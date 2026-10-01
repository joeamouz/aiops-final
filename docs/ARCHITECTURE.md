# Architecture AIOps — État des lieux et plan (Phase 0)

> Document vivant. Mis à jour à chaque couche validée. Voir `docs/PROGRESS.md` pour le
> statut courant.

## 1. Existant (audité le 2026-10-01)

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Docker Desktop (Windows, WSL2) — 8 vCPU / 7.66 Gio RAM alloués          │
│                                                                           │
│  ┌─────────────── Kubernetes (intégré) ───────────────┐                 │
│  │ namespace juice-shop                                 │                 │
│  │   deployment juice-shop (bkimminich/juice-shop:v20.2.0)              │
│  │     Service ClusterIP 10.99.141.65:3000 (pas de NodePort)            │
│  │     logs HTTP (morgan combined) -> fichier logs/access.log.<DATE>    │
│  │                 (PAS sur stdout — point d'attention couche 2)        │
│  │     stdout = messages de démarrage Winston uniquement                │
│  └───────────────────────────────────────────────────────┘             │
│                           │ joignable depuis réseau Docker               │
│                           │ "aiops_default" (testé : curl -> 200)        │
│                           ▼                                              │
│  ┌─────────────── Docker Compose "aiops" (réseau aiops_default) ──────┐ │
│  │  keep-frontend   :3000   (UI Next.js)                               │ │
│  │  keep-backend    :8080   (API FastAPI)                              │ │
│  │  keep-websocket  :6001, :9601 (Soketi / temps réel)                  │ │
│  │  postgres        (interne, non exposé)                              │ │
│  │  redis           (interne, non exposé)                              │ │
│  │  demo-app        :8000   (démo indépendante déjà branchée sur Keep) │ │
│  │  demo-monitor    (pousse des alertes synthétiques vers Keep)        │ │
│  └───────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

Fichiers compose existants (non modifiés) : `aiops/docker-compose.orangeci.yml`,
`aiops/docker-compose.demo-app.yml`. Volumes nommés : `aiops_postgres-data`,
`aiops_redis-data`, `aiops_keep-state`.

### Points d'attention relevés
- **Juice Shop tourne en Kubernetes**, pas en conteneur Docker Compose simple : pas de
  port hôte, accès via ClusterIP depuis le réseau `aiops_default` uniquement.
- **Logs HTTP de Juice Shop écrits dans un fichier interne** (pas stdout) ; image
  distroless sans shell (`exec` impossible). Nécessite une solution dédiée en couche 2
  (ex. sidecar de lecture de volume) — à valider avant toute modification du déploiement
  k8s existant.
- RAM Docker Desktop (7.66 Gio) : suffisante mais sans grande marge pour Kafka/Redpanda +
  Prometheus + Grafana + moteur ML. Alternatives légères recommandées à chaque couche.

## 2. Plan de ports (aucun conflit avec l'existant)

| Couche | Service | Port hôte | Statut |
|---|---|---|---|
| 1 | Juice Shop (k8s) | — (ClusterIP interne) | existant |
| 6 | Keep UI | 3000 | existant |
| 6 | Keep API | 8080 | existant |
| 6 | Keep WebSocket (Soketi) | 6001, 9601 | existant |
| (démo) | demo-app | 8000 | existant |
| 2 | Vector API (tap/top) | 8686 | à créer |
| 3 | Redpanda (broker externe) | 19092 | ✅ créé |
| 3 | Redpanda admin | 9644 | ✅ créé |
| 3 | Redpanda Console | 8089 | ✅ créé |
| 3 | Vector routeur (API) | 8687 | ✅ créé |
| 4 | Prometheus | 9090 | ✅ créé |
| 4 | Alertmanager | 9093 | ✅ créé |
| 4 | Grafana | **3001** (3000 pris par Keep) | ✅ créé |
| 4 | cAdvisor | 8081 | ✅ créé |
| 4 | Blackbox exporter | 9115 | ✅ créé |
| 4 | Vector métriques (prometheus_exporter) | 9598 | ✅ créé |
| 5 | Moteur prédictif (FastAPI) | 8001 (8000 pris par demo-app) | à créer |

## 3. Plan réseau
Réseau Docker partagé `aiops_default` (existant) réutilisé par toutes les nouvelles
couches, pour pouvoir joindre Keep et le ClusterIP de Juice Shop sans modification
réseau supplémentaire.

## 4. Flux cible

```
Juice Shop (k8s) --[2 Vector]--> [3 Kafka/Redpanda] --+--> [4 Prometheus/Grafana]
                                                        +--> [5 Moteur prédictif]
                                                              |
                                                              v
                                              [6 Keep : corrélation/enrichissement]
                                                              |
                                                              v
                                              [7 Alerting : Slack / PagerDuty]
```
