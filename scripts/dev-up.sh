#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
#  VZone Dev Environment — Docker Compose
#  Brings up APISIX + etcd + httpbin, then applies routes
#  with Docker-friendly upstream addresses.
# ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$PROJECT_ROOT/apisix-infra"

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"
GATEWAY_URL="${APISIX_GATEWAY_URL:-http://localhost:9080}"

# In Docker Compose, httpbin container is "apisix-backend" on port 80
DEV_BACKEND="apisix-backend:80"

echo "============================================"
echo "  VZone Dev Environment Setup"
echo "============================================"
echo ""

# ── 1. Start containers ──
echo "==> Starting Docker Compose..."
cd "$PROJECT_ROOT"
docker compose up -d
echo ""

# ── 2. Wait for Admin API ──
echo "==> Waiting for APISIX Admin API..."
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN_URL/routes" \
    -H "X-API-KEY: $API_KEY" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "    Admin API is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Admin API not reachable after 60s." >&2
    echo "       Check: docker compose logs apisix" >&2
    exit 1
  fi
  sleep 2
done
echo ""

# ── Helper: PUT a JSON payload to Admin API ──
api_put() {
  local path="$1" label="$2" payload="$3"
  echo "    PUT $path  ($label)"
  local http_code
  http_code=$(echo "$payload" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "$ADMIN_URL$path" \
    -H "X-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    -d @-)
  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "        OK (HTTP $http_code)"
  else
    echo "        FAILED (HTTP $http_code)" >&2
    return 1
  fi
}

ERRORS=0

# ── 3. Apply global rules ──
echo "==> Applying global rules..."
api_put "/global_rules/1" "CORS" '{
  "plugins": {
    "cors": {
      "allow_origins": "*",
      "allow_methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
      "allow_headers": "Content-Type, Authorization, X-Request-ID",
      "expose_headers": "X-Request-ID",
      "max_age": 3600,
      "allow_credential": false
    }
  }
}' || ERRORS=$((ERRORS + 1))

api_put "/global_rules/2" "Request ID" '{
  "plugins": {
    "request-id": {
      "header_name": "X-Request-ID",
      "include_in_response": true,
      "algorithm": "uuid"
    }
  }
}' || ERRORS=$((ERRORS + 1))
echo ""

# ── 4. Apply upstreams (pointing to Docker httpbin backend) ──
echo "==> Applying upstreams (dev: $DEV_BACKEND)..."
api_put "/upstreams/1" "live-tracking (dev)" "{
  \"name\": \"live-tracking-upstream\",
  \"desc\": \"Live Tracking Service - dev (httpbin)\",
  \"type\": \"roundrobin\",
  \"nodes\": {\"$DEV_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/4" "notification (dev)" "{
  \"name\": \"notification-upstream\",
  \"desc\": \"Notification Service - dev (httpbin)\",
  \"type\": \"roundrobin\",
  \"nodes\": {\"$DEV_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/5" "live-tracking-ws (dev)" "{
  \"name\": \"live-tracking-ws-upstream\",
  \"desc\": \"Live Tracking WS - dev (httpbin)\",
  \"type\": \"chash\",
  \"hash_on\": \"vars\",
  \"key\": \"remote_addr\",
  \"nodes\": {\"$DEV_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 60, \"read\": 60},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))
echo ""

# ── 5. Apply routes (no auth — jwt-auth removed) ──
echo "==> Applying routes..."
api_put "/routes/100" "tracking-read" '{
  "name": "tracking-read-routes",
  "desc": "Live Tracking - READ (dev)",
  "uri": "/api/v1/tracking/*",
  "methods": ["GET"],
  "upstream_id": "1",
  "plugins": {
    "limit-count": {
      "count": 100, "time_window": 60,
      "key_type": "var", "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\": \"Rate limit exceeded\", \"retry_after\": 60}",
      "policy": "local", "group": "tracking-read"
    },
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/tracking/(.*)", "/api/v1/tracking/$1"]
    }
  },
  "status": 1
}' || ERRORS=$((ERRORS + 1))

