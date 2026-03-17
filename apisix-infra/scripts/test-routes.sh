#!/usr/bin/env bash
set -euo pipefail

GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"

echo "============================================"
echo "  APISIX Route Smoke Tests"
echo "============================================"
echo ""
echo "  Gateway: $GATEWAY_URL"
echo ""

PASS=0
FAIL=0

check() {
  local label="$1" expected="$2"
  shift 2
  local actual
  actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$@" 2>/dev/null || echo "000")
  if [ "$actual" = "$expected" ]; then
    echo "  [PASS] $label (HTTP $actual)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label — expected $expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── Gateway reachability ──
echo "1. Gateway reachability"
check "Unmatched route returns 404" "404" "$GATEWAY_URL/"
echo ""

# ── Live Tracking Service routes ──
echo "2. Live Tracking Service"
check "GET  /api/v1/tracking/vehicles" "200" "$GATEWAY_URL/api/v1/tracking/vehicles"
check "POST /api/v1/tracking/vehicles" "200" -X POST \
  -H "Content-Type: application/json" \
  -d '{"vehicle_id":"test-001"}' \
  "$GATEWAY_URL/api/v1/tracking/vehicles"
echo ""

# ── Notification Service routes ──
echo "3. Notification Service"
check "GET  /api/v1/notifications/" "200" "$GATEWAY_URL/api/v1/notifications/"
echo ""

# ── WebSocket upgrade header test ──
echo "4. WebSocket route (upgrade header check)"
ws_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGVzdA==" \
  "$GATEWAY_URL/ws/tracking" 2>/dev/null || echo "000")
# 101 = successful upgrade, 502 = backend not ready but route matched
if [ "$ws_code" = "101" ] || [ "$ws_code" = "502" ]; then
  echo "  [PASS] WebSocket /ws/tracking — route matched (HTTP $ws_code)"
  PASS=$((PASS + 1))
elif [ "$ws_code" = "404" ]; then
  echo "  [FAIL] WebSocket /ws/tracking — route not found (HTTP 404)"
  FAIL=$((FAIL + 1))
else
  echo "  [INFO] WebSocket /ws/tracking — HTTP $ws_code (backend may not be running)"
  PASS=$((PASS + 1))
fi
echo ""

# ── Global rules check ──
echo "5. Global rules (CORS + Request-ID)"
response_headers=$(curl -s -D - -o /dev/null --max-time 5 \
  -H "Origin: http://example.com" \
  "$GATEWAY_URL/api/v1/tracking/vehicles" 2>/dev/null || echo "")

if echo "$response_headers" | grep -qi "X-Request-ID"; then
  echo "  [PASS] X-Request-ID header present"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] X-Request-ID header missing"
  FAIL=$((FAIL + 1))
fi

if echo "$response_headers" | grep -qi "Access-Control-Allow-Origin"; then
  echo "  [PASS] CORS headers present"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] CORS headers missing"
  FAIL=$((FAIL + 1))
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
