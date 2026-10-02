# Runbook AIOps — Accès, identifiants, démarrage/arrêt

> Document de référence. Pour le détail technique couche par couche (preuves de
> test, bugs rencontrés, décisions), voir `docs/PROGRESS.md`. Pour l'architecture
> cible et le plan de ports, voir `docs/ARCHITECTURE.md`.

Dernière mise à jour : 2026-10-02

## 1. Récapitulatif des grandes étapes

| Étape | Contenu | Statut |
|---|---|---|
| **Phase 0** | Audit en lecture seule de l'existant (Juice Shop en k8s, Keep en Docker Compose), plan de ports, schéma cible | ✅ Fait |
| **Couche 1** | Applications (Juice Shop existant) | ⏳ Générateur de trafic normal/anormal pas encore créé |
| **Couche 2** | Collecte de logs — Vector 0.58.0, sidecar k8s pour les logs d'accès Juice Shop | ✅ **Validée** (tag `layer-2-validated`) |
| **Couche 3** | Ingestion — Redpanda v26.2.3 + Vector routeur (normalisation HTTP) | ✅ **Validée** (tag `layer-3-validated`) |
| **Couche 4** | Observabilité — Prometheus v3.15.0, Grafana 13.2.2, Alertmanager v0.34.1, cAdvisor, Blackbox, Loki | ✅ **Validée** (tag `layer-4-validated`) |
| **Couche 5** | Moteur prédictif — Drain3-improved + River (HalfSpaceTrees), détection d'anomalies | ✅ **Validée** (tag `layer-5-validated`) |
| **Couche 6** | Keep configuré — champ `service`, provider Prometheus, workflow d'enrichissement/priorisation | ⚠️ Quasi complète — exécution confirmée, règle de corrélation à créer manuellement |
| **Couche 7** | Alerting — routage Slack/PagerDuty (récepteur factice, pas de comptes réels) | ✅ Testée (5/5), en attente de validation finale |

**Incident majeur résolu en cours de route** : les dossiers `aiops/` et
`juice-shop/` ont été déplacés en début de projet ; le conteneur `keep-backend`
avait été créé **avant** ce déplacement et montait donc un ancien répertoire vide
pour `/providers` et `/workflows`. Corrigé par recréation du conteneur depuis le
bon répertoire — voir `docs/PROGRESS.md` (couche 6) pour le détail complet.

## 2. Accès aux interfaces et APIs

| Service | URL | Identifiants |
|---|---|---|
| **Juice Shop** | Pas de port hôte — ClusterIP k8s interne `10.99.141.65:3000`, joignable uniquement depuis le réseau Docker `aiops_default` | Aucun (appli cible) |
| **Keep UI** | http://localhost:3000 | `KEEP_DEFAULT_USERNAME` / `KEEP_DEFAULT_PASSWORD` définis dans `aiops/.env` — **je ne les affiche pas ici**, consultez ce fichier |
| **Keep API** | http://localhost:8080 | Header `X-API-KEY` avec une clé de `KEEP_DEFAULT_API_KEYS` (`aiops/.env`), ex. `orangeci-test` (rôle webhook) |
| **Redpanda Console** | http://localhost:8089 | Aucun |
| **Redpanda (broker externe)** | `localhost:19092` (Kafka API), admin `localhost:9644` | Aucun |
| **Vector collecteur** (tap/top) | http://localhost:8686 | Aucun — `docker exec aiops-vector vector top --url http://localhost:8686` (interactif) ou `vector tap` (non-interactif) |
| **Vector routeur** | Non exposé sur l'hôte (réseau interne uniquement) | `docker exec aiops-vector-router vector top --url http://localhost:8687` |
| **Vector métriques** (Prometheus exporter) | http://localhost:9598/metrics | Aucun |
| **Prometheus** | http://localhost:9090 | Aucun |
| **Grafana** | http://localhost:3001 | Prévu `admin`/`admin` à l'installation (variables `GF_SECURITY_ADMIN_*` dans `compose/layer-4-observability.yml`) — **ne fonctionne plus**, le mot de passe a été changé depuis (manuellement ou volume pré-existant) ; à confirmer/réinitialiser vous-même dans l'UI si besoin |
| **Alertmanager** | http://localhost:9093 | Aucun |
| **cAdvisor** | http://localhost:8081 | Aucun |
| **Blackbox exporter** | http://localhost:9115 | Aucun |
| **Loki** | http://localhost:3100 (API, pas d'UI propre — consulté via Grafana) | Aucun |
| **Moteur prédictif (ml-engine)** | http://localhost:8001 — `/health`, `/status`, `POST /train/start`, `POST /train/stop` | Aucun |
| **Récepteur factice Slack/PagerDuty** | http://localhost:8002 — `/health`, `GET /received`, `POST /received/reset` | Aucun |
| **demo-app** (démo indépendante pré-existante) | http://localhost:8000 | Aucun |

