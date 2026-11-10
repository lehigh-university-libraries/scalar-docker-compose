#!/usr/bin/env bash
# Stage the host-managed TLS pair as local Compose secrets, as in ArchivesSpace.
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_CERT=${SOURCE_CERT:-/etc/ssl/certs/le/lehigh.edu.pem}
SOURCE_KEY=${SOURCE_KEY:-/etc/ssl/private/le/lehigh.edu.key}
EXPECTED_HOST=${EXPECTED_HOST:-scalar.lehigh.edu}
CERT_DIR=${CERT_DIR:-$root/certs}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cp -- "$SOURCE_CERT" "$work/cert.pem"
cp -- "$SOURCE_KEY" "$work/privkey.pem"

openssl x509 -in "$work/cert.pem" -noout -checkend 86400 >/dev/null 2>&1 || {
  echo 'Certificate is expired or expires within 24 hours.' >&2; exit 1;
}
# x509 -checkhost can return success for a mismatch on older OpenSSL versions.
openssl verify -purpose sslserver -verify_hostname "$EXPECTED_HOST" \
  -untrusted "$work/cert.pem" "$work/cert.pem" >/dev/null 2>&1 || {
  echo 'Certificate chain is not trusted for TLS server use or does not cover the configured Scalar hostname.' >&2; exit 1;
}
cert_public_key=$(openssl x509 -in "$work/cert.pem" -pubkey -noout |
  openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)
key_public_key=$(openssl pkey -in "$work/privkey.pem" -pubout -outform DER </dev/null 2>/dev/null | sha256sum)
[[ $cert_public_key == "$key_public_key" ]] || {
  echo 'Certificate and private key do not match.' >&2; exit 1;
}
install -d -m 0755 "$CERT_DIR"
install -m 0644 "$work/cert.pem" "$CERT_DIR/cert.pem"
install -m 0600 "$work/privkey.pem" "$CERT_DIR/privkey.pem"
printf '%s\n' 'Installed certs/cert.pem and certs/privkey.pem. Recreate Traefik after renewal to remount the files.'
