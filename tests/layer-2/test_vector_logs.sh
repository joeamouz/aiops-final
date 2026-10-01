#!/usr/bin/env bash
# Test automatisé couche 2 (Log Collection - Vector).
# Vérifie : conteneur up, capture des logs Keep, champs enrichis presents,
# et documente l'absence de logs d'acces HTTP Juice Shop (limitation connue).
set -uo pipefail

PASS=0
FAIL=0

check() {
  local desc="$1" result="$2"
  if [ "$result" = "0" ]; then
    echo "[PASS] $desc"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $desc"
    FAIL=$((FAIL+1))
  fi
}

echo "== Test couche 2 : collecte de logs (Vector) =="

running=$(docker inspect -f '{{.State.Running}}' aiops-vector 2>/dev/null)
[ "$running" = "true" ]; check "Conteneur aiops-vector actif" $?

curl -s -o /dev/null http://localhost:8080/healthcheck
sleep 2

# Capture unique (evite le piege pipefail + grep -q -> SIGPIPE sur docker logs)
VECTOR_LOGS="$(docker logs aiops-vector 2>&1)"

case "$VECTOR_LOGS" in *'"app":"keep"'*) r=0;; *) r=1;; esac
check "Logs Keep captures par Vector (champ app=keep)" $r

case "$VECTOR_LOGS" in *'"container_name":"aiops-keep-backend-1"'*) r=0;; *) r=1;; esac
check "Champ container_name present" $r

case "$VECTOR_LOGS" in *'"timestamp":'*) r=0;; *) r=1;; esac
check "Champ timestamp present" $r

case "$VECTOR_LOGS" in *'"level":"info"'*) r=0;; *) r=1;; esac
check "Champ level (niveau) correctement extrait" $r

JUICE_IP=$(kubectl get svc -n juice-shop juice-shop -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$JUICE_IP" ]; then
  docker run --rm --network aiops_default curlimages/curl:8.10.1 sh -c "
    curl -s -o /dev/null http://$JUICE_IP:3000/
    curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/search?q=test
    curl -s -o /dev/null -X POST http://$JUICE_IP:3000/rest/user/login
  " 2>/dev/null
  sleep 4
  VECTOR_LOGS2="$(docker logs aiops-vector 2>&1)"

  case "$VECTOR_LOGS2" in *'"app":"juice-shop"'*) r=0;; *) r=1;; esac
  check "Logs Juice Shop captures via sidecar access-log-shipper (Option A)" $r

  case "$VECTOR_LOGS2" in *'io.kubernetes.container.name":"access-log-shipper"'*) r=0;; *) r=1;; esac
  check "Sidecar access-log-shipper identifie dans les logs" $r

  case "$VECTOR_LOGS2" in *'HTTP/1.1\" 401'*) r=0;; *) r=1;; esac
  check "Code de statut HTTP (401 login) visible dans le log d'acces" $r
fi

echo "== Resultat : $PASS PASS / $FAIL FAIL =="
exit $FAIL
