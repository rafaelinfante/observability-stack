#!/usr/bin/env bash
# Prove the alerting path end to end: stop the service, watch ServiceInstanceDown
# go pending -> firing in Prometheus, reach Alertmanager, and hit the receiver.
# Then bring the service back. Run it against a stack that's already up.
#
# Requires: curl, jq, docker compose.
set -uo pipefail

PROM="${PROM_URL:-http://localhost:9090}"
AM="${AM_URL:-http://localhost:9093}"

echo "Stopping the service to trigger ServiceInstanceDown..."
docker compose stop payment-gateway-service >/dev/null

echo "Waiting for the alert to fire in Prometheus (rule has for: 1m)..."
state=""
for ((i = 0; i < 40; i++)); do
  state=$(curl -fsS "$PROM/api/v1/alerts" \
    | jq -r '.data.alerts[] | select(.labels.alertname=="ServiceInstanceDown") | .state' 2>/dev/null | head -1)
  printf '  [%3ds] state=%s\n' "$((i * 6))" "${state:-none}"
  [ "$state" = "firing" ] && break
  sleep 6
done

ok=0
if [ "$state" = "firing" ]; then echo "  -> Prometheus: FIRING"; else echo "  -> Prometheus never reached firing"; ok=1; fi

echo "Waiting for Alertmanager + receiver delivery (group_wait 30s)..."
sleep 40
am=$(curl -fsS "$AM/api/v2/alerts" | jq -r '[.[] | select(.labels.alertname=="ServiceInstanceDown")] | length')
[ "${am:-0}" -gt 0 ] && echo "  -> Alertmanager: active ($am)" || { echo "  -> not in Alertmanager"; ok=1; }
recv=$(docker compose logs --tail 200 alert-logger 2>&1 | grep -c 'ServiceInstanceDown')
[ "${recv:-0}" -gt 0 ] && echo "  -> Receiver got the webhook ($recv line(s))" || { echo "  -> receiver got nothing"; ok=1; }

echo "Restarting the service..."
docker compose start payment-gateway-service >/dev/null

echo
[ "$ok" -eq 0 ] && echo "ALERT DEMO PASSED" || echo "ALERT DEMO INCOMPLETE"
exit "$ok"
