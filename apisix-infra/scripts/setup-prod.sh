#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="apisix"
APISIX_RELEASE="apisix"
ETCD_RELEASE="apisix-etcd"
ADMIN_KEY="${APISIX_ADMIN_KEY:?ERROR: Set APISIX_ADMIN_KEY environment variable}"

echo "============================================"
echo "  VZone Platform - APISIX Prod Deployment"
echo "============================================"
echo ""

# ── Pre-flight checks ──
echo "==> Pre-flight checks..."
for cmd in kubectl helm; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." >&2
    exit 1
  fi
done

CURRENT_CTX=$(kubectl config current-context)
echo "    Kubernetes context: $CURRENT_CTX"
read -rp "    Deploying to PRODUCTION. Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# ── Create namespace ──
echo "==> Creating namespace..."
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"

# ── Add Helm repositories ──
echo "==> Adding Helm repositories..."
helm repo add apisix https://charts.apiseven.com 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# ── Install etcd (3 replicas) ──
echo "==> Installing etcd cluster (3 replicas)..."
helm upgrade --install "$ETCD_RELEASE" bitnami/etcd \
  --namespace "$NAMESPACE" \
  --values "$ROOT_DIR/helm/etcd/values-prod.yaml" \
  --wait --timeout 10m

echo "==> Waiting for etcd cluster to be ready..."
kubectl rollout status statefulset/"$ETCD_RELEASE" -n "$NAMESPACE" --timeout=300s

# ── Install APISIX ──
echo "==> Installing APISIX 3.9.x (3 replicas)..."
helm upgrade --install "$APISIX_RELEASE" apisix/apisix \
  --namespace "$NAMESPACE" \
  --values "$ROOT_DIR/helm/apisix/values-prod.yaml" \
  --set admin.credentials.admin="$ADMIN_KEY" \
  --wait --timeout 10m

echo "==> Waiting for APISIX to be ready..."
kubectl rollout status deployment/"$APISIX_RELEASE" -n "$NAMESPACE" --timeout=180s

# ── Apply network policy ──
echo "==> Applying network policies..."
kubectl apply -f "$ROOT_DIR/k8s/network-policy.yaml"

# ── Verify ──
echo "==> Verifying deployment..."
kubectl get pods -n "$NAMESPACE"
echo ""

# ── Apply routes ──
echo "==> Applying routes..."
APISIX_ADMIN_KEY="$ADMIN_KEY" "$SCRIPT_DIR/apply-routes.sh"

echo ""
echo "============================================"
echo "  Production deployment complete!"
echo "============================================"
