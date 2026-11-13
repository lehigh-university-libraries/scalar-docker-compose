#!/usr/bin/env bash
# Exercise the actual Compose services with isolated files and no public ports.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
work=$(mktemp -d)
project="scalar-smoke-$$"
export SCALAR_DATA_DIR="$work/books"
export TURNSTILE_SITE_KEY=test-site-key TURNSTILE_SECRET_KEY=test-secret-key
export SCALAR_DB_HOSTNAME=unconfigured.invalid SCALAR_DB_USERNAME='' SCALAR_DB_PASSWORD='' SCALAR_DB_DATABASE=''
export SCALAR_USE_LDAP=false SCALAR_USE_AD_LDAP=false
compose=(docker compose --env-file /dev/null -p "$project" -f "$root/compose.yaml" -f "$work/override.yaml")
cleanup() {
  result=$?
  if ((result)); then "${compose[@]}" logs --tail=100 || true; fi
  "${compose[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker image rm "$project-traefik" >/dev/null 2>&1 || true
  python3 - "$work" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
  return "$result"
}
trap cleanup EXIT
mkdir -p "$work/plugins"
cp -R conf/traefik/plugins/captcha-protect "$work/plugins/"
cp conf/traefik/dynamic.yml "$work/dynamic.yml"
# Simulate campus clients on the isolated test subnet; retain real client-IP matching.
python3 - "$work/dynamic.yml" "198.19.$(( $$ % 250 )).0/24" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("ClientIP(`128.180.0.0/16`)", "ClientIP(`" + sys.argv[2] + "`)"))
PYTHON
cp conf/traefik/challenge.tmpl.html "$work/challenge.tmpl.html"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=scalar.lehigh.edu \
  -keyout "$work/privkey.pem" -out "$work/cert.pem" >/dev/null 2>&1
proxy_image=$(SCALAR_DATA_DIR="$work" docker compose --env-file /dev/null config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["traefik"]["image"])')
printf 'FROM %s\nCOPY dynamic.yml /etc/traefik/dynamic.yml\nCOPY challenge.tmpl.html /etc/traefik/challenge.tmpl.html\nCOPY cert.pem /run/secrets/CERT_PUBLIC_KEY\nCOPY privkey.pem /run/secrets/CERT_PRIVATE_KEY\nCOPY plugins/captcha-protect /plugins-local/src/github.com/libops/captcha-protect\n' "$proxy_image" > "$work/Dockerfile"
cat > "$work/override.yaml" <<YAML
services:
  scalar:
    secrets: !reset []
    volumes: !override
      - smoke-books:/opt/scalar
  traefik:
    image: $project-traefik
    build: $work
    ports: !reset []
    secrets: !reset []
    volumes: !override
      - traefik-state:/data
volumes:
  smoke-books: {}
# The plugin exempts private client IPs. Use the reserved benchmarking range
# so test requests exercise CAPTCHA without trusting spoofed forwarding headers.
networks:
  default:
    ipam:
      config: !override
        - subnet: 198.19.$(( $$ % 250 )).0/24
YAML
"${compose[@]}" build traefik
"${compose[@]}" up -d --wait --wait-timeout 180
"${compose[@]}" exec -T scalar sh -ec 'mkdir -p /opt/scalar/smoke; printf media-ok > /opt/scalar/smoke/media.txt; chmod 700 /opt/scalar/smoke'
# Reproduce inaccessible files copied from an old host installation.
if "${compose[@]}" exec -T --user nginx scalar sh -s -- check < scripts/permissions.sh; then
  echo 'Expected the permissions check to reject root-owned book content.' >&2
  exit 1
fi
"${compose[@]}" exec -T --user root scalar sh -s -- fix < scripts/permissions.sh
"${compose[@]}" up -d --wait --wait-timeout 180 --force-recreate scalar
# Expand command substitutions inside the container, not on the host.
# shellcheck disable=SC2016
"${compose[@]}" exec -T scalar sh -exc '
  test "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: scalar.lehigh.edu" http://traefik/)" = 301
  test "$(curl -s -o /tmp/monitor -w "%{http_code}" -H "Host: campus-monitor.example" http://traefik/)" = 200
  grep -qx OK /tmp/monitor
  test "$(curl -ks -o /tmp/monitor -w "%{http_code}" -H "Host: campus-monitor.example" https://traefik/)" = 200
  grep -qx OK /tmp/monitor
  test "$(curl -ks -o /dev/null -w "%{http_code}" -H "Host: campus-monitor.example" https://traefik/not-a-health-path)" = 404
  test "$(curl -ks -o /tmp/challenge -w "%{http_code}" -H "Host: scalar.lehigh.edu" https://traefik/)" = 429
  grep -q "Verifying connection | Lehigh University Libraries" /tmp/challenge
  curl -fsS http://localhost/smoke/media.txt | grep -q media-ok
  test "$(curl -s -A SemrushBot -o /dev/null -w "%{http_code}" http://localhost/smoke/media.txt)" = 403
  test "$(curl -s -o /dev/null -w "%{http_code}" http://localhost/system/application/config/database.php)" = 404
'
# Loopback is outside the simulated campus range; forwarding headers cannot grant access.
# shellcheck disable=SC2016 # Expand response inside the container, not on the host.
"${compose[@]}" exec -T traefik sh -ec '
  response=$(wget --no-check-certificate -S -O /dev/null --header="Host: campus-monitor.example" --header="X-Forwarded-For: 128.180.155.198" https://127.0.0.1/ 2>&1 || true)
  printf "%s\n" "$response" | grep -q "404 Not Found"
'
"${compose[@]}" exec -T --user nginx scalar sh -s -- check < scripts/permissions.sh
printf '%s\n' 'PASS: Scalar health, HTTPS redirect, CAPTCHA challenge, media, bot blocks, and protected configuration.'
