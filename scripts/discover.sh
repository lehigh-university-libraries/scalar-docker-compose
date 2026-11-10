#!/usr/bin/env bash
# Read-only inventory. Run on the VM and redact output before sharing.
set -u
root=${1:-/opt/scalar}
for cmd in php apache2ctl; do
  if command -v "$cmd" >/dev/null; then
    case "$cmd" in
      php) php -v; php -m ;;
      apache2ctl) apache2ctl -M; apache2ctl -S ;;
    esac
  fi
done
if command -v mariadb >/dev/null; then mariadb --version; elif command -v mysql >/dev/null; then mysql --version; fi
df -h / /var /home "$root"
du -sh "$root"
du -h --max-depth=1 "$root" 2>/dev/null | sort -h | tail -30
find "$root" -maxdepth 2 -type d \( -name media -o -name uploads \) -print
find "$root" -maxdepth 2 -type f -mtime -30 -print | head -100
find "$root" -maxdepth 4 -type f \( -iname '*config*' -o -iname '*database*' \) -print | head -100
if [[ -d $root/.git ]]; then git -C "$root" status --short; git -C "$root" rev-parse HEAD; fi
printf '%s\n' 'Review .htaccess, INSTALL.txt, .gitmodules, LDAP changes, and configs privately; redact credentials and remote URLs before sharing.'
