# Progression AIOps

Dernière mise à jour : 2026-10-01

## Statut par couche

| Couche | Nom | Statut | Validé le |
|---|---|---|---|
| 0 | Audit (lecture seule) | ✅ Fait, en attente de validation utilisateur | — |
| 1 | Applications (Juice Shop) | ⏳ Générateur de trafic à créer | — |
| 2 | Log Collection | ✅ Validée | 2026-10-01 |
| 3 | Ingestion / Stream Processing | ✅ Validée | 2026-10-01 |
| 4 | Observabilité & Métriques | ✅ Installée et testée, en attente de "VALIDÉ couche 4" | — |
| 5 | Moteur Prédictif | ⏳ Non démarré | — |
| 6 | Keep (existant à configurer) | ⏳ Providers/workflows à ajouter | — |
| 7 | Alerting | ⏳ Non démarré | — |

## Couche 2 — Rapport (installation et tests, 2026-10-01)

| Vérification | Résultat | Preuve |
|---|---|---|
| Conteneur `aiops-vector` actif | PASS | `docker inspect -f '{{.State.Running}}' aiops-vector` → `true` |
| Capture des logs Keep (`app=keep`) | PASS | 118+ events capturés après appel `/healthcheck` |
| Champ `container_name` présent | PASS | `"container_name":"aiops-keep-backend-1"` |
| Champ `timestamp` présent | PASS | `"timestamp":"2026-10-01T16:19:30..."` |
| Champ `level` (niveau) extrait | PASS | `"level":"info"` (`downcase()` en VRL) |
| Logs d'accès HTTP Juice Shop (Option A — sidecar) | PASS | `"message":"::ffff:10.1.0.1 - - [01/Oct/2026:16:32:06] \"POST /rest/user/login HTTP/1.1\" 401 26..."` |
| Sidecar `access-log-shipper` identifié | PASS | `io.kubernetes.container.name":"access-log-shipper"` |
| Code de statut HTTP visible dans le log d'accès | PASS | `401` sur tentative de login |

**Script de test** : `tests/layer-2/test_vector_logs.sh` — **8/8 PASS**.

**Option A implémentée** (accord explicite reçu le 2026-10-01) : patch additif du
Deployment k8s `juice-shop` (`k8s/juice-shop-access-log-sidecar-patch.yaml`) :
- Ajout d'un volume `emptyDir` `access-logs`, monté dans le conteneur applicatif
  `juice-shop` à `/juice-shop/logs` (même chemin qu'avant, juste backé par un volume
  partagé désormais).
- Ajout d'un sidecar `access-log-shipper` (`busybox:1.38.0`) qui `tail -F` le fichier
  du jour et l'expose sur son propre stdout → capturé par Vector via le label Docker
  `io.kubernetes.pod.namespace=juice-shop` (plus robuste que le prefix-matching sur
  nom de conteneur généré par k8s).
- **Rollout sans interruption** : stratégie `RollingUpdate` (maxSurge=25%→1 pour
  1 replica) → nouveau pod créé et prêt avant terminaison de l'ancien (`kubectl
  rollout status` → "successfully rolled out", 0 downtime observé).
- Conteneur applicatif Juice Shop **non modifié** (même image `bkimminich/juice-shop`,
  aucun changement de commande/config).

**Limitation connue (mineure, non bloquante)** : le champ `level` reste `"unknown"`
pour les lignes d'accès HTTP (le format `combined` de morgan ne contient pas les mots
`info`/`warn`/`error`) ; le niveau pertinent pour ces lignes est le code de statut
HTTP, déjà visible dans `message`. Une extraction dédiée (regex sur le statut HTTP)
pourra être ajoutée en couche 3 (transform/routage) si besoin.

**Impact sur l'existant** :
- `aiops-vector` : conteneur additif sur `aiops_default`, rien d'existant modifié.
- Deployment `juice-shop` : modifié (volume + sidecar additifs), rollout sans coupure
  constatée. Le conteneur applicatif lui-même est inchangé.

**Rollback** :
```bash
# Couche 2 (Vector)
docker compose -f compose/layer-2-collect.yml down
docker volume rm aiops_vector-output   # si on veut aussi supprimer les donnees collectees

