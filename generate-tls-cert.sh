#!/bin/bash

# Generates a self-signed TLS certificate and private key for Quay.
# Output: ssl.cert and ssl.key in the same directory as this script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CN="quay.arvhomelab.com"
DAYS=825   # ~2 years (max broadly accepted by browsers)
OUT_CERT="$SCRIPT_DIR/ssl.cert"
OUT_KEY="$SCRIPT_DIR/ssl.key"

echo "=== Generating self-signed TLS certificate ==="
echo "  CN:      $CN"
echo "  Valid:   $DAYS days"
echo "  Output:  $OUT_CERT"
echo "           $OUT_KEY"
echo

openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
    -days "$DAYS" \
    -keyout "$OUT_KEY" \
    -out   "$OUT_CERT" \
    -subj "/C=CA/ST=Ontario/L=Toronto/O=ArvHomeLab/OU=Infrastructure/CN=${CN}" \
    -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1"

chmod 644 "$OUT_CERT"
chmod 600 "$OUT_KEY"

echo
echo "✓ Certificate generated successfully"
echo
echo "Certificate details:"
openssl x509 -in "$OUT_CERT" -noout -subject -issuer -dates -ext subjectAltName
echo
echo "Next step — deploy Quay with these certificates:"
echo "  ./deploy-quay-local.sh --cert $OUT_CERT --key $OUT_KEY"
