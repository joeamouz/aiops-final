#!/usr/bin/env bash
# Test automatise couche 3 (Ingestion / Stream Processing - Redpanda + Vector router).
set -uo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "[PASS] $desc"; PASS=$((PASS+1))
  else
    echo "[FAIL] $desc"; FAIL=$((FAIL+1))
  fi
}

echo "== Test couche 3 : ingestion (Redpanda + Vector router) =="

running=$(docker inspect -f '{{.State.Running}}' aiops-redpanda 2>/dev/null)
[ "$running" = "true" ]; check "Conteneur aiops-redpanda actif" $?

health="$(docker exec aiops-redpanda rpk cluster health 2>&1)"
case "$health" in *"Healthy:                          true"*) r=0;; *) r=1;; esac
check "Cluster Redpanda healthy" $r

topics="$(docker exec aiops-redpanda rpk topic list 2>&1)"
for t in logs.raw logs.parsed anomalies; do
  case "$topics" in *"$t"*) r=0;; *) r=1;; esac
  check "Topic $t present" $r
done

router_running=$(docker inspect -f '{{.State.Running}}' aiops-vector-router 2>/dev/null)
[ "$router_running" = "true" ]; check "Conteneur aiops-vector-router actif" $?

# Generer du trafic Juice Shop normal + anormal (erreur produit inexistant -> 500, login -> 401)
JUICE_IP=$(kubectl get svc -n juice-shop juice-shop -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$JUICE_IP" ]; then
  docker run --rm --network aiops_default curlimages/curl:8.10.1 sh -c "
    curl -s -o /dev/null http://$JUICE_IP:3000/
    curl -s -o /dev/null -X POST http://$JUICE_IP:3000/rest/user/login
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/9999999
  " 2>/dev/null
  sleep 6

  PARSED="$(timeout 20 docker exec aiops-redpanda rpk topic consume logs.parsed --num 800 -o 0 2>&1)"

  case "$PARSED" in *'\"http_status\":401'*) r=0;; *) r=1;; esac
  check "logs.parsed contient http_status=401 (login)" $r

  case "$PARSED" in *'\"http_status\":500'*) r=0;; *) r=1;; esac
  check "logs.parsed contient http_status=500 (erreur produit)" $r

  case "$PARSED" in *'\"level\":\"error\"'*) r=0;; *) r=1;; esac
  check "Niveau 'error' assigne automatiquement pour un 500" $r
fi

# Lag du consumer group vector-router
LAG_LINE="$(docker exec aiops-redpanda rpk group describe vector-router 2>&1 | grep 'TOTAL-LAG')"
echo "[INFO] $LAG_LINE"

echo "== Resultat : $PASS PASS / $FAIL FAIL =="
exit $FAIL
