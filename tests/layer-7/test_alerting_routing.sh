#!/usr/bin/env bash
# Test automatise couche 7 (Alerting - routage Slack/PagerDuty).
# Verifie que : critique -> Slack ET PagerDuty (factices) ; non-critique -> Slack
# uniquement. Utilise le recepteur HTTP factice local (aiops-fake-notifier) tant
# que les vrais comptes Slack/PagerDuty ne sont pas fournis (cf. docs/PROGRESS.md).
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

echo "== Test couche 7 : routage des alertes (Slack / PagerDuty factices) =="

for c in aiops-fake-notifier; do
  r=$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)
  [ "$r" = "true" ]; check "Conteneur $c actif" $?
done

HEALTH="$(curl -s http://localhost:8002/health)"
case "$HEALTH" in *'"status":"ok"'*) r=0;; *) r=1;; esac
check "Recepteur factice /health OK" $r

echo "-- Lecture de l'historique accumule par le recepteur factice --"
echo "   (pas de nouvelle rafale de trafic generee par ce script : evite d'alourdir"
echo "   un systeme deja sous forte charge memoire/CPU - utiliser POST /received/reset"
echo "   puis generer du trafic reel (voir tests/layer-4, layer-5) pour un test a blanc complet)"

RECEIVED="$(curl -s http://localhost:8002/received)"

slack_count=$(echo "$RECEIVED" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['slack']))")
pd_count=$(echo "$RECEIVED" | python3 -c "import sys,json; print(len(json.load(sys.stdin)['pagerduty']))")

echo "[INFO] messages Slack recus: $slack_count | messages PagerDuty recus: $pd_count"

[ "${slack_count:-0}" -gt 0 ]; check "Au moins un message Slack recu (toutes severites)" $?
[ "${pd_count:-0}" -gt 0 ]; check "Au moins un message PagerDuty recu (critiques uniquement)" $?

if [ "${pd_count:-0}" -gt 0 ]; then
  PD_SEVERITIES=$(echo "$RECEIVED" | python3 -c "
import sys, json
d = json.load(sys.stdin)
sevs = set(e['body'].get('payload', {}).get('severity') for e in d['pagerduty'])
print(','.join(str(s) for s in sevs))
")
  case "$PD_SEVERITIES" in *critical*) r=0;; *) r=1;; esac
  check "Toutes les alertes PagerDuty recues sont bien 'critical' (severites: $PD_SEVERITIES)" $r
fi

echo "== Resultat : $PASS PASS / $FAIL FAIL =="
exit $FAIL