api_put "/routes/102" "tracking-write" '{
  "name": "tracking-write-routes",
  "desc": "Live Tracking - WRITE (dev)",
  "uri": "/api/v1/tracking/*",
  "methods": ["POST", "PUT", "PATCH", "DELETE"],
  "upstream_id": "1",
  "plugins": {
    "limit-count": {
      "count": 20, "time_window": 60,
      "key_type": "var", "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\": \"Rate limit exceeded\", \"retry_after\": 60}",
      "policy": "local", "group": "tracking-write"
    },
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/tracking/(.*)", "/api/v1/tracking/$1"]
    }
  },
  "status": 1
}' || ERRORS=$((ERRORS + 1))

api_put "/routes/400" "notification-read" '{
  "name": "notification-read-routes",
  "desc": "Notification - READ (dev)",
  "uri": "/api/v1/notifications/*",
  "methods": ["GET"],
  "upstream_id": "4",
  "plugins": {
    "limit-count": {
      "count": 100, "time_window": 60,
      "key_type": "var", "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\": \"Rate limit exceeded\", \"retry_after\": 60}",
      "policy": "local", "group": "notification-read"
    },
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/notifications/(.*)", "/api/v1/notifications/$1"]
    }
  },
  "status": 1
}' || ERRORS=$((ERRORS + 1))

api_put "/routes/401" "notification-write" '{
  "name": "notification-write-routes",
  "desc": "Notification - WRITE (dev)",
  "uri": "/api/v1/notifications/*",
  "methods": ["POST", "PUT", "PATCH", "DELETE"],
  "upstream_id": "4",
  "plugins": {
    "limit-count": {
      "count": 20, "time_window": 60,
      "key_type": "var", "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\": \"Rate limit exceeded\", \"retry_after\": 60}",
      "policy": "local", "group": "notification-write"
    },
    "proxy-rewrite": {
      "regex_uri": ["^/api/v1/notifications/(.*)", "/api/v1/notifications/$1"]
    }
  },
  "status": 1
}' || ERRORS=$((ERRORS + 1))

api_put "/routes/101" "websocket" '{
  "name": "tracking-websocket-route",
  "desc": "Live Tracking - WebSocket (dev)",
  "uri": "/ws/tracking",
  "enable_websocket": true,
  "upstream_id": "5",
  "plugins": {
    "limit-conn": {
      "conn": 50, "burst": 10, "default_conn_delay": 1,
      "key_type": "var", "key": "remote_addr",
      "rejected_code": 429,
      "rejected_msg": "{\"error\": \"Too many concurrent connections\"}"
    },
    "proxy-rewrite": {
      "uri": "/ws/tracking"
    }
  },
  "status": 1
}' || ERRORS=$((ERRORS + 1))
echo ""

# ── 6. Verify ──
echo "==> Quick health check..."
gw_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/" 2>/dev/null || echo "000")
tracking_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/tracking/test" 2>/dev/null || echo "000")
notif_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/notifications/test" 2>/dev/null || echo "000")
echo "    Gateway root:        HTTP $gw_code"
echo "    /api/v1/tracking/*:  HTTP $tracking_code"
echo "    /api/v1/notifications/*: HTTP $notif_code"
echo ""

echo "============================================"
if [ "$ERRORS" -gt 0 ]; then
  echo "  Setup completed with $ERRORS error(s)"
  exit 1
else
  echo "  Dev environment is READY"
  echo ""
  echo "  Gateway:     http://localhost:9080"
  echo "  Admin API:   http://localhost:9180"
  echo "  Prometheus:  http://localhost:9091"
  echo ""
  echo "  Test it:"
  echo "    curl http://localhost:9080/api/v1/tracking/vehicles"
  echo "    curl http://localhost:9080/api/v1/notifications/list"
  echo ""
  echo "  Auth: DISABLED (will use Keycloak later)"
fi
echo "============================================"
