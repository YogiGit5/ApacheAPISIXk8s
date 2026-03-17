#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
#  Apply/update upstreams to a RUNNING APISIX instance
#  Works for both Docker Compose and K8s (just needs Admin API)
#
#  Usage:
#    bash scripts/apply-upstreams.sh                    # uses defaults (httpbin)
#    bash scripts/apply-upstreams.sh --real              # uses real services
#    ADMIN_URL=http://10.0.0.5:9180/apisix/admin bash scripts/apply-upstreams.sh
#
#  Changes take effect INSTANTLY — no restart needed.
# ──────────────────────────────────────────────────────────

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"
MODE="${1:-mock}"

# ── Upstream definitions ──
if [ "$MODE" = "--real" ]; then
  echo "  Mode: REAL services"
  UPSTREAM_1_NODES='"live-tracking-service.vzone.svc.cluster.local:8080": 1'
  UPSTREAM_4_NODES='"notification-service.vzone.svc.cluster.local:8080": 1'
  UPSTREAM_5_NODES='"live-tracking-service.vzone.svc.cluster.local:8080": 1'
else
  echo "  Mode: MOCK (httpbin)"
  UPSTREAM_1_NODES='"httpbin.apisix.svc.cluster.local:80": 1'
  UPSTREAM_4_NODES='"httpbin.apisix.svc.cluster.local:80": 1'
  UPSTREAM_5_NODES='"httpbin.apisix.svc.cluster.local:80": 1'
fi

echo ""

api_put() {
  local path="$1" label="$2" payload="$3"
  echo "  PUT $path  ($label)"
  local http_code body
  body=$(echo "$payload" | curl -s -w "\n%{http_code}" \
    -X PUT "$ADMIN_URL$path" \
    -H "X-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)
  http_code=$(echo "$body" | tail -1)
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "      OK (HTTP $http_code)"
  else
    echo "      FAILED (HTTP $http_code)" >&2
    return 1
  fi
}

ERRORS=0

echo "==> Applying upstreams..."

api_put "/upstreams/1" "live-tracking (REST, roundrobin)" "{
  \"name\": \"live-tracking-upstream\",
  \"desc\": \"Live Tracking Service (REST)\",
  \"type\": \"roundrobin\",
  \"nodes\": {$UPSTREAM_1_NODES},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/4" "notification (REST, roundrobin)" "{
  \"name\": \"notification-upstream\",
  \"desc\": \"Notification Service\",
  \"type\": \"roundrobin\",
  \"nodes\": {$UPSTREAM_4_NODES},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/5" "websocket (chash by IP)" "{
  \"name\": \"live-tracking-ws-upstream\",
  \"desc\": \"Live Tracking WebSocket\",
  \"type\": \"chash\",
  \"hash_on\": \"vars\",
  \"key\": \"remote_addr\",
  \"nodes\": {$UPSTREAM_5_NODES},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 60, \"read\": 60},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "==> Completed with $ERRORS error(s)."
  exit 1
else
  echo "==> All upstreams updated. Changes are LIVE."
  echo ""
  echo "  Verify:"
  echo "    curl -s -H 'X-API-KEY: $API_KEY' $ADMIN_URL/upstreams | python3 -m json.tool"
fi
