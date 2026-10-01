# Progression AIOps

Dernière mise à jour : 2026-10-01

## Statut par couche

| Couche | Nom | Statut | Validé le |
|---|---|---|---|
| 0 | Audit (lecture seule) | ✅ Fait, en attente de validation utilisateur | — |
| 1 | Applications (Juice Shop) | ⏳ Générateur de trafic à créer | — |
| 2 | Log Collection | ✅ Validée | 2026-10-01 |
| 3 | Ingestion / Stream Processing | ✅ Validée | 2026-10-01 |
| 4 | Observabilité & Métriques | ✅ Validée | 2026-10-01 |
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
| Grafana provisionné (datasource + dashboard "Juice Shop") | PASS | http://localhost:3001, dashboard "Juice Shop" visible |
| **Loki** `3.7.8` pret (`/ready`) | PASS | `GET /ready` → `ready` |
| **Logs applicatifs `app="juice-shop"` dans Loki** | PASS | requete `{app="juice-shop"}` → lignes d'acces (401/500) + stack traces |
| **Logs applicatifs `app="keep"` dans Loki** | PASS | requete `{app="keep"}` → heartbeats + `/healthcheck` |
| **Datasource Grafana "Loki" provisionnee** | PASS | log Grafana : `inserting datasource from configuration" name=Loki` |
| Panneau "Logs applicatifs" ajoute au dashboard "Juice Shop" | PASS | visible sous les 4 panneaux metriques existants |

**Script de test** : `tests/layer-4/test_observability.sh` — **23/23 PASS** (18 initiaux + 5 ajoutes pour Loki).

### Ajout post-rapport : logs applicatifs dans Grafana (Loki)

**Constat utilisateur** : seules les metriques Prometheus etaient visibles dans Grafana,
aucun moyen de consulter les logs bruts.

**Solution** : Grafana Loki `3.7.8` (single-binary, stockage filesystem local, schema
`tsdb`/`v13` — config verifiee sur la doc officielle actuelle). Vector (`aiops-vector-metrics`,
sink `loki_out`) pousse directement le topic Kafka `logs.parsed` deja consomme vers Loki —
pas de Promtail necessaire. Labels **faible cardinalite uniquement** : `app`, `level`,
`job=vector` (jamais `http_path` ni timestamp, pour eviter de degrader les perfs Loki).

**Fichiers crees** :
- `compose/loki/loki-config.yaml`
- `compose/grafana/provisioning/datasources/loki.yml`

**Fichiers modifies** :
- `compose/layer-4-observability.yml` (service `loki` + volume `aiops_loki-data`)
- `compose/vector/vector-metrics.yaml` (sink `loki_out`, consomme `logs_parsed_in` deja present)
- `compose/grafana/provisioning/dashboards/json/juice-shop.json` (panneau "Logs applicatifs")
- `tests/layer-4/test_observability.sh` (+5 verifications Loki)

**Probleme rencontre et corrige** : config Loki initiale refusee au demarrage
(`CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be
configured when retention is enabled`) — `retention_enabled: true` necessite un
`delete_request_store` (S3/GCS/Azure, non pertinent ici). Corrige en retirant
`retention_enabled` (pas de suppression automatique des anciens logs dans ce
labo — a revisiter si la retention devient un besoin reel).

**Point d'attention** : la verification via l'API Grafana (`/api/datasources`) a echoue
avec `admin`/`admin` (401) — le mot de passe a probablement ete change manuellement
depuis le premier rapport. Verification faite autrement (logs de provisioning Grafana
+ requetes directes sur l'API Loki). A confirmer visuellement dans l'UI ; si le login
`admin`/`admin` ne fonctionne plus, me donner le mot de passe actuel ou le reinitialiser
vous-meme dans l'UI.

**Bug corrige pendant les tests** : `docker logs | grep -q` sous `set -o pipefail` peut
faussement echouer (SIGPIPE sur le process qui ecrit les logs quand `grep -q` sort tot
apres avoir trouve sa correspondance) — deja rencontre et corrige de la meme facon en
couche 2/3. Corrige ici aussi (capture dans une variable puis `case ... in *motif*)`).

**Impact sur l'existant** : additif. Seul redemarrage : `aiops-vector-metrics`
(consumer group Kafka, pas de perte) et `aiops-grafana` (pour charger la nouvelle
datasource — ses donnees/dashboards persistent via le volume existant).

**Rollback (logs/Loki uniquement)** :
```bash
docker compose -f compose/layer-4-observability.yml stop loki
docker rm aiops-loki
docker volume rm aiops_loki-data
# puis retirer le sink loki_out de compose/vector/vector-metrics.yaml et redemarrer :
docker restart aiops-vector-metrics
```

### Ajout post-rapport 2 : dashboard "Logs - Insights" (agregation/stats sur les logs)

**Demande utilisateur** : au-dela des logs bruts, pouvoir "interpreter" les logs
(compter les occurrences par type d'erreur) pour aider a la prise de decision.

**Solution** : nouveau dashboard Grafana `compose/grafana/provisioning/dashboards/json/logs-insights.json`
(additif, ne modifie pas le dashboard "Juice Shop"), 100% requetes LogQL sur Loki :

| Panneau | Requete LogQL (resumee) |
|---|---|
| Logs totaux / Erreurs / Warnings ($__range) | `sum(count_over_time({app=~"juice-shop\|keep"} \| json [...]))` filtre par `level` |
| Logs par niveau dans le temps | `sum by (level) (count_over_time(... \| json [...]))` |
| Repartition par code HTTP | `sum by (http_status) (count_over_time({app="juice-shop"} \| json \| http_status!="" [...]))` |
| Top endpoints en erreur | `topk(10, sum by (http_path,http_status) (count_over_time(... http_status>=400 ...)))` |
| Top types d'erreurs applicatives | extraction regex sur `message` (stack traces) via `line_format` + `regexp`, groupee par `error_kind` |

**Requetes validees en direct contre l'API Loki avant integration** (lecture seule,
derniere heure de donnees reelles) :
- Par code HTTP : `200`→34, `401`→128, `500`→125
- Top endpoints en erreur : `/rest/user/login` 401 ×132, `/rest/products/9999999` 500 ×91,
  `/rest/products/1` 500 ×39
- Type d'erreur applicative : `"Unexpected path"` ×135 (stack traces Juice Shop)

**Fichier cree** : `compose/grafana/provisioning/dashboards/json/logs-insights.json`

**Impact sur l'existant** : aucun redemarrage necessaire en theorie (le provisioning
dashboards de Grafana recharge selon `updateIntervalSeconds: 30`) ; un `docker restart
aiops-grafana` a ete fait pour forcer/confirmer le chargement immediat et verifier
l'absence d'erreur dans les logs (`finished to provision dashboards`, aucune erreur
JSON). Donnees et datasources Grafana inchangees (volume persistant).

**A verifier visuellement** : http://localhost:3001 → dashboard **"Logs - Insights"**.

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
- Grafana : http://localhost:3001 (admin/admin a l'origine ; mot de passe visiblement
  change depuis — a confirmer avec l'utilisateur)
- Alertmanager : http://localhost:9093
- cAdvisor : http://localhost:8081
- Blackbox exporter : http://localhost:9115
- Loki : http://localhost:3100 (consommé via Grafana, pas d'UI propre)
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
