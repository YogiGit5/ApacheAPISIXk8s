#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

NAMESPACE="apisix"
APISIX_RELEASE="apisix"
ETCD_RELEASE="apisix-etcd"

echo "============================================"
echo "  VZone Platform - APISIX Dev Environment"
echo "============================================"
echo ""

# ── Pre-flight checks ──
echo "==> Pre-flight checks..."
for cmd in kubectl helm minikube; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed." >&2
    exit 1
  fi
done

if ! minikube status &>/dev/null; then
  echo "==> Starting Minikube..."
  minikube start --memory=4096 --cpus=2
fi
echo "    Minikube is running."

# ── Create namespace ──
echo "==> Creating namespace..."
kubectl apply -f "$ROOT_DIR/k8s/namespace.yaml"

# ── Add Helm repositories ──
echo "==> Adding Helm repositories..."
helm repo add apisix https://charts.apiseven.com 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# ── Install etcd ──
echo "==> Installing etcd (1 replica)..."
helm upgrade --install "$ETCD_RELEASE" bitnami/etcd \
  --namespace "$NAMESPACE" \
  --values "$ROOT_DIR/helm/etcd/values-dev.yaml" \
  --wait --timeout 5m

echo "==> Waiting for etcd to be ready..."
kubectl rollout status statefulset/"$ETCD_RELEASE" -n "$NAMESPACE" --timeout=120s

# ── Install APISIX ──
echo "==> Installing APISIX 3.9.x..."
helm upgrade --install "$APISIX_RELEASE" apisix/apisix \
  --namespace "$NAMESPACE" \
  --values "$ROOT_DIR/helm/apisix/values-dev.yaml" \
  --wait --timeout 5m

echo "==> Waiting for APISIX to be ready..."
kubectl rollout status deployment/"$APISIX_RELEASE" -n "$NAMESPACE" --timeout=120s

# ── Apply network policy ──
echo "==> Applying network policies..."
kubectl apply -f "$ROOT_DIR/k8s/network-policy.yaml"

# ── Wait and verify ──
echo "==> Verifying deployment..."
kubectl get pods -n "$NAMESPACE"
echo ""

# ── Port-forward for local access ──
echo "==> Setting up port-forwarding..."
echo "    Gateway:  kubectl port-forward svc/$APISIX_RELEASE-gateway -n $NAMESPACE 9080:9080 &"
echo "    Admin:    kubectl port-forward svc/$APISIX_RELEASE-admin -n $NAMESPACE 9180:9180 &"
echo ""

# ── Apply routes ──
echo "==> Applying routes..."
"$SCRIPT_DIR/apply-routes.sh"

echo ""
echo "============================================"
echo "  Dev environment ready!"
echo ""
echo "  Gateway:   http://localhost:9080"
echo "  Admin API: http://localhost:9180"
echo "============================================"
