#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="apisix"
RELEASE_NAME="apisix"

echo "==> Stopping port-forwards..."
pkill -f "kubectl port-forward.*9080:9080" 2>/dev/null || true
pkill -f "kubectl port-forward.*9180:9180" 2>/dev/null || true

echo "==> Removing httpbin..."
kubectl delete -f "$(dirname "$0")/../k8s/httpbin.yaml" 2>/dev/null || true

echo "==> Removing legacy standalone dashboard (if present)..."
kubectl delete deployment apisix-dashboard -n "$NAMESPACE" 2>/dev/null || true
kubectl delete service apisix-dashboard -n "$NAMESPACE" 2>/dev/null || true
kubectl delete configmap apisix-dashboard-config -n "$NAMESPACE" 2>/dev/null || true

echo "==> Uninstalling APISIX Helm release..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null || true

echo "==> Deleting namespace..."
kubectl delete namespace "$NAMESPACE" 2>/dev/null || true

echo "==> K8s environment torn down."
