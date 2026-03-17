#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"
NAMESPACE="${APISIX_NAMESPACE:-apisix}"

echo "============================================"
echo "  VZone Platform - Logging & Monitoring"
echo "============================================"
echo ""

ERRORS=0

api_put() {
  local path="$1" label="$2" payload="$3"
  echo "  PUT $path  ($label)"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "$ADMIN_URL$path" \
    -H "X-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload")
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "      OK (HTTP $http_code)"
  else
    echo "      FAILED (HTTP $http_code)" >&2
    ERRORS=$((ERRORS + 1))
  fi
}

# ── 1. Enable Prometheus metrics global rule ──
echo "==> Enabling Prometheus metrics (global rule)..."
api_put "/global_rules/4" "prometheus-metrics" '{
  "plugins": {
    "prometheus": {
      "prefer_name": true
    }
  }
}'
echo ""

# ── 2. Apply ServiceMonitor for Prometheus Operator ──
echo "==> Applying ServiceMonitor (Prometheus Operator)..."
if kubectl get crd servicemonitors.monitoring.coreos.com &>/dev/null 2>&1; then
  kubectl apply -f "$ROOT_DIR/k8s/servicemonitor.yaml"
  kubectl apply -f "$ROOT_DIR/k8s/podmonitor-etcd.yaml"
  echo "    ServiceMonitor and PodMonitor applied."
else
  echo "    Prometheus Operator CRDs not found — skipping ServiceMonitor."
  echo "    Configure manual scrape target: http://apisix-gateway.apisix:9091/apisix/prometheus/metrics"
fi
echo ""

# ── 3. Enable HTTP access logging (optional — requires collector) ──
HTTP_LOGGER_URI="${HTTP_LOGGER_URI:-}"
if [ -n "$HTTP_LOGGER_URI" ]; then
  echo "==> Enabling HTTP access logging..."
  api_put "/global_rules/5" "http-access-logger" "$(cat <<EOF
{
  "plugins": {
    "http-logger": {
      "uri": "$HTTP_LOGGER_URI",
      "batch_max_size": 100,
      "inactive_timeout": 5,
      "buffer_duration": 30,
      "max_retry_count": 3,
      "retry_delay": 1,
      "concat_method": "json",
      "include_req_body": false,
      "include_resp_body": false
    }
  }
}
EOF
)"
else
  echo "==> HTTP logger: skipped (set HTTP_LOGGER_URI to enable)"
  echo "    Example: HTTP_LOGGER_URI=http://collector:9080/logs make monitoring"
fi
echo ""

# ── 4. Verify Prometheus metrics endpoint ──
echo "==> Verifying Prometheus metrics endpoint..."
metrics_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "http://localhost:9091/apisix/prometheus/metrics" 2>/dev/null || echo "000")
if [ "$metrics_code" = "200" ]; then
  sample_count=$(curl -s --max-time 5 "http://localhost:9091/apisix/prometheus/metrics" 2>/dev/null \
    | grep -c "^apisix_" || echo "0")
  echo "    Metrics endpoint: OK ($sample_count APISIX metric lines)"
else
  echo "    Metrics endpoint: not reachable (HTTP $metrics_code)"
  echo "    Port-forward if needed: kubectl port-forward svc/apisix-gateway -n $NAMESPACE 9091:9091"
fi
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo "==> Completed with $ERRORS error(s)."
  exit 1
else
  echo "==> Monitoring configured successfully."
  echo ""
  echo "  Prometheus metrics: http://localhost:9091/apisix/prometheus/metrics"
  echo "  Key metrics:"
  echo "    apisix_http_status          — Request counts by status code"
  echo "    apisix_http_latency_bucket  — Request latency histogram"
  echo "    apisix_bandwidth            — Ingress/egress bytes"
  echo "    apisix_upstream_status      — Upstream response codes"
  echo "    apisix_node_info            — APISIX node metadata"
fi
