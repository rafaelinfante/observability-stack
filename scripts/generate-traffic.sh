#!/usr/bin/env bash
# Drive the payments API through the built-in mock gateway so the dashboards have
# something to show: successful charges, declines, a manual capture+refund, reads
# and a 404. No keys required.
#
#   ./scripts/generate-traffic.sh [base-url] [rounds]
set -euo pipefail

BASE="${1:-http://localhost:8080}"
ROUNDS="${2:-20}"

post() { curl -fsS -o /dev/null -X POST "$BASE$1" -H 'Content-Type: application/json' "${@:2}"; }

echo "Generating $ROUNDS rounds of traffic against $BASE"
for i in $(seq 1 "$ROUNDS"); do
  # successful auto-capture (idempotency key makes replays safe)
  post /api/v1/payments -H "Idempotency-Key: traffic-$i" \
    -d "{\"amount\": $((1000 + RANDOM % 9000)), \"currency\": \"EUR\", \"description\": \"order $i\"}"

  # a declined charge (mock gateway declines this token)
  post /api/v1/payments -d '{"amount": 750, "currency": "EUR", "paymentMethodToken": "tok_decline"}' || true

  # authorize-only, then capture and partially refund
  pid=$(curl -fsS -X POST "$BASE/api/v1/payments" -H 'Content-Type: application/json' \
        -d '{"amount": 2500, "currency": "EUR", "captureMethod": "MANUAL"}' \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  if [ -n "$pid" ]; then
    post "/api/v1/payments/$pid/capture" || true
    post "/api/v1/payments/$pid/refund" -d '{"amount": 500}' || true
    curl -fsS -o /dev/null "$BASE/api/v1/payments/$pid/events" || true
  fi

  # reads + a 404
  curl -fsS -o /dev/null "$BASE/api/v1/payments?page=0&size=5" || true
  curl -fsS -o /dev/null "$BASE/api/v1/payments/00000000-0000-0000-0000-000000000000" || true
done
echo "Done."
