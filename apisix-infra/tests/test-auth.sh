#!/usr/bin/env bash
set -euo pipefail

GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"
ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"

echo "============================================"
echo "  JWT Authentication Tests"
echo "============================================"
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

# ── 1. Verify consumers exist ──
echo "1. JWT consumers configured"
for consumer in vzone_platform vzone_admin; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "X-API-KEY: $API_KEY" \
    "$ADMIN_URL/consumers/$consumer" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "  [PASS] Consumer '$consumer' exists"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] Consumer '$consumer' not found (HTTP $code)"
    FAIL=$((FAIL + 1))
  fi
done
echo ""

# ── 2. Unauthenticated requests are rejected ──
echo "2. Unauthenticated requests → 401"
check "GET /api/v1/tracking/vehicles (no token)" "401" \
  "$GATEWAY_URL/api/v1/tracking/vehicles"
check "GET /api/v1/notifications/ (no token)" "401" \
  "$GATEWAY_URL/api/v1/notifications/"
echo ""

# ── 3. Invalid token is rejected ──
echo "3. Invalid token → 401"
check "GET with garbage token" "401" \
  -H "Authorization: Bearer invalid.token.here" \
  "$GATEWAY_URL/api/v1/tracking/vehicles"
echo ""

# ── 4. Generate valid token via sign endpoint ──
echo "4. JWT sign endpoint"
TOKEN=$(curl -s --max-time 5 \
  "$GATEWAY_URL/apisix/plugin/jwt/sign?key=vzone_platform-key" 2>/dev/null || echo "")

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] && echo "$TOKEN" | grep -q '\.'; then
  echo "  [PASS] Token generated: ${TOKEN:0:20}..."
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Could not generate token (got: $TOKEN)"
  FAIL=$((FAIL + 1))
  TOKEN=""
fi
echo ""

# ── 5. Authenticated requests succeed ──
echo "5. Authenticated requests → 200 (or 502 if backend not running)"
if [ -n "$TOKEN" ]; then
  for path in "/api/v1/tracking/vehicles" "/api/v1/notifications/"; do
    actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
      -H "Authorization: Bearer $TOKEN" \
      "$GATEWAY_URL$path" 2>/dev/null || echo "000")
    if [ "$actual" = "200" ] || [ "$actual" = "502" ]; then
      echo "  [PASS] GET $path with token (HTTP $actual — auth passed)"
      PASS=$((PASS + 1))
    else
      echo "  [FAIL] GET $path with token — expected 200/502, got $actual"
      FAIL=$((FAIL + 1))
    fi
  done
else
  echo "  [SKIP] No token available — cannot test authenticated requests"
fi
echo ""

# ── 6. Admin consumer token works ──
echo "6. Admin consumer token"
ADMIN_TOKEN=$(curl -s --max-time 5 \
  "$GATEWAY_URL/apisix/plugin/jwt/sign?key=vzone_admin-key" 2>/dev/null || echo "")

if [ -n "$ADMIN_TOKEN" ] && echo "$ADMIN_TOKEN" | grep -q '\.'; then
  actual=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$GATEWAY_URL/api/v1/tracking/vehicles" 2>/dev/null || echo "000")
  if [ "$actual" = "200" ] || [ "$actual" = "502" ]; then
    echo "  [PASS] Admin token accepted (HTTP $actual)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] Admin token rejected (HTTP $actual)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  [FAIL] Could not generate admin token"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 7. WebSocket route requires auth ──
echo "7. WebSocket route requires JWT"
ws_noauth=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGVzdA==" \
  "$GATEWAY_URL/ws/tracking" 2>/dev/null || echo "000")
if [ "$ws_noauth" = "401" ]; then
  echo "  [PASS] WebSocket without token → 401"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] WebSocket without token — expected 401, got $ws_noauth"
  FAIL=$((FAIL + 1))
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
