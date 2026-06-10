#!/usr/bin/env bash
# End-to-end smoke test for the whole stack. Assumes `docker compose up -d` has
# already run. Waits for the service, drives a little traffic, then asserts each
# pillar is actually working. Exits non-zero on the first hard failure.
#
# Requires: curl, jq.
set -uo pipefail

PROM="${PROM_URL:-http://localhost:9090}"
GRAFANA="${GRAFANA_URL:-http://localhost:3000}"
LOKI="${LOKI_URL:-http://localhost:3100}"
TEMPO="${TEMPO_URL:-http://localhost:3200}"
SERVICE="${SERVICE_URL:-http://localhost:8080}"

fail=0
pass() { echo "  PASS  $1"; }
bad()  { echo "  FAIL  $1"; fail=1; }

# wait_for <name> <url> <seconds>
wait_for() {
  local name="$1" url="$2" timeout="${3:-90}" i
  for ((i = 0; i < timeout; i += 3)); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then echo "  up    $name (${i}s)"; return 0; fi
    sleep 3
  done
  echo "  TIMEOUT waiting for $name at $url"; return 1
}

echo "== waiting for components =="
wait_for "service"    "$SERVICE/actuator/health" 120 || bad "service health endpoint"
wait_for "prometheus" "$PROM/-/ready"            60  || bad "prometheus ready"
wait_for "grafana"    "$GRAFANA/api/health"      60  || bad "grafana ready"
wait_for "loki"       "$LOKI/ready"              90  || bad "loki ready"
wait_for "tempo"      "$TEMPO/ready"             90  || bad "tempo ready"

echo "== generating traffic =="
"$(dirname "$0")/generate-traffic.sh" "$SERVICE" 8 >/dev/null 2>&1 || true
sleep 20  # let one scrape + ingestion cycle pass

echo "== metrics: prometheus targets =="
targets=$(curl -fsS "$PROM/api/v1/targets")
total=$(echo "$targets" | jq '.data.activeTargets | length')
up=$(echo "$targets" | jq '[.data.activeTargets[] | select(.health=="up")] | length')
echo "$targets" | jq -r '.data.activeTargets[] | "    \(.labels.job): \(.health)"'
if [ "$up" -gt 0 ] && [ "$up" -eq "$total" ]; then pass "all $up/$total scrape targets up"; else bad "$up/$total targets up"; fi

echo "== metrics: service histogram (p99 needs this) =="
service_metrics=$(curl -fsS "$SERVICE/actuator/prometheus")
if [[ "$service_metrics" == *http_server_requests_seconds_bucket* ]]; then
  pass "http_server_requests histogram exposed"
else
  bad "http_server_requests histogram missing"
fi

echo "== visualization: grafana =="
if curl -fsS "$GRAFANA/api/health" | jq -e '.database == "ok"' >/dev/null; then pass "grafana health ok"; else bad "grafana health"; fi

echo "== logs: loki has service logs =="
# Alloy discovers containers and starts shipping logs a little after startup, so the
# first query right after `compose up` can race it — retry for up to 60s before failing.
loki_streams=0
for ((i = 0; i < 60; i += 5)); do
  loki_streams=$(curl -fsS -G "$LOKI/loki/api/v1/query_range" \
    --data-urlencode 'query={service_name="payment-gateway-service"}' \
    --data-urlencode 'limit=1' --data-urlencode 'since=15m' | jq '.data.result | length')
  [ "${loki_streams:-0}" -gt 0 ] && break
  sleep 5
done
if [ "${loki_streams:-0}" -gt 0 ]; then pass "loki is receiving service logs"; else bad "no logs in loki (waited 60s)"; fi

echo "== traces: tempo has service traces =="
traces=$(curl -fsS -G "$TEMPO/api/search" \
  --data-urlencode 'q={resource.service.name="payment-gateway-service"}' \
  --data-urlencode 'limit=5' | jq '.traces | length')
if [ "${traces:-0}" -gt 0 ]; then pass "tempo has $traces trace(s)"; else bad "no traces in tempo"; fi

echo
if [ "$fail" -eq 0 ]; then echo "SMOKE TEST PASSED"; else echo "SMOKE TEST FAILED"; fi
exit "$fail"
