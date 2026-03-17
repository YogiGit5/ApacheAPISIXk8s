#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"
NAMESPACE="${APISIX_NAMESPACE:-apisix}"
ENV="${APISIX_ENV:-dev}"

echo "============================================"
echo "  VZone Platform - HTTPS/SSL Configuration"
echo "============================================"
echo ""
echo "  Environment: $ENV"
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

case "$ENV" in
  dev)
    CERT_DIR="$ROOT_DIR/ssl/dev/certs"
    DOMAIN="${GATEWAY_DOMAIN:-localhost}"

    # ── Generate self-signed certs if missing ──
    if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
      echo "==> Generating self-signed certificates..."
      bash "$ROOT_DIR/ssl/dev/self-signed-cert.sh" "$DOMAIN"
      echo ""
    fi

    # ── Create K8s TLS secret ──
    echo "==> Creating TLS secret in Kubernetes..."
    kubectl create secret tls apisix-gateway-tls \
      --cert="$CERT_DIR/server.crt" \
      --key="$CERT_DIR/server.key" \
      --namespace "$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo ""

    # ── Upload SSL certificate to APISIX via Admin API ──
    echo "==> Uploading SSL certificate to APISIX..."
    CERT_CONTENT=$(awk '{printf "%s\\n", $0}' "$CERT_DIR/server.crt")
    KEY_CONTENT=$(awk '{printf "%s\\n", $0}' "$CERT_DIR/server.key")

    api_put "/ssls/1" "dev TLS certificate" "$(cat <<EOF
{
  "cert": "$CERT_CONTENT",
  "key": "$KEY_CONTENT",
  "snis": ["$DOMAIN", "*.$DOMAIN", "*.apisix.svc.cluster.local"]
}
EOF
)"
    echo ""
    ;;

  staging|prod)
    DOMAIN="${GATEWAY_DOMAIN:?ERROR: Set GATEWAY_DOMAIN for $ENV}"
    ACME_EMAIL="${ACME_EMAIL:?ERROR: Set ACME_EMAIL for $ENV}"

    # ── Install cert-manager if not present ──
    if ! kubectl get crd certificates.cert-manager.io &>/dev/null; then
      echo "==> Installing cert-manager..."
      helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
      helm repo update
      helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set crds.enabled=true \
        --wait --timeout 5m
    else
      echo "==> cert-manager already installed."
    fi
    echo ""

    # ── Apply ClusterIssuers and Certificate ──
    echo "==> Applying cert-manager resources..."
    export GATEWAY_DOMAIN="$DOMAIN"
    export ACME_EMAIL="$ACME_EMAIL"
    envsubst < "$ROOT_DIR/ssl/prod/cert-manager.yaml" | kubectl apply -f -
    echo ""

    # ── Wait for certificate to be ready ──
    echo "==> Waiting for certificate to be issued..."
    kubectl wait --for=condition=Ready certificate/apisix-gateway-tls \
      -n "$NAMESPACE" --timeout=300s 2>/dev/null || {
      echo "  WARNING: Certificate not ready yet. Check: kubectl describe certificate apisix-gateway-tls -n $NAMESPACE"
    }
    echo ""

    # ── Upload cert from K8s secret to APISIX Admin API ──
    echo "==> Uploading certificate to APISIX..."
    CERT_CONTENT=$(kubectl get secret apisix-gateway-tls -n "$NAMESPACE" \
      -o jsonpath='{.data.tls\.crt}' | base64 -d | awk '{printf "%s\\n", $0}')
    KEY_CONTENT=$(kubectl get secret apisix-gateway-tls -n "$NAMESPACE" \
      -o jsonpath='{.data.tls\.key}' | base64 -d | awk '{printf "%s\\n", $0}')

    api_put "/ssls/1" "$ENV TLS certificate" "$(cat <<EOF
{
  "cert": "$CERT_CONTENT",
  "key": "$KEY_CONTENT",
  "snis": ["$DOMAIN", "*.$DOMAIN"]
}
EOF
)"
    echo ""
    ;;

  *)
    echo "ERROR: Unknown environment '$ENV'. Use dev, staging, or prod." >&2
    exit 1
    ;;
esac

# ── Configure HTTP → HTTPS redirect (global rule) ──
echo "==> Configuring HTTP → HTTPS redirect..."
api_put "/global_rules/3" "HTTP-to-HTTPS redirect" '{
  "plugins": {
    "redirect": {
      "http_to_https": true
    }
  }
}'
echo ""

if [ "$ERRORS" -gt 0 ]; then
  echo "==> Completed with $ERRORS error(s)."
  exit 1
else
  echo "==> HTTPS configured successfully."
  echo ""
  echo "  Test: curl -k https://localhost:9443/api/v1/tracking/vehicles"
fi
