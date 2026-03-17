#!/usr/bin/env bash
set -euo pipefail

# Delegates to the main test-routes script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../scripts/test-routes.sh" "$@"
