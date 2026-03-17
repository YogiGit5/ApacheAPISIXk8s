#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/certs"
DOMAIN="${1:-localhost}"
DAYS=365

echo "============================================"
echo "  Generate Self-Signed TLS Certificate"
echo "============================================"
echo ""
echo "  Domain:  $DOMAIN"
echo "  Output:  $CERT_DIR/"
echo "  Validity: $DAYS days"
echo ""

if ! command -v openssl &>/dev/null; then
  echo "ERROR: openssl is not installed." >&2
  exit 1
fi

mkdir -p "$CERT_DIR"

# ── Generate CA key and certificate ──
echo "==> Generating CA..."
openssl genrsa -out "$CERT_DIR/ca.key" 4096 2>/dev/null

openssl req -new -x509 -sha256 \
  -key "$CERT_DIR/ca.key" \
  -out "$CERT_DIR/ca.crt" \
  -days "$DAYS" \
  -subj "/C=US/ST=Dev/L=Dev/O=VZone/OU=Platform/CN=VZone Dev CA"

# ── Generate server key and CSR ──
echo "==> Generating server certificate..."
openssl genrsa -out "$CERT_DIR/server.key" 2048 2>/dev/null

cat > "$CERT_DIR/san.cnf" <<EOF
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
C = US
ST = Dev
L = Dev
O = VZone
OU = Platform
CN = $DOMAIN

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
DNS.3 = apisix-gateway.apisix.svc.cluster.local
DNS.4 = *.apisix.svc.cluster.local
IP.1 = 127.0.0.1
EOF

openssl req -new -sha256 \
  -key "$CERT_DIR/server.key" \
  -out "$CERT_DIR/server.csr" \
  -config "$CERT_DIR/san.cnf"

# ── Sign the server certificate with the CA ──
openssl x509 -req -sha256 \
  -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/server.crt" \
  -days "$DAYS" \
  -extensions v3_req \
  -extfile "$CERT_DIR/san.cnf" 2>/dev/null

# ── Clean up intermediate files ──
rm -f "$CERT_DIR/server.csr" "$CERT_DIR/san.cnf" "$CERT_DIR/ca.srl"

# ── Set restrictive permissions ──
chmod 600 "$CERT_DIR/ca.key" "$CERT_DIR/server.key"
chmod 644 "$CERT_DIR/ca.crt" "$CERT_DIR/server.crt"

echo ""
echo "==> Certificates generated:"
echo "    CA cert:     $CERT_DIR/ca.crt"
echo "    Server cert: $CERT_DIR/server.crt"
echo "    Server key:  $CERT_DIR/server.key"
echo ""
echo "==> Verify:"
openssl x509 -in "$CERT_DIR/server.crt" -noout -subject -issuer -dates
echo ""
echo "==> To trust the CA locally (optional):"
echo "    macOS: sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CERT_DIR/ca.crt"
echo "    Linux: sudo cp $CERT_DIR/ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates"
