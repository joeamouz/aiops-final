"""
Moteur predictif (couche 5) - detection d'anomalies sur les logs.

Protocole :
  - Mode "learning" (defaut au demarrage) : consomme le topic Kafka "logs.parsed",
    construit les templates de logs (Drain3) et nourrit le modele de reference
    (River HalfSpaceTrees) avec les features de chaque fenetre, SANS alerter.
  - Mode "scoring" (apres POST /train/stop) : chaque nouvelle fenetre est scoree ;
    au-dela du seuil ANOMALY_THRESHOLD, une anomalie est publiee dans le topic
    "anomalies" et envoyee a Keep (API generique /alerts/event), avec le template
    de log concerne, le score et la fenetre de temps.
  - POST /train/start reinitialise le modele et repasse en mode "learning"
    (reentrainement complet sur le trafic qui suit).

Deux signaux d'anomalie independants :
  1. Template jamais vu pendant l'apprentissage (nouveau cluster Drain3) ->
     signal deterministe fort (score 1.0), uniquement en mode scoring.
  2. Deviation statistique de la fenetre courante (volume d'evenements, part
     d'erreurs 4xx/5xx, diversite des templates) via River HalfSpaceTrees.
"""
import json
import os
import threading
import time
from collections import Counter
from datetime import datetime, timezone

import requests
from confluent_kafka import Consumer, Producer
from drain3 import TemplateMiner
from fastapi import FastAPI
from river import anomaly

KAFKA_BOOTSTRAP_SERVERS = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "redpanda:9092")
CONSUMER_TOPIC = os.environ.get("CONSUMER_TOPIC", "logs.parsed")
ANOMALY_TOPIC = os.environ.get("ANOMALY_TOPIC", "anomalies")
CONSUMER_GROUP = os.environ.get("CONSUMER_GROUP", "ml-engine")
KEEP_API_URL = os.environ.get("KEEP_API_URL", "http://keep-backend:8080")
KEEP_API_KEY_NAME = os.environ.get("KEEP_API_KEY_NAME", "orangeci-test")
ANOMALY_THRESHOLD = float(os.environ.get("ANOMALY_THRESHOLD", "0.6"))
WINDOW_SECONDS = float(os.environ.get("WINDOW_SECONDS", "5"))
# HalfSpaceTrees a besoin d'environ "window_size" points pour produire des scores
# significatifs. Avec le window_size par defaut (250) et WINDOW_SECONDS=15s, il
# faudrait ~1h d'apprentissage avant d'obtenir un signal utile. Reduit ici pour un
# apprentissage court (quelques minutes) ; a augmenter (ex. 250, valeur par defaut
# River) pour un deploiement reel avec plusieurs heures/jours d'historique.
HALFSPACETREES_WINDOW_SIZE = int(os.environ.get("HALFSPACETREES_WINDOW_SIZE", "20"))


def get_keep_api_key() -> str | None:
    raw = os.environ.get("KEEP_DEFAULT_API_KEYS", "")
    for entry in raw.split(","):
        parts = entry.split(":")
        if len(parts) >= 3 and parts[0] == KEEP_API_KEY_NAME:
            return parts[2]
    return None


state_lock = threading.Lock()
state = {
    "mode": "learning",
    "events_processed": 0,
    "anomalies_detected": 0,
    "new_templates_during_scoring": 0,
    "started_at": datetime.now(timezone.utc).isoformat(),
    "last_window_score": None,
    "last_anomaly": None,
}

template_miner = TemplateMiner()
model = anomaly.HalfSpaceTrees(seed=42, window_size=HALFSPACETREES_WINDOW_SIZE)

window_lock = threading.Lock()
window = {
    "start": time.time(),
    "events": 0,
    "errors": 0,
    "templates": Counter(),
}


def reset_window():
    with window_lock:
        window["start"] = time.time()
        window["events"] = 0
        window["errors"] = 0
        window["templates"] = Counter()


def window_features(w) -> dict:
    duration = max(time.time() - w["start"], 1e-6)
    return {
        "rate": w["events"] / duration,
        "error_ratio": (w["errors"] / w["events"]) if w["events"] else 0.0,
        "unique_templates": float(len(w["templates"])),
    }


def send_to_keep(alert_id: str, name: str, severity: str, description: str):
    api_key = get_keep_api_key()
    if not api_key:
        print(f"[ml-engine] Pas de cle API Keep ({KEEP_API_KEY_NAME}) trouvee, alerte non envoyee")
        return
    payload = {
        "id": alert_id,
        "name": name,
        "status": "firing",
        "severity": severity,
        "source": ["ml-engine"],
        "description": description,
    }
    try:
        resp = requests.post(
            f"{KEEP_API_URL}/alerts/event",
            json=payload,
            headers={"X-API-KEY": api_key},
            timeout=5,
        )
        print(f"[ml-engine] Alerte envoyee a Keep -> HTTP {resp.status_code}")
    except requests.RequestException as exc:
        print(f"[ml-engine] Echec d'envoi de l'alerte a Keep: {exc}")


def publish_anomaly(producer: Producer, anomaly_payload: dict):
    producer.produce(ANOMALY_TOPIC, json.dumps(anomaly_payload).encode("utf-8"))
    producer.poll(0)