# Sidecar Juice Shop (retour a la version precedente du Deployment)
kubectl rollout undo -n juice-shop deployment juice-shop
```

## Couche 3 — Rapport (installation et tests, 2026-10-01)

| Vérification | Résultat | Preuve |
|---|---|---|
| Cluster Redpanda `v26.2.3` healthy | PASS | `rpk cluster health` → `Healthy: true` |
| Topics `logs.raw` / `logs.parsed` / `anomalies` créés | PASS | `rpk topic list` |
| Vector routeur actif, consomme `logs.raw` | PASS | `rpk group describe vector-router` → `STATE Stable` |
| Messages en temps réel dans `logs.raw` | PASS | `rpk topic consume logs.raw` après appel `/healthcheck` Keep |
| Normalisation : extraction `http_status`/`http_method`/`http_path` (Juice Shop) | PASS | `http_status":401` (login), `http_status":500` (produit inexistant) dans `logs.parsed` |
| Niveau dérivé du code HTTP (4xx→warn, 5xx→error) | PASS | `"level":"warn"` pour 401, `"level":"error"` pour 500 |
| Lag consumer `vector-router` proche de 0 | PASS | `TOTAL-LAG 0-4` (bruit de fond = heartbeats Keep) |
| Redémarrage du routeur sans perte de messages | PASS | Après `docker restart aiops-vector-router`, le consumer group reprend à l'offset committé (201), pas de reset à 0, lag revenu à 2 puis stable |

**Script de test** : `tests/layer-3/test_redpanda_pipeline.sh` — **9/9 PASS**.

**Bonus constaté** : une requête vers un produit inexistant (`/rest/products/9999999`) a
déclenché une vraie 500 côté Juice Shop, et Vector a capturé **à la fois** la ligne
d'accès HTTP (`status 500`) et la stack trace applicative complète (`stderr`,
`console.error`) — donnée précieuse pour la corrélation en couche 5/6.

**Pipeline validé** : Juice Shop/Keep → Vector (collecteur, sink Kafka `logs.raw`) →
Redpanda → Vector (routeur, consumer group `vector-router`) → normalisation VRL →
Redpanda (`logs.parsed`).

**Impact sur l'existant** : aucun. Services additifs uniquement (`aiops-redpanda`,
`aiops-redpanda-console`, `aiops-vector-router`, `aiops-redpanda-topics-init` one-shot).

**Rollback** :
```bash
docker compose -f compose/layer-3-ingestion.yml down
docker volume rm aiops_redpanda-data   # si on veut aussi supprimer les donnees Kafka
```

## Couche 4 — Rapport (installation et tests, 2026-10-01)

| Vérification | Résultat | Preuve |
|---|---|---|
| Prometheus v3.15.0 : toutes les targets UP | PASS | `prometheus`, `cadvisor`, `vector-metrics`, `blackbox-http` (x2) → `health: up` |
| Blackbox : `probe_success=1` pour Juice Shop et Keep | PASS | requête `probe_success` sur l'API Prometheus |
| cAdvisor v0.60.6 : métriques conteneur Juice Shop exposées | PASS | `container_memory_usage_bytes{container_label_io_kubernetes_container_name="juice-shop"}` |
| Vector métriques : `juice_shop_http_requests_total` (401/500) | PASS | compteur par `status` alimenté par le trafic réel |
| 3 règles d'alerte chargées | PASS | `JuiceShopDown`, `KeepDown`, `JuiceShopHighErrorRate` |
| Alerte déclenchée volontairement (rafale 401/500 réelle) | PASS | `JuiceShopHighErrorRate` → état `firing` en ~1-2 min |
| Alertmanager reçoit l'alerte | PASS | `GET /api/v2/alerts` → `JuiceShopHighErrorRate active` |
| **Webhook Alertmanager → Keep livré** | PASS | log Keep : `POST /alerts/event/prometheus HTTP/1.1" 202` |
| Grafana provisionné (datasource + dashboard "Juice Shop") | PASS | http://localhost:3001 (admin/admin), dashboard "Juice Shop" visible |

**Script de test** : `tests/layer-4/test_observability.sh` — **18/18 PASS**.

**Mécanisme webhook Alertmanager → Keep** (trouvé dans le code source de Keep,
`keep/api/routes/alerts.py` : route `POST /event/{provider_type}`) :
`http://keep-backend:8080/alerts/event/prometheus` avec Basic Auth
(`username: keep`, `password: <clé API role webhook>`). Décision utilisateur :
réutilisation de la clé existante `orangeci-test` (déjà dans `aiops/.env`, non modifié).

