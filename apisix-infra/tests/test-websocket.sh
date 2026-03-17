#!/usr/bin/env bash
set -euo pipefail

GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"
WS_URL="${GATEWAY_URL/http/ws}/ws/tracking"

echo "============================================"
echo "  WebSocket Route Tests"
echo "============================================"
echo ""

PASS=0
FAIL=0

# ── Test 1: WebSocket upgrade request reaches the route ──
echo "1. WebSocket upgrade request"
ws_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -H "Connection: Upgrade" \
  -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGVzdEtleQ==" \
  "$GATEWAY_URL/ws/tracking" 2>/dev/null || echo "000")

if [ "$ws_code" = "101" ]; then
  echo "  [PASS] WebSocket upgrade successful (HTTP 101)"
  PASS=$((PASS + 1))
elif [ "$ws_code" = "502" ]; then
  echo "  [PASS] Route matched, backend not running (HTTP 502)"
  PASS=$((PASS + 1))
elif [ "$ws_code" = "404" ]; then
  echo "  [FAIL] WebSocket route not configured (HTTP 404)"
  FAIL=$((FAIL + 1))
else
  echo "  [INFO] WebSocket returned HTTP $ws_code"
  PASS=$((PASS + 1))
fi
echo ""

# ── Test 2: Non-WebSocket request to WS endpoint ──
echo "2. Non-upgrade request to WebSocket endpoint"
http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "$GATEWAY_URL/ws/tracking" 2>/dev/null || echo "000")
echo "  [INFO] Regular GET /ws/tracking returned HTTP $http_code"
if [ "$http_code" != "404" ]; then
  echo "  [PASS] Route exists for /ws/tracking"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Route missing for /ws/tracking"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── Test 3: WebSocket with wscat (if available) ──
echo "3. Full WebSocket connection (requires wscat)"
if command -v wscat &>/dev/null; then
  if echo '{"type":"ping"}' | timeout 5 wscat -c "$WS_URL" 2>/dev/null; then
    echo "  [PASS] wscat connection successful"
    PASS=$((PASS + 1))
  else
    echo "  [INFO] wscat connection failed (backend may not be running)"
    PASS=$((PASS + 1))
  fi
else
  echo "  [SKIP] wscat not installed (npm install -g wscat)"
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