def record_anomaly(producer, kind, score, template, app, window_start, window_end):
    payload = {
        "kind": kind,
        "score": round(float(score), 4),
        "template": template,
        "app": app,
        "window_start": window_start,
        "window_end": window_end,
        "detected_at": datetime.now(timezone.utc).isoformat(),
    }
    with state_lock:
        state["anomalies_detected"] += 1
        state["last_anomaly"] = payload

    publish_anomaly(producer, payload)
    send_to_keep(
        alert_id=f"ml-engine-{kind}",
        name=f"Anomalie detectee ({kind})",
        severity="warning" if kind == "statistical_burst" else "critical",
        description=(
            f"Type: {kind} | Score: {payload['score']} | App: {app} | "
            f"Template: {template} | Fenetre: {window_start} -> {window_end}"
        ),
    )
    print(f"[ml-engine] ANOMALIE {kind} score={payload['score']} template={template!r}")


def consumer_loop():
    consumer = Consumer({
        "bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS,
        "group.id": CONSUMER_GROUP,
        "auto.offset.reset": "latest",
    })
    consumer.subscribe([CONSUMER_TOPIC])
    producer = Producer({"bootstrap.servers": KAFKA_BOOTSTRAP_SERVERS})

    reset_window()
    last_flush = time.time()

    print(f"[ml-engine] Consommation de '{CONSUMER_TOPIC}' demarree (mode={state['mode']})")

    while True:
        msg = consumer.poll(timeout=1.0)
        now = time.time()

        if msg is not None and not msg.error():
            try:
                event = json.loads(msg.value())
            except (json.JSONDecodeError, TypeError):
                event = None

            if event is not None:
                try:
                    message_text = str(event.get("message", ""))
                    app_name = event.get("app", "unknown")

                    # Le mining de templates (Drain3) n'est applique qu'aux logs
                    # d'acces Juice Shop : lignes courtes et structurellement
                    # stables (morgan combined). Les logs Keep (JSON verbeux, IDs
                    # de workflow/stack traces incorporees en texte libre) font
                    # exploser le nombre de templates (quasi chaque ligne est
                    # "nouvelle") et noient le signal sous les faux positifs -
                    # constate empiriquement (cf. tests/layer-5).
                    is_new_template = False
                    template = message_text
                    if app_name == "juice-shop":
                        result = template_miner.add_log_message(message_text)
                        template = result.get("template_mined", message_text)
                        is_new_template = result.get("change_type") == "cluster_created"

                    with window_lock:
                        window["events"] += 1
                        if app_name == "juice-shop":
                            window["templates"][template] += 1
                        http_status = event.get("http_status")
                        level = event.get("level")
                        if (isinstance(http_status, int) and http_status >= 400) or level == "error":
                            window["errors"] += 1

                    with state_lock:
                        state["events_processed"] += 1
                        mode = state["mode"]

                    if mode == "scoring" and is_new_template:
                        with state_lock:
                            state["new_templates_during_scoring"] += 1
                        record_anomaly(
                            producer, "new_template", 1.0, template, app_name,
                            datetime.fromtimestamp(window["start"], tz=timezone.utc).isoformat(),
                            datetime.now(timezone.utc).isoformat(),
                        )
                except Exception as exc:  # ne jamais tuer le thread consommateur
                    print(f"[ml-engine] Erreur traitement evenement (ignoree): {exc}")

        if now - last_flush >= WINDOW_SECONDS:
            try:
                with window_lock:
                    w = dict(window)
                    w["templates"] = Counter(window["templates"])
                feats = window_features(w)
                with state_lock:
                    mode = state["mode"]

                if mode == "learning":
                    model.learn_one(feats)
                else:
                    score = model.score_one(feats)
                    model.learn_one(feats)
                    with state_lock:
                        state["last_window_score"] = round(float(score), 4)
                    if score > ANOMALY_THRESHOLD and w["events"] > 0:
                        top_template = w["templates"].most_common(1)
                        top_template_str = top_template[0][0] if top_template else "n/a"
                        record_anomaly(
                            producer, "statistical_burst", score, top_template_str, "mixed",
                            datetime.fromtimestamp(w["start"], tz=timezone.utc).isoformat(),
                            datetime.now(timezone.utc).isoformat(),
                        )
            except Exception as exc:  # ne jamais tuer le thread consommateur
                print(f"[ml-engine] Erreur traitement fenetre (ignoree): {exc}")
            finally:
                reset_window()
                last_flush = now


app = FastAPI(title="aiops-ml-engine")


@app.on_event("startup")
def startup():
    thread = threading.Thread(target=consumer_loop, daemon=True)
    thread.start()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/status")
def status():
    with state_lock:
        return dict(state)


@app.post("/train/start")
def train_start():
    global model, template_miner
    with state_lock:
        state["mode"] = "learning"
        state["events_processed"] = 0
        state["anomalies_detected"] = 0
        state["new_templates_during_scoring"] = 0
        state["last_window_score"] = None
        state["last_anomaly"] = None
    model = anomaly.HalfSpaceTrees(seed=42, window_size=HALFSPACETREES_WINDOW_SIZE)
    template_miner = TemplateMiner()
    reset_window()
    return {"mode": "learning", "message": "Modele reinitialise, apprentissage en cours"}


@app.post("/train/stop")
def train_stop():
    with state_lock:
        state["mode"] = "scoring"
    return {"mode": "scoring", "message": "Apprentissage termine, scoring en cours"}
