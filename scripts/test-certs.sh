#!/usr/bin/env bash
# Exercise certificate installation without host certificates or Docker access.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=scalar.lehigh.edu \
  -addext subjectAltName=DNS:scalar.lehigh.edu \
  -keyout "$work/key.pem" -out "$work/cert.pem" >/dev/null 2>&1
export SOURCE_CERT="$work/cert.pem" SOURCE_KEY="$work/key.pem"
export CERT_DIR="$work/local" SSL_CERT_FILE="$work/cert.pem"
export EXPECTED_HOST=scalar.lehigh.edu
bash "$root/scripts/lehigh-certs.sh"
cmp "$SOURCE_CERT" "$CERT_DIR/cert.pem"
cmp "$SOURCE_KEY" "$CERT_DIR/privkey.pem"
[[ $(stat -c %a "$CERT_DIR/privkey.pem") == 600 ]]
[[ $(stat -c %a "$CERT_DIR/cert.pem") == 644 ]]
if EXPECTED_HOST=wrong.example.edu bash "$root/scripts/lehigh-certs.sh" >/dev/null 2>&1; then
  echo 'Accepted a certificate for another hostname.' >&2; exit 1
fi
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/wrong-key.pem" >/dev/null 2>&1
if SOURCE_KEY="$work/wrong-key.pem" bash "$root/scripts/lehigh-certs.sh" >/dev/null 2>&1; then
  echo 'Accepted a mismatched key.' >&2; exit 1
fi
cmp "$SOURCE_CERT" "$CERT_DIR/cert.pem"
cmp "$SOURCE_KEY" "$CERT_DIR/privkey.pem"
printf '%s\n' 'PASS: certificate/key copy, private-key permissions, and rejection without replacing installed files.'
