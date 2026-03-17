#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"

echo "==> Applying APISIX route configuration"
echo "    Admin URL: $ADMIN_URL"
echo ""

# ── Wait for Admin API ──
echo "==> Waiting for Admin API..."
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$ADMIN_URL/routes" \
    -H "X-API-KEY: $API_KEY" 2>/dev/null || echo "000")
  if [ "$code" = "200" ]; then
    echo "    Admin API is ready."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "ERROR: Admin API not reachable after 60 seconds." >&2
    exit 1
  fi
  sleep 2
done

# ── Apply a single YAML resource to the Admin API ──
apply_resource() {
  local file="$1"
  local filename
  filename=$(basename "$file")
  local pyfile
  pyfile=$(native_path "$file")

  # Parse _meta and extract payload using Python
  read -r resource id < <($PYTHON_CMD -c "
import yaml
with open(r'$pyfile') as f:
    d = yaml.safe_load(f)
print(d['_meta']['resource'], d['_meta']['id'])
" | tr -d '\r')

  # Extract payload (everything except _meta) and convert to JSON
  local payload
  payload=$($PYTHON_CMD -c "
import yaml, json
with open(r'$pyfile') as f:
    d = yaml.safe_load(f)
del d['_meta']
print(json.dumps(d))
" | tr -d '\r')

  echo "    PUT /$resource/$id  ($filename)"
  local http_code
  http_code=$(echo "$payload" | curl -s -o /dev/null -w "%{http_code}" \
    -X PUT "$ADMIN_URL/$resource/$id" \
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

# ── Apply global rules ──
echo ""
echo "==> Applying global rules..."
for file in "$ROOT_DIR"/routes/global-rules/*.yaml; do
  [ -f "$file" ] || continue
  apply_resource "$file" || ERRORS=$((ERRORS + 1))
done

# ── Apply upstreams ──
echo ""
echo "==> Applying upstreams..."
for file in "$ROOT_DIR"/routes/upstreams/*.yaml; do
  [ -f "$file" ] || continue
  apply_resource "$file" || ERRORS=$((ERRORS + 1))
done

# ── Apply routes ──
echo ""
echo "==> Applying routes..."
for file in "$ROOT_DIR"/routes/routes/*.yaml; do
  [ -f "$file" ] || continue
  apply_resource "$file" || ERRORS=$((ERRORS + 1))
done

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "==> Completed with $ERRORS error(s)."
  exit 1
else
  echo "==> All resources applied successfully."
fi
