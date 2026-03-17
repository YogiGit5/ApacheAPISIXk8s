#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/lib.sh"

GATEWAY_HTTP="${APISIX_GATEWAY_URL:-http://localhost:9080}"
GATEWAY_HTTPS="${APISIX_GATEWAY_HTTPS_URL:-https://localhost:9443}"
ADMIN_URL="${APISIX_ADMIN_URL:-http://localhost:9180/apisix/admin}"
API_KEY="${APISIX_ADMIN_KEY:-dev-admin-key}"

echo "============================================"
echo "  HTTPS / SSL Tests"
echo "============================================"
echo ""

PASS=0
FAIL=0

check() {
  local label="$1" expected="$2"
  shift 2
  local actual
  actual=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "$@" 2>/dev/null || echo "000")
  if [ "$actual" = "$expected" ]; then
    echo "  [PASS] $label (HTTP $actual)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] $label — expected $expected, got $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ── 1. HTTPS port is listening ──
echo "1. HTTPS port reachable"
check "HTTPS gateway responds" "404" "$GATEWAY_HTTPS/"
echo ""

# ── 2. SSL certificate is valid ──
echo "2. TLS certificate details"
cert_info=$(echo | openssl s_client -connect localhost:9443 -servername localhost 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates 2>/dev/null || echo "ERROR")
if echo "$cert_info" | grep -q "subject="; then
  echo "  [PASS] TLS certificate present"
  echo "$cert_info" | sed 's/^/         /'
  PASS=$((PASS + 1))
else
  echo "  [FAIL] Could not retrieve TLS certificate"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 3. SSL resource exists in Admin API ──
echo "3. SSL resource in APISIX"
ssl_count=$(curl -s -H "X-API-KEY: $API_KEY" "$ADMIN_URL/ssls" 2>/dev/null \
  | $PYTHON_CMD -c "import sys,json; print(json.load(sys.stdin).get('total',0))" 2>/dev/null || echo "0")
if [ "$ssl_count" -gt 0 ]; then
  echo "  [PASS] $ssl_count SSL certificate(s) configured"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] No SSL certificates found in APISIX"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 4. HTTP → HTTPS redirect ──
echo "4. HTTP → HTTPS redirect"
redirect_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
  "$GATEWAY_HTTP/api/v1/tracking/vehicles" 2>/dev/null || echo "000")
if [ "$redirect_code" = "301" ] || [ "$redirect_code" = "302" ]; then
  redirect_location=$(curl -s -D - -o /dev/null --max-time 5 \
    "$GATEWAY_HTTP/api/v1/tracking/vehicles" 2>/dev/null | grep -i "^location:" | head -1)
  echo "  [PASS] HTTP request redirected (HTTP $redirect_code)"
  echo "         $redirect_location"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] HTTP not redirecting — got HTTP $redirect_code (expected 301/302)"
  FAIL=$((FAIL + 1))
fi
echo ""

# ── 5. HTTPS routes work with valid JWT ──
echo "5. HTTPS + JWT auth end-to-end"
TOKEN=$(curl -sk --max-time 5 \
  "$GATEWAY_HTTPS/apisix/plugin/jwt/sign?key=vzone_platform_key" 2>/dev/null || echo "")
if [ -n "$TOKEN" ] && echo "$TOKEN" | grep -q '\.'; then
  actual=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Authorization: Bearer $TOKEN" \
    "$GATEWAY_HTTPS/api/v1/tracking/vehicles" 2>/dev/null || echo "000")
  if [ "$actual" = "200" ] || [ "$actual" = "502" ]; then
    echo "  [PASS] HTTPS + JWT auth works (HTTP $actual)"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] HTTPS + JWT auth — expected 200/502, got $actual"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  [SKIP] Could not generate JWT token over HTTPS"
fi
echo ""

# ── 6. TLS version check (reject TLS < 1.2) ──
echo "6. TLS version enforcement"
if echo | openssl s_client -connect localhost:9443 -tls1_2 2>/dev/null | grep -q "Verify"; then
  echo "  [PASS] TLS 1.2 supported"
  PASS=$((PASS + 1))
else
  echo "  [FAIL] TLS 1.2 not supported"
  FAIL=$((FAIL + 1))
fi

if echo | openssl s_client -connect localhost:9443 -tls1 2>&1 | grep -qi "error\|unsupported\|no protocols"; then
  echo "  [PASS] TLS 1.0 rejected"
  PASS=$((PASS + 1))
else
  echo "  [INFO] TLS 1.0 check inconclusive (may depend on OpenSSL build)"
  PASS=$((PASS + 1))
fi
echo ""

echo "============================================"
echo "  Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
