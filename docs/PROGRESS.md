# Progression AIOps

Dernière mise à jour : 2026-10-01

## Statut par couche

| Couche | Nom | Statut | Validé le |
|---|---|---|---|
| 0 | Audit (lecture seule) | ✅ Fait, en attente de validation utilisateur | — |
| 1 | Applications (Juice Shop) | ⏳ Générateur de trafic à créer | — |
| 2 | Log Collection | ✅ Installée et testée, en attente de "VALIDÉ couche 2" | — |
| 3 | Ingestion / Stream Processing | ⏳ Non démarré | — |
| 4 | Observabilité & Métriques | ⏳ Non démarré | — |
| 5 | Moteur Prédictif | ⏳ Non démarré | — |
| 6 | Keep (existant à configurer) | ⏳ Providers/workflows à ajouter | — |
| 7 | Alerting | ⏳ Non démarré | — |

## Couche 2 — Rapport (installation et tests, 2026-10-01)

| Vérification | Résultat | Preuve |
|---|---|---|
| Conteneur `aiops-vector` actif | PASS | `docker inspect -f '{{.State.Running}}' aiops-vector` → `true` |
| Capture des logs Keep (`app=keep`) | PASS | `tests/layer-2/test_vector_logs.sh` → 118 events capturés après appel `/healthcheck` |
| Champ `container_name` présent | PASS | `"container_name":"aiops-keep-backend-1"` dans le JSON de sortie |
| Champ `timestamp` présent | PASS | `"timestamp":"2026-10-01T16:19:30..."` |
| Champ `level` (niveau) extrait | PASS | `"level":"info"` (après correctif de casse `downcase()` en VRL) |
| Logs d'accès HTTP Juice Shop sur stdout | **FAIL (attendu)** | Trafic réel envoyé (200, 401) → **0** événement `app=juice-shop` capturé |

**Script de test** : `tests/layer-2/test_vector_logs.sh` (exécutable, 5/5 PASS sur les vérifications applicables).

**Problème rencontré et diagnostic** : Juice Shop écrit ses logs d'accès HTTP dans un
fichier interne au conteneur (`morgan` → `logs/access.log.<DATE>`), jamais sur
stdout/stderr. `docker_logs` ne peut donc voir que les messages de démarrage
(Winston `info:`/`warn:`), pas le détail des requêtes HTTP. Confirmé par test réel
(trafic normal + 404 + login raté envoyés, aucun nouvel événement Juice Shop capturé).
**Non corrigé dans cette itération** (Option B retenue : stdout uniquement, zéro
impact sur le déploiement Juice Shop existant). Option A (sidecar de lecture du
fichier de logs) reste proposée pour une itération ultérieure, **sous réserve de
votre accord explicite** puisqu'elle modifierait le Deployment k8s existant.

**Impact sur l'existant** : aucun. Un seul conteneur additif (`aiops-vector`) sur le
réseau `aiops_default`, aucune modification des conteneurs/volumes/réseaux existants.

**Rollback** :
```bash
docker compose -f compose/layer-2-collect.yml down
docker volume rm aiops_vector-output   # si on veut aussi supprimer les données collectées
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
1. Logs HTTP Juice Shop (fichier interne, pas stdout) : solution à valider en couche 2
   (piste envisagée : sidecar de lecture du volume de logs — modifierait le déploiement
   k8s existant, nécessite accord explicite).
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
