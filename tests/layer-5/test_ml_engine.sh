#!/usr/bin/env bash
# Test automatise couche 5 (Moteur Predictif - ml-engine).
# Cycle complet : reset -> apprentissage (trafic normal) -> scoring -> injection
# d'une anomalie reelle -> verification de la detection et de la propagation
# (topic Kafka "anomalies" + alerte Keep).
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

echo "== Test couche 5 : moteur predictif (ml-engine) =="

running=$(docker inspect -f '{{.State.Running}}' aiops-ml-engine 2>/dev/null)
[ "$running" = "true" ]; check "Conteneur aiops-ml-engine actif" $?

HEALTH="$(curl -s http://localhost:8001/health)"
case "$HEALTH" in *'"status":"ok"'*) r=0;; *) r=1;; esac
check "Endpoint /health OK" $r

JUICE_IP=$(kubectl get svc -n juice-shop juice-shop -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -z "$JUICE_IP" ]; then
  echo "[FAIL] ClusterIP Juice Shop introuvable, test interrompu"
  exit 1
fi

echo "-- Reinitialisation du modele (mode apprentissage) --"
curl -s -X POST http://localhost:8001/train/start >/dev/null

docker rm -f ml-test-normal-traffic >/dev/null 2>&1
docker run -d --name ml-test-normal-traffic --network aiops_default curlimages/curl:8.10.1 sh -c "
  while true; do
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/search?q=apple
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/1
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/2
    sleep 1
  done
" >/dev/null

echo "-- Phase d'apprentissage (~110s, trafic normal) --"
sleep 110

STATUS_LEARN="$(curl -s http://localhost:8001/status)"
events_learned=$(echo "$STATUS_LEARN" | python3 -c "import sys,json; print(json.load(sys.stdin)['events_processed'])" 2>/dev/null)
[ "${events_learned:-0}" -gt 50 ]; check "Au moins 50 evenements traites pendant l'apprentissage (obtenu: ${events_learned:-0})" $?

docker rm -f ml-test-normal-traffic >/dev/null 2>&1

echo "-- Passage en mode scoring --"
STOP_RESP="$(curl -s -X POST http://localhost:8001/train/stop)"
case "$STOP_RESP" in *'"mode":"scoring"'*) r=0;; *) r=1;; esac
check "Passage en mode scoring confirme" $r

echo "-- Injection d'une anomalie reelle (rafale 500/401) --"
docker run --rm --network aiops_default curlimages/curl:8.10.1 sh -c "
  for i in \$(seq 1 20); do
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/9999999
    curl -s -o /dev/null -X POST http://$JUICE_IP:3000/rest/user/login
  done
" >/dev/null

FOUND=1
for i in $(seq 1 6); do
  sleep 5
  ST="$(curl -s http://localhost:8001/status)"
  anomalies=$(echo "$ST" | python3 -c "import sys,json; print(json.load(sys.stdin)['anomalies_detected'])" 2>/dev/null)
  if [ "${anomalies:-0}" -gt 0 ]; then FOUND=0; break; fi
done
check "Anomalie detectee en un delai raisonnable (<= ~40s apres l'injection)" $FOUND

if [ "$FOUND" = "0" ]; then
  echo "$ST" | python3 -c "
import sys, json
d = json.load(sys.stdin)
la = d.get('last_anomaly') or {}
print('[INFO] kind =', la.get('kind'))
print('[INFO] score =', la.get('score'))
print('[INFO] window =', la.get('window_start'), '->', la.get('window_end'))
"

  sleep 3
  KEEP_LOG="$(docker logs aiops-keep-backend-1 --since 2m 2>&1)"
  case "$KEEP_LOG" in *'/alerts/event'*'202'*) r=0;; *) r=1;; esac
  check "Anomalie transmise a Keep (POST /alerts/event -> 202)" $r
fi

docker rm -f ml-test-normal-traffic >/dev/null 2>&1

echo "== Resultat : $PASS PASS / $FAIL FAIL =="
exit $FAIL
