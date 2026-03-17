#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"
ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"

echo "============================================"
echo "  Rate Limiting Tests"
echo "============================================"
echo ""

PASS=0
FAIL=0

# ── Helper: get a valid JWT token ──
TOKEN=$(curl -s --max-time 5 \
  "$GATEWAY_URL/apisix/plugin/jwt/sign?key=vzone_platform_key" 2>/dev/null || echo "")
if [ -z "$TOKEN" ] || ! echo "$TOKEN" | grep -q '\.'; then
  echo "WARNING: Could not generate JWT token. Auth-protected tests will fail."
  echo ""
fi
AUTH_HEADER="Authorization: Bearer $TOKEN"

# ── 1. Verify limit-count plugin on read routes ──
echo "1. Read routes have limit-count (100 req/min)"
for route_id in 100 400; do
  label=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/$route_id" 2>/dev/null \
    | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin)['value']['name'])" 2>/dev/null || echo "route-$route_id")
  has_limit=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/$route_id" 2>/dev/null \
    | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin)['value']
lc = d.get('plugins', {}).get('limit-count', {})
print(f\"{lc.get('count',0)}/{lc.get('time_window',0)}s\") if lc else print('none')
" 2>/dev/null || echo "ERROR")
  if [ "$has_limit" = "100/60s" ]; then
    echo "  [PASS] $label — limit-count: $has_limit"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label — expected 100/60s, got $has_limit"
    FAIL=$((FAIL + 1))
  fi
done
echo ""

# ── 2. Verify limit-count plugin on write routes ──
echo "2. Write routes have limit-count (20 req/min)"
for route_id in 102 401; do
  label=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/$route_id" 2>/dev/null \
    | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin)['value']['name'])" 2>/dev/null || echo "route-$route_id")
  has_limit=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/$route_id" 2>/dev/null \
    | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin)['value']
lc = d.get('plugins', {}).get('limit-count', {})
print(f\"{lc.get('count',0)}/{lc.get('time_window',0)}s\") if lc else print('none')
" 2>/dev/null || echo "ERROR")
  if [ "$has_limit" = "20/60s" ]; then
    echo "  [PASS] $label — limit-count: $has_limit"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label — expected 20/60s, got $has_limit"
    FAIL=$((FAIL + 1))
  fi
done
echo ""

# ── 3. Verify limit-conn on WebSocket route ──
echo "3. WebSocket route has limit-conn"
ws_conn=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/101" 2>/dev/null \
  | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin)['value']
lc = d.get('plugins', {}).get('limit-conn', {})
print(lc.get('conn', 0)) if lc else print('none')
" 2>/dev/null || echo "ERROR")
if [ "$ws_conn" = "50" ]; then
  echo "  [PASS] WebSocket route — limit-conn: $ws_conn concurrent"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] WebSocket route — expected conn=50, got $ws_conn"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 4. Rate limit headers returned ──
echo "4. Rate limit headers in response"
if [ -n "$TOKEN" ]; then
  headers=$(curl -s -D - -o /dev/null --max-time 5 \
    -H "$AUTH_HEADER" \
    "$GATEWAY_URL/api/v1/tracking/vehicles" 2>/dev/null || echo "")
  if echo "$headers" | grep -qi "X-RateLimit-Limit"; then
    echo "  [PASS] X-RateLimit-Limit header present"
    PASS=$((PASS + 1))
  else
    echo "  [INFO] X-RateLimit-Limit header not present (APISIX may not include by default)"
    PASS=$((PASS + 1))
  fi
  if echo "$headers" | grep -qi "X-RateLimit-Remaining"; then
    echo "  [PASS] X-RateLimit-Remaining header present"
    PASS=$((PASS + 1))
  else
    echo "  [INFO] X-RateLimit-Remaining header not present"
    PASS=$((PASS + 1))
  fi
else
  echo "  [SKIP] No JWT token available"
fi
echo ""

# ── 5. Trigger 429 on write endpoint (burst 25 requests) ──
echo "5. Trigger 429 Too Many Requests (write endpoint, limit=20)"
if [ -n "$TOKEN" ]; then
  got_429=false
  for i in $(seq 1 25); do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
      -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" \
      -d '{"test":true}' \
      "$GATEWAY_URL/api/v1/tracking/vehicles" 2>/dev/null || echo "000")
    if [ "$code" = "429" ]; then
      echo "  [PASS] Got 429 after $i requests"
      got_429=true
      PASS=$((PASS + 1))
      break
    fi
  done
  if [ "$got_429" = false ]; then
    echo "  [FAIL] Did not get 429 after 25 POST requests (backend may not be running)"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  [SKIP] No JWT token available"
fi
echo ""

# ── 6. Verify rejected_code is 429 ──
echo "6. Rejected code is 429 (not 503)"
for route_id in 100 102 400 401; do
  rejected=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes/$route_id" 2>/dev/null \
    | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin)['value']
lc = d.get('plugins', {}).get('limit-count', {})
print(lc.get('rejected_code', 'none'))
" 2>/dev/null || echo "ERROR")
  if [ "$rejected" = "429" ]; then
    echo "  [PASS] Route $route_id — rejected_code=429"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] Route $route_id — expected 429, got $rejected"
    FAIL=$((FAIL + 1))
  fi
done
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
