# Progression AIOps

Dernière mise à jour : 2026-10-01

## Statut par couche

| Couche | Nom | Statut | Validé le |
|---|---|---|---|
| 0 | Audit (lecture seule) | ✅ Fait, en attente de validation utilisateur | — |
| 1 | Applications (Juice Shop) | ⏳ Générateur de trafic à créer | — |
| 2 | Log Collection | ✅ Validée | 2026-10-01 |
| 3 | Ingestion / Stream Processing | ⏳ Non démarré | — |
| 4 | Observabilité & Métriques | ⏳ Non démarré | — |
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

## URLs et ports utiles (existant)
- Keep UI : http://localhost:3000
- Keep API : http://localhost:8080
- demo-app : http://localhost:8000
- Vector API (tap/top) : http://localhost:8686
  - `docker exec -it aiops-vector vector top --url http://localhost:8686`
  - `docker logs -f aiops-vector` (sortie console des événements enrichis)
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
2. RAM Docker Desktop (7.66 Gio actuel) : à augmenter si possible (10-12 Gio recommandé)
   pour Kafka/Redpanda + Prometheus + Grafana + moteur ML.
3. Secrets couche 6/7 (clés API Keep, webhook Slack, clé PagerDuty) : à fournir au
   moment voulu, jamais committés (`.env` dans `.gitignore`, `.env.example` fourni).

## Commandes utiles
```bash
# Stack Keep existante (ne pas toucher sans accord)
docker compose -f aiops/docker-compose.orangeci.yml ps

# Pods Juice Shop (Kubernetes intégré à Docker Desktop)
kubectl get pods -n juice-shop
kubectl get svc -n juice-shop
```
