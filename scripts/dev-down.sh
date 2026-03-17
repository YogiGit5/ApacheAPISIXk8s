#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "==> Stopping VZone dev environment..."
cd "$PROJECT_ROOT"
docker compose down

echo "==> Dev environment stopped."
echo "    To also remove etcd data: docker compose down -v"
