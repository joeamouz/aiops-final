#!/usr/bin/env bash
# Test automatise couche 4 (Observabilite & Metriques).
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

echo "== Test couche 4 : observabilite (Prometheus/Grafana/Alertmanager/cAdvisor/Blackbox) =="

for c in aiops-prometheus aiops-grafana aiops-alertmanager aiops-cadvisor aiops-blackbox-exporter aiops-vector-metrics; do
  r=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)
  [ "$r" = "true" ]; check "Conteneur $c actif" $?
done

TARGETS="$(curl -s http://localhost:9090/api/v1/targets)"
for job in prometheus cadvisor vector-metrics blackbox-http; do
  up_count=$(echo "$TARGETS" | python3 -c "
import sys,json
d=json.load(sys.stdin)
n=sum(1 for t in d['data']['activeTargets'] if t['labels'].get('job')=='$job' and t['health']=='up')
print(n)
")
  [ "${up_count:-0}" -gt 0 ]; check "Au moins une target '$job' UP" $?
done

PROBES="$(curl -s 'http://localhost:9090/api/v1/query?query=probe_success')"
echo "$PROBES" | grep -q '"app":"juice-shop"'; check "probe_success expose pour juice-shop" $?
echo "$PROBES" | grep -q '"app":"keep"'; check "probe_success expose pour keep" $?

RULES="$(curl -s http://localhost:9090/api/v1/rules)"
for rule in JuiceShopDown KeepDown JuiceShopHighErrorRate; do
  echo "$RULES" | grep -q "\"$rule\""; check "Regle d'alerte '$rule' chargee" $?
done

# Declenchement reel d'une alerte (rafale 401/500) et verification bout-en-bout vers Keep
JUICE_IP=$(kubectl get svc -n juice-shop juice-shop -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
if [ -n "$JUICE_IP" ]; then
  docker rm -f traffic-gen-test >/dev/null 2>&1
  docker run -d --name traffic-gen-test --network aiops_default curlimages/curl:8.10.1 sh -c "
    while true; do
      curl -s -o /dev/null -X POST http://$JUICE_IP:3000/rest/user/login
      curl -s -o /dev/null http://$JUICE_IP:3000/rest/products/9999999
      sleep 1
    done
  " >/dev/null

  FIRED=1
  for i in $(seq 1 18); do
    STATE=$(curl -s http://localhost:9090/api/v1/rules | python3 -c "
import sys,json
d=json.load(sys.stdin)
for g in d['data']['groups']:
    for r in g['rules']:
        if r['name']=='JuiceShopHighErrorRate':
            print(r['state'])
" 2>/dev/null)
    if [ "$STATE" = "firing" ]; then FIRED=0; break; fi
    sleep 5
  done
  check "Alerte JuiceShopHighErrorRate passee en 'firing' (rafale reelle)" $FIRED

  if [ "$FIRED" = "0" ]; then
    AM_ALERTS="$(curl -s http://localhost:9093/api/v2/alerts)"
    case "$AM_ALERTS" in *'JuiceShopHighErrorRate'*) r=0;; *) r=1;; esac
    check "Alertmanager a recu l'alerte" $r

    sleep 5
    # Fenetre large : Alertmanager deduplique les notifications pour une alerte deja
    # active (repeat_interval: 5m) - une livraison recente suffit comme preuve.
    KEEP_LOG="$(docker logs aiops-keep-backend-1 --since 15m 2>&1)"
    case "$KEEP_LOG" in *'event/prometheus'*'202'*) r=0;; *) r=1;; esac
    check "Webhook Alertmanager -> Keep livre avec succes (202, deduplication Alertmanager normale sinon)" $r
  fi

  docker rm -f traffic-gen-test >/dev/null 2>&1
fi

echo "== Resultat : $PASS PASS / $FAIL FAIL =="
exit $FAIL