## 3. Secrets — où les trouver (jamais affichés en clair ici)

- **Fichier source** : `aiops/.env` (jamais committé, voir `aiops/.gitignore`).
- Variables clés : `KEEP_JWT_SECRET`, `KEEP_DEFAULT_USERNAME`/`PASSWORD`,
  `KEEP_DEFAULT_API_KEYS` (format `nom:role:secret,...`), `DEMO_APP_KEEP_API_KEY`.
- La clé `orangeci-test` (rôle `webhook`) est réutilisée par Alertmanager
  (couche 4) et le moteur prédictif (couche 5) pour pousser des alertes vers
  Keep — elle n'a que les scopes `write:alert`/`write:incident` (pas d'accès
  admin).
- **Aucun vrai compte Slack/PagerDuty** n'existe dans cet environnement — la
  couche 7 utilise un récepteur HTTP factice local. Voir `docs/PROGRESS.md`
  (couche 7) pour comment brancher de vrais comptes plus tard.
- Un script (`scripts/keep-admin/create_correlation_rule.py`) existe pour créer
  la règle de corrélation Keep via un JWT admin auto-signé, mais son exécution a
  été refusée par le mode sécurisé (forger un JWT admin = élévation de
  privilège) — **à exécuter vous-même** si besoin, ou créer la règle à la main
  dans l'UI (valeurs données dans `docs/PROGRESS.md`, couche 6).

## 4. Commandes utiles

```bash
# Statut de tous les conteneurs du projet
docker ps --filter "name=aiops-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Démarrer une couche (exemple couche 4)
docker compose -f compose/layer-4-observability.yml up -d

# Arrêter une couche (exemple couche 7)
docker compose -f compose/layer-7-alerting.yml down

# Stack Keep existante (ne jamais arrêter sans accord explicite)
docker compose -f aiops/docker-compose.orangeci.yml -f aiops/docker-compose.demo-app.yml ps

# Recharger un provider/workflow Keep apres modification (RECREATE, pas restart)
docker compose -f aiops/docker-compose.orangeci.yml -f aiops/docker-compose.demo-app.yml \
  up -d --force-recreate keep-backend
# /!\ Peut prendre 15s a plusieurs minutes selon la charge systeme - patienter,
# "unhealthy" transitoire pendant la montee en charge n'est pas forcement une panne.

# Tests automatises par couche
bash tests/layer-2/test_vector_logs.sh
bash tests/layer-3/test_redpanda_pipeline.sh
bash tests/layer-4/test_observability.sh
bash tests/layer-5/test_ml_engine.sh
bash tests/layer-7/test_alerting_routing.sh
```

## 5. Points d'attention actuels

1. **Ressources système** : ~24 conteneurs tournent simultanément (couches 2-7
   cumulées). Une alerte mémoire système basse a été rencontrée pendant les
   tests de couche 7. Si vous ajoutez de la charge de test, surveillez la RAM
   disponible (Docker Desktop alloue 7.66 Gio) et fermez les applications non
   essentielles si besoin.
2. **Grafana / Keep UI** : mots de passe admin non confirmés fonctionnels
   actuellement (voir section 2) — à vérifier/réinitialiser vous-même.
3. **Règle de corrélation Keep** (couche 6) : à créer manuellement dans l'UI
   (Correlation > New rule) — valeurs exactes dans `docs/PROGRESS.md`.
4. **Couche 1** (générateur de trafic normal/anormal dédié) n'a pas encore été
   créé formellement — les tests ont jusqu'ici généré leur propre trafic
   ad hoc via des conteneurs `curl` jetables.
5. **Makefile / scripts `make up-layer-N`** (prévus par CLAUDE.md pour la
   validation finale) : pas encore créés — actuellement on utilise directement
   `docker compose -f compose/layer-N-*.yml`.
6. **PagerDuty réel** : le provider natif Keep cible en dur l'API PagerDuty
   réelle (non redirigeable) — nécessite un vrai compte pour remplacer le
   récepteur factice (voir `docs/PROGRESS.md` couche 7 pour la procédure de
   bascule).
