"""
Recepteur HTTP factice pour Slack et PagerDuty (couche 7).

Sert a valider le ROUTAGE des alertes (critique -> PagerDuty + Slack ; warning ->
Slack uniquement) sans necessiter de vrais comptes externes, comme prevu par
CLAUDE.md. A remplacer par les vrais providers Slack/PagerDuty une fois les
identifiants reels disponibles (voir docs/PROGRESS.md couche 7).
"""
import threading
from datetime import datetime, timezone

from fastapi import FastAPI, Request

app = FastAPI(title="fake-notifier")

state_lock = threading.Lock()
received = {"slack": [], "pagerduty": []}
MAX_KEPT = 50


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/received")
def get_received():
    with state_lock:
        return {"slack": list(received["slack"]), "pagerduty": list(received["pagerduty"])}


@app.post("/received/reset")
def reset_received():
    with state_lock:
        received["slack"].clear()
        received["pagerduty"].clear()
    return {"status": "reset"}


@app.post("/slack")
async def fake_slack(request: Request):
    body = await request.json()
    entry = {"received_at": datetime.now(timezone.utc).isoformat(), "body": body}
    with state_lock:
        received["slack"].append(entry)
        received["slack"][:] = received["slack"][-MAX_KEPT:]
    print(f"[fake-notifier] SLACK recu: {body.get('text', body)}")
    return {"ok": True}


@app.post("/pagerduty")
async def fake_pagerduty(request: Request):
    body = await request.json()
    entry = {"received_at": datetime.now(timezone.utc).isoformat(), "body": body}
    with state_lock:
        received["pagerduty"].append(entry)
        received["pagerduty"][:] = received["pagerduty"][-MAX_KEPT:]
    print(f"[fake-notifier] PAGERDUTY recu: {body}")
    return {"status": "success", "message": "Event processed", "dedup_key": "fake-dedup-key"}
