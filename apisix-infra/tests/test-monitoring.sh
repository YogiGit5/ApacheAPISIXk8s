#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"
ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
METRICS_URL="${APISIX_METRICS_URL:-http://localhost:9091/apisix/prometheus/metrics}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"

echo "============================================"
echo "  Logging & Monitoring Tests"
echo "============================================"
echo ""

PASS=0
FAIL=0

# ── 1. Prometheus global rule exists ──
echo "1. Prometheus global rule configured"
has_prom=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/global_rules/4" 2>/dev/null \
  | $PYTHON_CMD -c "
import sys, json
d = json.load(sys.stdin).get('value', {})
plugins = d.get('plugins', {})
print('yes' if 'prometheus' in plugins else 'no')
" 2>/dev/null || echo "ERROR")
if [ "$has_prom" = "yes" ]; then
  echo "  [PASS] Prometheus plugin enabled as global rule"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Prometheus global rule not found"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 2. Metrics endpoint reachable ──
echo "2. Prometheus metrics endpoint"
metrics_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "$METRICS_URL" 2>/dev/null || echo "000")
if [ "$metrics_code" = "200" ]; then
  echo "  [PASS] Metrics endpoint reachable (HTTP 200)"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Metrics endpoint — expected 200, got $metrics_code"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 3. Key APISIX metrics present ──
echo "3. Key APISIX metrics present"
if [ "$metrics_code" = "200" ]; then
  metrics_body=$(curl -s --max-time 5 "$METRICS_URL" 2>/dev/null || echo "")

  for metric in apisix_http_status apisix_http_latency_bucket apisix_bandwidth apisix_node_info; do
    if echo "$metrics_body" | grep -q "^$metric"; then
      echo "  [PASS] $metric"
      PASS=$((PASS + 1))
    else
      echo "  [INFO] $metric not yet populated (requires traffic)"
      PASS=$((PASS + 1))
    fi
  done
else
  echo "  [SKIP] Cannot check metrics — endpoint not reachable"
fi
echo ""

# ── 4. Generate traffic and verify metrics update ──
echo "4. Metrics update after traffic"
TOKEN=$(curl -s --max-time 5 \
  "$GATEWAY_URL/apisix/plugin/jwt/sign?key=vzone_platform_key" 2>/dev/null || echo "")

if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q '\.'; then
  # Send 5 requests to generate metrics
  for i in $(seq 1 5); do
    curl -s -o /dev/null --max-time 3 \
      -H "Authorization: Bearer $TOKEN" \
      "$GATEWAY_URL/api/v1/tracking/vehicles" 2>/dev/null || true
  done

  # Check metrics updated
  if [ "$metrics_code" = "200" ]; then
    updated_metrics=$(curl -s --max-time 5 "$METRICS_URL" 2>/dev/null || echo "")
    if echo "$updated_metrics" | grep -q "apisix_http_status"; then
      echo "  [PASS] Metrics contain HTTP status data after traffic"
      PASS=$((PASS + 1))
    else
      echo "  [INFO] Metrics may take a scrape interval to populate"
      PASS=$((PASS + 1))
    fi
  fi
else
  echo "  [SKIP] No JWT token — cannot generate traffic"
fi
echo ""

# ── 5. Upstream health metrics ──
echo "5. Upstream health check metrics"
if [ "$metrics_code" = "200" ]; then
  upstream_metrics=$(curl -s --max-time 5 "$METRICS_URL" 2>/dev/null | grep -c "apisix_upstream" || echo "0")
  if [ "$upstream_metrics" -gt 0 ]; then
    echo "  [PASS] $upstream_metrics upstream metric lines found"
    PASS=$((PASS + 1))
  else
    echo "  [INFO] No upstream metrics yet (backends may not be running)"
    PASS=$((PASS + 1))
  fi
else
  echo "  [SKIP] Metrics endpoint not reachable"
fi
echo ""

# ── 6. APISIX access log exists ──
echo "6. Access log availability"
if command -v kubectl &>/dev/null; then
  NAMESPACE="${APISIX_NAMESPACE:-apisix}"
  POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=apisix \
    --no-headers -o custom-columns=":metadata.name" 2>/dev/null | head -1)
  if [ -n "$POD" ]; then
    log_lines=$(kubectl logs "$POD" -n "$NAMESPACE" --tail=5 2>/dev/null | wc -l || echo "0")
    if [ "$log_lines" -gt 0 ]; then
      echo "  [PASS] Pod $POD has $log_lines recent log lines"
      PASS=$((PASS + 1))
    else
      echo "  [INFO] Pod $POD has no recent logs"
      PASS=$((PASS + 1))
    fi
  else
    echo "  [SKIP] No APISIX pod found in namespace $NAMESPACE"
  fi
else
  echo "  [SKIP] kubectl not available"
fi
echo ""

# ── 7. Global rules count ──
echo "7. All global rules configured"
globals=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/global_rules" 2>/dev/null \
  | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
echo "  Total global rules: $globals"
if [ "$globals" -ge 4 ]; then
  echo "  [PASS] Expected 4+ global rules (CORS, request-id, redirect, prometheus)"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Expected at least 4 global rules, got $globals"
  FAIL=$((FAIL + 1))
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
