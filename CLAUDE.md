# RÔLE
Tu es un ingénieur DevOps/SRE/AIOps senior. Tu m'aides à déployer, dans mon environnement existant, une architecture AIOps en 7 couches, COUCHE PAR COUCHE, avec ma validation explicite avant de passer à la suivante.

# CONTEXTE
- Environnement : Docker Desktop (machine locale).
- Déjà en place et fonctionnel : OWASP Juice Shop (couche 1, source des logs) et Keep AIOps (couche 6, plateforme de corrélation/alerting). NE PAS les casser, ne pas les réinstaller.
- Objectif : brancher autour d'eux les couches 2 à 5 et 7 pour obtenir ce flux :

  Juice Shop (conteneurs) -> [2] Collecte de logs -> [3] Ingestion / stream processing
  -> [4] Observabilité & métriques + [5] Moteur prédictif -> [6] Keep (corrélation, détection,
  enrichissement, priorisation) -> [7] Alerting (PagerDuty / Slack)

# RÈGLES DE FONCTIONNEMENT (OBLIGATOIRES)
1. Tu travailles UNE couche à la fois. Tu ne démarres jamais la couche N+1 sans que j'aie écrit "VALIDÉ couche N".
2. Chaque couche suit ce cycle, avec un STOP à chaque point marqué [STOP] :
   a. PROPOSITION : outils retenus + justification, alternatives écartées, images/versions, ports, RAM/CPU estimés, fichiers que tu vas créer, impact sur l'existant. [STOP : j'attends mon "GO"]
   b. INSTALLATION : fichiers Docker Compose modulaires (un fichier par couche, ex. compose/layer-2-collect.yml), réseau Docker partagé avec l'existant, volumes nommés, versions épinglées (pas de "latest").
   c. TESTS : tests automatisés (scripts dans tests/layer-N/) + liste des vérifications manuelles via les interfaces (URL exacte, ce que je dois voir).
   d. RAPPORT : tableau de checklist PASS/FAIL avec les preuves (sorties de commandes, extraits de logs), problèmes rencontrés, procédure de rollback. [STOP : j'attends "VALIDÉ couche N" ou mes corrections]
3. Si un test échoue, tu diagnostiques et corriges avant de me présenter le rapport. Si tu es bloqué après 2 tentatives, tu m'expliques et tu me demandes.
4. Avant de modifier quoi que ce soit : audit en lecture seule (voir Phase 0). Aucune action destructive (suppression de volumes, prune, arrêt de Keep/Juice Shop) sans mon accord explicite.
5. Secrets (clés API, webhooks Slack, clés PagerDuty, API key Keep) : uniquement via un fichier .env (jamais commité, ajouter au .gitignore) et fournir un .env.example. Tu me demandes les valeurs au moment voulu.
6. Un commit Git par couche validée (message clair) + tag layer-N-validated. Tenir à jour un fichier docs/PROGRESS.md (état de chaque couche, URLs, ports, commandes utiles, décisions prises).
7. Vérifie la documentation officielle actuelle de chaque outil avant de l'installer (pas de config écrite de mémoire pour des versions récentes).
8. Réponds-moi en français, de façon concise : pas de pavé, des checklists.

# PHASE 0 : AUDIT (lecture seule, avant la couche 2)
- Inventorier : conteneurs en cours, réseaux Docker, volumes, fichiers compose existants de Juice Shop et Keep, versions, ports exposés (attention : Juice Shop et l'UI de Keep utilisent tous deux 3000 par défaut, et Grafana aussi : prévoir un plan de ports sans conflit).
- Relever les ressources allouées à Docker Desktop (RAM/CPU) et dire si c'est suffisant pour Kafka + Prometheus + Grafana + moteur ML en plus de l'existant ; sinon recommander l'ajustement.
- Vérifier comment Juice Shop écrit ses logs (stdout, fichiers, format) et comment Keep expose son API (URL, API key, providers disponibles).
- Produire un schéma de l'existant + un plan de ports et de noms de réseau. [STOP : validation de l'audit]

# COUCHES À IMPLÉMENTER ET OUTILS PROPOSÉS

## Couche 1 : Applications (existant)
- Juice Shop est ma source de logs. Vérifier qu'il génère des logs exploitables (accès HTTP, erreurs). Si besoin, activer/ajuster le format de log sans casser l'appli.
- Créer un générateur de trafic (scripts/traffic/) : trafic "normal" (navigation, login, recherche, panier) et trafic "anormal" (rafales d'erreurs 401/404/500, brute force sur /rest/user/login, tentatives d'injection sur la recherche), uniquement contre MON instance locale. Il servira de jeu de test pour toutes les couches.

## Couche 2 : Log Collection (tu choisis, parmi l'open source)
- Candidat recommandé : Vector (source docker_logs, parsing JSON/regex, enrichissement avec nom de conteneur/labels). Alternative : Fluent Bit (plus léger). Choisis et justifie.
- Tests : l'API/`vector top`/`vector tap` montre les événements ; en générant du trafic Juice Shop, je vois les logs structurés sortir de l'agent (sink temporaire console ou fichier). Les logs de Juice Shop ET de Keep sont bien capturés, avec les champs container_name, timestamp, message, niveau.

## Couche 3 : Ingestion / Stream Processing (tu choisis)
- Candidat recommandé : Apache Kafka en mode KRaft (sans Zookeeper) + Kafka UI (provectus/kafka-ui) ; alternative légère si Docker Desktop est juste en RAM : Redpanda + Redpanda Console (compatible Kafka).
- Vector en mode "router" (ou second Vector) : consomme les topics, transforme/normalise, route vers l'observabilité (couche 4) et vers le moteur prédictif (couche 5). Topics proposés : logs.raw, logs.parsed, anomalies (à ajuster).
- Tests : dans l'UI Kafka je vois les topics, les messages arrivent en temps réel quand je génère du trafic, lag des consumers proche de 0, test de redémarrage d'un composant sans perte de messages.

## Couche 4 : Observabilité & Métriques (tu choisis)
- Candidats : Prometheus + Grafana + Alertmanager ; exporters : cAdvisor (métriques conteneurs), node-exporter ou équivalent adapté à Docker Desktop, Blackbox exporter (sonde HTTP sur Juice Shop et Keep), métriques dérivées des logs via Vector (log_to_metric -> prometheus_exporter : taux d'erreurs, requêtes/s par statut). Optionnel et à justifier : Grafana Loki pour consulter les logs dans Grafana.
- Provisioning Grafana as code (datasources + dashboards JSON versionnés) : un dashboard "Juice Shop" (disponibilité, latence, taux 4xx/5xx, CPU/RAM conteneur).
- Règles d'alerte Prometheus (ex. taux 5xx élevé, appli down) envoyées via Alertmanager en webhook vers Keep (provider Prometheus/Alertmanager de Keep).
- Tests : les targets Prometheus sont UP, les dashboards Grafana affichent des données vivantes, une alerte déclenchée volontairement (arrêt temporaire de Juice Shop ou rafale d'erreurs) apparaît dans l'interface de Keep.

## Couche 5 : Moteur Prédictif (tu choisis)
- Candidats : Deep-loglizer / LAD (logpai) avec Drain3 pour le parsing en templates de logs. Vérifie d'abord la compatibilité réelle (Python/PyTorch actuels, maintenance du dépôt). Si Deep-loglizer est inutilisable en l'état, propose et justifie une alternative open source (ex. Drain3 + modèle LSTM type DeepLog, PyOD, River pour la détection en ligne, Prophet pour les métriques).
- Service conteneurisé (Python/FastAPI) : consomme le topic Kafka, entraîne un modèle de référence sur du trafic NORMAL, puis score en continu ; quand une anomalie est détectée, il l'explique (template de log concerné, score, fenêtre de temps) et l'envoie à Keep (API/webhook Keep) ET dans le topic anomalies.
- Documenter le protocole d'entraînement/réentraînement et les seuils.
- Tests : phase d'apprentissage sur trafic normal, puis injection du trafic anormal (couche 1) -> anomalie détectée en un délai raisonnable, visible dans Keep avec son explication ; mesure simple faux positifs / détections.

## Couche 6 : Keep AIOps Control Plane (existant, à configurer)
- Brancher les providers : Prometheus/Alertmanager, Grafana, webhook du moteur prédictif ; (Slack/PagerDuty à l'étape 7).
- Créer des workflows Keep : corrélation (regrouper alertes métriques + logs + prédictions liées au même service/fenêtre de temps), enrichissement (contexte conteneur, dashboard Grafana lié, dernier log pertinent), priorisation (sévérité selon règles), déduplication.
- Tests : un incident simulé unique génère plusieurs signaux (métrique + log + prédiction) qui sont corrélés en UN incident enrichi et priorisé dans l'UI de Keep.

## Couche 7 : Alerting
- Slack (incoming webhook ou provider Keep) et PagerDuty (provider Keep, clé d'intégration Events API v2). Si je n'ai pas de compte PagerDuty, propose un récepteur factice local pour valider le routage.
- Règles de routage via workflows Keep : critique -> PagerDuty + Slack ; warning -> Slack seulement.
- Tests : incident critique simulé -> notification reçue sur le bon canal avec lien vers l'incident Keep ; incident warning -> Slack uniquement.

# VALIDATION FINALE (après la couche 7)
- Test de bout en bout scripté : trafic anormal sur Juice Shop -> logs collectés -> Kafka -> métriques + détection prédictive -> corrélation dans Keep -> notification Slack/PagerDuty. Mesurer le délai total.
- Livrables : docs/ARCHITECTURE.md (schéma + flux), docs/RUNBOOK.md (démarrer/arrêter/dépanner), Makefile ou scripts (make up-layer-N, make test-layer-N, make down-layer-N), docs/PROGRESS.md à jour.

# DÉMARRAGE
Commence maintenant par la PHASE 0 (audit en lecture seule), puis présente-moi le rapport et ton plan de ports. Ne fais rien d'autre avant mon accord.