# AIOps Final — Architecture AIOps en 7 couches

Déploiement d'une architecture AIOps complète autour d'[OWASP Juice Shop](https://owasp-juice.shop/)
(source de logs) et de [Keep](https://github.com/keephq/keep) (plateforme de
corrélation/alerting), sur Docker Desktop local.

```
Juice Shop (k8s) → [2] Collecte de logs → [3] Ingestion (Kafka/Redpanda)
→ [4] Observabilité & métriques + [5] Moteur prédictif (ML)
→ [6] Keep (corrélation, enrichissement, priorisation) → [7] Alerting (Slack/PagerDuty)
```

## Démarrage rapide

**Prérequis** : Docker Desktop (avec Kubernetes activé), Juice Shop et Keep déjà
déployés (voir `aiops/README.md` pour la stack Keep — non incluse dans ce dépôt,
dépôt séparé). ~7-8 Gio de RAM allouée à Docker Desktop recommandés.

```bash
# Démarrer une couche (exemple : observabilité)
docker compose -f compose/layer-4-observability.yml up -d

# Vérifier son bon fonctionnement
bash tests/layer-4/test_observability.sh

# Arrêter une couche
docker compose -f compose/layer-4-observability.yml down
```

Chaque couche a son propre fichier `compose/layer-N-*.yml` et son script de test
`tests/layer-N/*.sh`.

## Documentation

| Fichier | Contenu |
|---|---|
| **[docs/RUNBOOK.md](docs/RUNBOOK.md)** | **Commencez ici** : récapitulatif des couches, toutes les URLs d'accès, identifiants, commandes utiles, points d'attention |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Schéma de l'existant, plan de ports, flux cible |
| [docs/PROGRESS.md](docs/PROGRESS.md) | Détail technique complet par couche : choix d'outils, tests, bugs rencontrés et corrigés, preuves |
| [CLAUDE.md](CLAUDE.md) | Cahier des charges original du projet |

## Structure du dépôt

```
compose/      Fichiers Docker Compose, un par couche (layer-2 à layer-7)
services/     Services applicatifs custom (ml-engine, fake-notifier)
tests/        Scripts de test automatisés, un dossier par couche
k8s/          Patch Kubernetes (sidecar de logs Juice Shop, couche 2)
scripts/      Scripts d'administration ponctuels (ex. Keep)
docs/         Documentation (runbook, architecture, suivi d'avancement)
```

## État des couches

| Couche | Statut |
|---|---|
| 2 — Collecte de logs (Vector) | ✅ Validée |
| 3 — Ingestion (Redpanda) | ✅ Validée |
| 4 — Observabilité (Prometheus/Grafana/Loki) | ✅ Validée |
| 5 — Moteur prédictif (Drain3 + River) | ✅ Validée |
| 6 — Keep (providers, workflows) | ⚠️ Quasi-complète |
| 7 — Alerting (Slack/PagerDuty) | ✅ Testée |

Détail complet et preuves de test : voir [docs/PROGRESS.md](docs/PROGRESS.md).

## Notes importantes

- **Secrets** : jamais committés. Voir `.gitignore` et `docs/RUNBOOK.md` section
  "Secrets" pour savoir où ils vivent (`aiops/.env`, non inclus dans ce dépôt).
- **`aiops/`** (stack Keep) et **`juice-shop/`** (application cible) sont des
  dépôts upstream séparés, clonés localement mais **non inclus** dans ce dépôt
  (voir `.gitignore`) — ils doivent être déployés indépendamment au préalable.
- Les couches Slack/PagerDuty de la couche 7 utilisent actuellement un
  **récepteur HTTP factice local** (pas de comptes tiers réels) — voir
  `docs/PROGRESS.md` (couche 7) pour la procédure de bascule vers de vrais
  comptes.