**Génération du secret dans la config Alertmanager** : un conteneur init
(`alertmanager-config-init`, busybox) reçoit `aiops/.env` via `env_file` et fait
l'extraction/substitution **à l'intérieur du conteneur** (`sed` sur un template) —
la clé n'a jamais été manipulée dans une commande shell de ma part (bloqué une fois
par le classificateur de sécurité "Credential Leakage" avec ma première approche, qui
extrayait la clé directement dans un `Bash` ; j'ai corrigé en déplaçant l'extraction
côté conteneur). Le fichier généré contenant le secret vit uniquement dans un volume
Docker nommé (`aiops_alertmanager-config`), jamais sur le disque du dépôt.

**Point d'attention mineur** : la déduplication native d'Alertmanager
(`repeat_interval: 5m`) signifie qu'une alerte déjà active ne redéclenche pas un
nouvel envoi webhook avant ce délai — comportement normal, pas un bug.

**Limitation connue** : les requêtes `GET /` (page d'accueil Juice Shop, servie en
statique) ne passent pas par `morgan` et n'apparaissent donc pas dans les métriques
HTTP ; seules les routes API (`/rest/...`) sont comptabilisées. À prendre en compte
pour le générateur de trafic de la couche 1 (préférer des routes API).

**Impact sur l'existant** : aucun. Tous les services sont additifs. Le seul
changement touchant un composant existant est la **lecture** (non modification) de
`aiops/.env` pour le webhook Alertmanager.

**Rollback** :
```bash
docker compose -f compose/layer-4-observability.yml down
docker volume rm aiops_prometheus-data aiops_grafana-data aiops_alertmanager-config  # destructif, donnees uniquement
```

## URLs et ports utiles (existant)
- Keep UI : http://localhost:3000
- Keep API : http://localhost:8080
- demo-app : http://localhost:8000
- Vector API collecteur (tap/top) : http://localhost:8686
  - `docker exec -it aiops-vector vector top --url http://localhost:8686` (interactif, terminal requis)
  - `docker exec aiops-vector vector tap --url http://localhost:8686` (flux, pas de TTY requis)
- Vector API routeur : http://localhost:8687
- Redpanda Console (UI topics/consumers) : http://localhost:8089
- Redpanda broker (externe) : localhost:19092 ; admin : localhost:9644
- `docker exec aiops-redpanda rpk topic consume logs.parsed -o 0`
- `docker exec aiops-redpanda rpk group describe vector-router`
- Prometheus : http://localhost:9090 (Targets, Alerts, Graph)
- Grafana : http://localhost:3001 (admin/admin — a changer en production)
- Alertmanager : http://localhost:9093
- cAdvisor : http://localhost:8081
- Blackbox exporter : http://localhost:9115
- Juice Shop (k8s) : pas de port hôte, ClusterIP interne 10.99.141.65:3000
  (joignable depuis le réseau Docker `aiops_default`)

## Décisions prises
- Réseau Docker partagé pour les nouvelles couches : `aiops_default` (existant, réutilisé).
- Grafana sur le port 3001 (3000 déjà pris par Keep UI).
- Port 8001 pour le moteur prédictif (8000 pris par demo-app).
- Repo Git créé à la racine `aiops-final/` pour les couches 2-7 ; `aiops/` et
  `juice-shop/` restent des clones upstream non versionnés ici.

## Points en attente de décision utilisateur
1. ~~Logs HTTP Juice Shop~~ → **Résolu** : Option A (sidecar) implémentée et testée.
2. ~~RAM Docker Desktop~~ → **Résolu** : reste à 7.66 Gio, Redpanda choisi en consequence.
3. Secrets couche 6/7 (clés API Keep, webhook Slack, clé PagerDuty) : à fournir au
   moment voulu, jamais committés (`.env` dans `.gitignore`, `.env.example` fourni).

## Point mineur connu (cosmétique)
Les fichiers `compose/layer-2-collect.yml` et `compose/layer-3-ingestion.yml` n'ont
pas de `name:` de projet Compose explicite : Docker Compose avertit "orphan
containers" quand on lance l'un après l'autre depuis le même dossier (chacun voit les
conteneurs de l'autre comme "orphelins" de son propre projet implicite). Sans impact
(rien n'est supprimé), mais à corriger proprement dans une passe ultérieure (ajouter
`name: aiops-layer2` / `name: aiops-layer3`) — pas fait maintenant pour ne pas
recréer inutilement les conteneurs de la couche 2 déjà validée.

## Commandes utiles
```bash
# Stack Keep existante (ne pas toucher sans accord)
docker compose -f aiops/docker-compose.orangeci.yml ps

# Pods Juice Shop (Kubernetes intégré à Docker Desktop)
kubectl get pods -n juice-shop
kubectl get svc -n juice-shop
```
