#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
#  VZone Dev/Demo — Deploy APISIX on Kubernetes
#  Deploys: etcd + APISIX (Helm) + httpbin (mock backend)
#  Then applies routes via Admin API
# ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
K8S_DIR="$PROJECT_ROOT/k8s"

NAMESPACE="apisix"
RELEASE_NAME="apisix"
API_KEY="dev-admin-key"

# Backend inside K8s — httpbin service DNS
K8S_BACKEND="httpbin.apisix.svc.cluster.local:80"

echo "============================================"
echo "  VZone — K8s APISIX Setup"
echo "============================================"
echo ""

# ── 1. Add Helm repos ──
echo "==> Step 1: Adding Helm repos..."
helm repo add apisix https://charts.apiseven.com 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update
echo ""

# ── 2. Create namespace ──
echo "==> Step 2: Creating namespace '$NAMESPACE'..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || echo "    Namespace already exists."
echo ""

# ── 3. Install APISIX via Helm (includes etcd) ──
echo "==> Step 3: Installing APISIX via Helm..."
helm upgrade --install "$RELEASE_NAME" apisix/apisix \
  --namespace "$NAMESPACE" \
  -f "$K8S_DIR/values.yaml" \
  --wait \
  --timeout 10m
echo ""

# ── 4. Deploy httpbin mock backend ──
echo "==> Step 4: Deploying httpbin mock backend..."
kubectl apply -f "$K8S_DIR/httpbin.yaml"
echo ""

# ── 5. Wait for all pods to be ready ──
echo "==> Step 5: Waiting for pods to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=apisix \
  -n "$NAMESPACE" --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=httpbin \
  -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

echo ""
echo "    Pod status:"
kubectl get pods -n "$NAMESPACE" --no-headers | while read -r line; do
  echo "      $line"
done
echo ""

# ── 6. Port-forward Admin API (background) ──
echo "==> Step 6: Starting port-forward to Admin API..."
# Kill any existing port-forward
pkill -f "kubectl port-forward.*9180:9180" 2>/dev/null || true
sleep 1
kubectl port-forward svc/${RELEASE_NAME}-admin -n "$NAMESPACE" 9180:9180 &>/dev/null &
PF_PID=$!
echo "    Port-forward PID: $PF_PID (localhost:9180 → Admin API)"

# Wait for port-forward to be ready
ADMIN_URL="http://localhost:9180/apisix/admin"
echo "    Waiting for Admin API on localhost:9180..."
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN_URL/routes" \
    -H "X-API-KEY: $API_KEY" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "    Admin API is ready."
    break
  fi
  if [ "$i" -eq 20 ]; then
    echo "ERROR: Admin API not reachable. Check pods and port-forward." >&2
    echo "       kubectl logs -l app.kubernetes.io/name=apisix -n $NAMESPACE" >&2
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

# ── 7. Apply global rules ──
echo "==> Step 7: Applying global rules..."
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

# ── 8. Apply upstreams (pointing to httpbin inside K8s) ──
echo "==> Step 8: Applying upstreams (→ $K8S_BACKEND)..."
api_put "/upstreams/1" "live-tracking" "{
  \"name\": \"live-tracking-upstream\",
  \"desc\": \"Live Tracking Service (httpbin mock)\",
  \"type\": \"roundrobin\",
  \"nodes\": {\"$K8S_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/4" "notification" "{
  \"name\": \"notification-upstream\",
  \"desc\": \"Notification Service (httpbin mock)\",
  \"type\": \"roundrobin\",
  \"nodes\": {\"$K8S_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 5, \"read\": 10},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))

api_put "/upstreams/5" "live-tracking-ws" "{
  \"name\": \"live-tracking-ws-upstream\",
  \"desc\": \"Live Tracking WS (httpbin mock)\",
  \"type\": \"chash\",
  \"hash_on\": \"vars\",
  \"key\": \"remote_addr\",
  \"nodes\": {\"$K8S_BACKEND\": 1},
  \"retries\": 2,
  \"timeout\": {\"connect\": 5, \"send\": 60, \"read\": 60},
  \"scheme\": \"http\"
}" || ERRORS=$((ERRORS + 1))
echo ""

# ── 9. Apply routes (no auth) ──
echo "==> Step 9: Applying routes..."
api_put "/routes/100" "tracking-read" '{
  "name": "tracking-read-routes",
  "desc": "Live Tracking - READ",
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
  "desc": "Live Tracking - WRITE",
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
  "desc": "Notification - READ",
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
  "desc": "Notification - WRITE",
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
  "desc": "Live Tracking - WebSocket",
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

# ── 10. Port-forward Gateway too ──
echo "==> Step 10: Port-forwarding Gateway..."
pkill -f "kubectl port-forward.*9080:9080" 2>/dev/null || true
sleep 1
kubectl port-forward svc/${RELEASE_NAME}-gateway -n "$NAMESPACE" 9080:9080 &>/dev/null &
GW_PID=$!
sleep 2
echo "    Gateway port-forward PID: $GW_PID (localhost:9080)"
echo ""

# ── 11. Verify ──
echo "==> Step 11: Quick health check..."
GATEWAY_URL="http://localhost:9080"
gw_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/" 2>/dev/null || echo "000")
tracking_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/tracking/test" 2>/dev/null || echo "000")
notif_code=$(curl -s -o /dev/null -w "%{http_code}" "$GATEWAY_URL/api/v1/notifications/test" 2>/dev/null || echo "000")
echo "    Gateway root:              HTTP $gw_code"
echo "    /api/v1/tracking/*:        HTTP $tracking_code"
echo "    /api/v1/notifications/*:   HTTP $notif_code"
echo ""

echo "============================================"
if [ "$ERRORS" -gt 0 ]; then
  echo "  Setup completed with $ERRORS error(s)"
  exit 1
else
  echo "  K8s environment is READY"
  echo ""
  echo "  Gateway:     http://localhost:9080  (port-forwarded)"
  echo "  Admin API:   http://localhost:9180  (port-forwarded)"
  echo ""
  echo "  Test it:"
  echo "    curl http://localhost:9080/api/v1/tracking/vehicles"
  echo "    curl http://localhost:9080/api/v1/notifications/list"
  echo ""
  echo "  View pods:"
  echo "    kubectl get pods -n $NAMESPACE"
  echo ""
  echo "  View logs:"
  echo "    kubectl logs -l app.kubernetes.io/name=apisix -n $NAMESPACE"
  echo ""
  echo "  Auth: DISABLED (Keycloak OIDC planned)"
fi
echo "============================================"
