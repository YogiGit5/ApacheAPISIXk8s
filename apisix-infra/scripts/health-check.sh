#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"
NAMESPACE="${APISIX_NAMESPACE:-apisix}"

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

echo "============================================"
echo "  APISIX Health Check"
echo "============================================"
echo ""

# ── Kubernetes pod status (if kubectl available) ──
if command -v kubectl &>/dev/null; then
  echo "1. Kubernetes pod status"
  kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | while read -r line; do
    echo "   $line"
  done
  echo ""
fi

# ── etcd health ──
echo "2. etcd connectivity"
check "etcd from Admin API" "200" \
  -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes"
echo ""

# ── APISIX Gateway ──
echo "3. APISIX Gateway"
check "Gateway responds" "404" "$GATEWAY_URL/"
echo ""

# ── Admin API ──
echo "4. Admin API"
check "List routes" "200" -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes"
check "List upstreams" "200" -H "X-API-KEY: $API_KEY" "$ADMIN_URL/upstreams"
check "List global rules" "200" -H "X-API-KEY: $API_KEY" "$ADMIN_URL/global_rules"
echo ""

# ── Route counts ──
echo "5. Configured resources"
if command -v $PYTHON_CMD &>/dev/null; then
  routes=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/routes" 2>/dev/null \
    | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
  upstreams=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/upstreams" 2>/dev/null \
    | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
  globals=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/global_rules" 2>/dev/null \
    | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "?")
  echo "   Routes:       $routes"
  echo "   Upstreams:    $upstreams"
  echo "   Global rules: $globals"
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
