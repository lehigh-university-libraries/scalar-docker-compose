#!/usr/bin/env bash
# Validate inputs without starting containers or altering data.
set -euo pipefail
: "${SCALAR_DATA_DIR:?Set SCALAR_DATA_DIR to a separate books-only staging directory}"
[[ $SCALAR_DATA_DIR = /* && -d $SCALAR_DATA_DIR ]] || { echo 'SCALAR_DATA_DIR must be an existing absolute directory.' >&2; exit 1; }
resolved=$(realpath "$SCALAR_DATA_DIR")
[[ $resolved != /opt/scalar && $resolved != /opt/scalar/* ]] || { echo 'Refusing the live /opt/scalar tree; use a separate copy.' >&2; exit 1; }
for name in system codeigniter.php maintenance.html; do
  path="$resolved/$name"
  if [[ -e $path || -L $path ]]; then
    [[ -L $path && $(readlink "$path") == "/usr/local/share/scalar/$name" ]] || {
      echo "Refusing old application content at $path; use a separate books-only directory." >&2; exit 1;
    }
  fi
done
if [[ ${1:-} == --proxy ]]; then
  : "${TURNSTILE_SITE_KEY:?Set TURNSTILE_SITE_KEY for Traefik}"
  : "${TURNSTILE_SECRET_KEY:?Set TURNSTILE_SECRET_KEY for Traefik}"
  root=$(cd "$(dirname "$0")/.." && pwd)
  plugin="$root/conf/traefik/plugins/captcha-protect"
  if [[ ! -f $plugin/.traefik.yml || ! -f $plugin/main.go || ! -f $plugin/vendor/modules.txt ]]; then
    echo 'Vendored captcha-protect source is missing; restore conf/traefik/plugins/captcha-protect from this repository.' >&2
    exit 1
  fi
  [[ -s $root/certs/cert.pem && -s $root/certs/privkey.pem ]] || { echo 'Certificate or key file is missing.' >&2; exit 1; }
fi
printf 'Tree: %s\n' "$resolved"
du -sh "$resolved"
printf '%s\n' 'Verify staging database isolation, ownership, LDAP, runtime compatibility and available disk before starting.'
