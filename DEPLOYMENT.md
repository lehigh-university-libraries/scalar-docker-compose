# Scalar Docker migration

This is a staging proposal for lifting the **existing** Scalar installation into Docker. The runtime image is built in [`buildkit/images/scalar`](../buildkit/images/scalar); this repository deploys that image with Traefik. The image bundles Scalar 2.6.10 under `/usr/local/share/scalar`; startup links its code into an operator-managed books-only bind mount at `/opt/scalar`. Book directories and uploads remain persistent. The database remains external. No data is copied, imported, upgraded, or initialized automatically.

**Do not cut over yet.** The buildkit PHP 8.4 image is a supported staging candidate, not evidence of compatibility with the live Scalar version. Confirm the actual version and extensions, compare the live `.htaccess` to the proposed Nginx rules, and complete the acceptance checklist. Nginx does not read `.htaccess`. The Nginx image translates the bundled upstream rules and blocks PHP entry points other than `codeigniter.php`; live custom rules or additional required entry points must be identified and ported. The existing three user-agent blocks are retained. The image uses the buildkit Nginx/PHP-FPM/s6 base and its existing `nginx` worker UID/GID: run `make permissions` to verify access to the copied books. If ownership needs repair, stop the app with `make down`, then explicitly run `make fix-permissions` on the staged books-only directory before `make up`.

## Discovery and prerequisites

- Review PHP version and extensions, Scalar release, Git status and local patches, LDAP settings, full `.htaccess`, server configuration, cron, upload limits, external binaries and absolute paths. The application source and LDAP backport are maintained in buildkit; inspect the live installation for any additional customizations. Run `sudo ./scripts/discover.sh /opt/scalar` and redact output before sharing; inspect config and LDAP files privately. Never paste secrets or credential-bearing Git remotes into logs or tickets.
- Determine the actual DB host, port, server version, size, TLS, access rules, account permissions and live backup process. Confirm Galera/HAProxy independently. Use a least-privilege user; do not assume the archived `scalar-2.1.6.sql.gz` or `scalar-2.5.15.sql.gz` is a current backup. Inventory all book directories, media, filesystem ownership and writable paths.
- Check `df -h / /var /home` and inode space for images, builds, copies, DB dumps, logs and backups. `/home` was observed with about 12 GiB free; `/var` was only about 3.2 GiB total. IT should configure Docker's host `data-root` as `/home/docker` and verify with `docker info` before migration. Moving an existing Docker data root is a separate administrative operation. Select an independent bind-mount location only after checking capacity and backup policy.
- Confirm network access to the DB, LDAP and other dependencies from Docker. For LDAPS, set `SCALAR_LDAP_SERVER=ldaps://directory.example.edu` and `SCALAR_LDAP_PORT=636` (or the directory's LDAPS port), ensure its certificate matches the hostname, and install the issuing CA in the container trust store. Verify certificate validation and login with a test account, and compare the live LDAP patch and authentication configuration with the bundled release; implement and test any required patch in the image before cutover. Review egress, mail and scheduled jobs; isolate staging from production side effects.
- Review the currently supported PHP branches on [php.net](https://www.php.net/supported-versions.php/). PHP 8.4 must pass application tests before use; if compatibility requires an EOL runtime, document the security exception and remediation rather than silently upgrading or deploying an unsupported runtime.

For targeted manual inspection:

```sh
php -v; php -m; apache2ctl -M; apache2ctl -S
mysql --version 2>/dev/null || mariadb --version
sudo du -sh /opt/scalar
sudo du -h --max-depth=1 /opt/scalar | sort -h | tail -30
sudo find /opt/scalar -maxdepth 2 -type d \( -name media -o -name uploads \)
sudo find /opt/scalar -maxdepth 2 -type f -mtime -30 | head -100
sudo cat /opt/scalar/.htaccess
sudo sed -n '1,200p' /opt/scalar/INSTALL.txt
sudo cat /opt/scalar/.gitmodules
sudo find /opt/scalar -maxdepth 4 \( -iname '*config*' -o -iname '*database*' \) -type f | head -100
sudo grep -RIl 'ldap' /opt/scalar/system /opt/scalar/system-v2.0.2 2>/dev/null | head -50
cd /opt/scalar && git status --short && git remote -v
```

Redact passwords, bind credentials, tokens, internal endpoints and sensitive filenames before sharing. The `find` results are exploratory, not a complete asset inventory.

## Isolated staging

1. Verify restorable backups of the complete application tree and live DB. Quiesce writes or take coordinated snapshots so files and DB are consistent. Restore the full tree to a **new backup path** outside the repository and restore the database to an isolated staging DB with separate credentials. Inventory book slugs against the database and manually copy only audited book directories to a second, empty books-only directory. Preserve required permissions and ACLs; inspect symlinks and do not copy application code, configuration, SQL archives, or secrets into the served directory. Do not mount the original `/opt/scalar` writable. Compare data counts and representative checksums.
2. Configure the bundled release for the staging DB, LDAP and other isolated services using its supported environment variables. Review all live configuration and custom code against the release: host code and LDAP patches are not loaded. The pinned image contains a backport of upstream PR #272. Configure `SCALAR_LDAP_EMAIL_DOMAIN` and `SCALAR_LDAP_OBJECT_CLASS` as needed, then verify that the configuration covers the live LDAP customization and passes staging authentication tests. Do not bake or commit credentials. Verify the Nginx/PHP-FPM worker UID/GID can access required book files. Startup sets the books directory itself to root:nginx and mode 1775, without recursively changing its contents; confirm this is appropriate for the host. The sticky directory allows book creation while protecting the image-owned links. Startup refuses existing `system`, `codeigniter.php`, or `maintenance.html` entries other than the expected links.
3. Copy `sample.env` to `.env`; set `SCALAR_DATA_DIR` to the absolute path of the separate books-only directory. Set `SCALAR_DB_USERNAME` and `SCALAR_DB_DATABASE` in `.env`. Populate the six `./secrets/SCALAR_*` files listed in README with staging credentials and the existing application salt/encryption key. Compose pins the published Scalar 2.6.10 image by digest; review and update that reference in `compose.yaml` when upgrading. Select non-production Turnstile keys, copy the matching certificate chain/key into `certs/cert.pem` and `certs/privkey.pem` using `scripts/lehigh-certs.sh`, and keep the loopback bind and unprivileged staging ports. The private key is mounted as a Compose secret into Traefik only, never into the Scalar application container or image. Ensure the certificate covers the staging hostname.
4. The captcha-protect source is committed under `conf/traefik/plugins/captcha-protect`; no plugin download is needed. For staging, adapt the router hostname in `conf/traefik/dynamic.yml` and the Turnstile widget to your isolated test hostname. Review the diff before later deploying the production hostname.
5. With a trusted locally edited `.env` (sourcing executes shell syntax), run:

```sh
set -a; . ./.env; set +a
./scripts/preflight.sh --proxy
docker compose config --quiet
docker compose up -d
docker compose ps
docker compose logs --tail=100
```

The preflight rejects `/opt/scalar` and its descendants, but cannot detect all bind-mounted or aliased live data; the operator must verify isolation. Port 80 and 443 are bound to loopback on staging ports 18080 and 18443 by default; only after acceptance set `BIND_ADDRESS=0.0.0.0`, `HTTP_PORT=80`, and `HTTPS_PORT=443` and configure host firewall/DNS for production. Scalar has no host-published port. Traefik terminates HTTPS and redirects HTTP; it preserves the host header. Nginx sends `HTTPS=on` to PHP-FPM because only Traefik's HTTPS router reaches the app. Do not attach untrusted containers to the Compose network: peers could reach Nginx directly. The PHP-FPM `/status` health check is local to the container, checks neither DB nor books, and is not acceptance evidence.

Traefik includes the pinned local CAPTCHA plugin, a rate limiter, campus exemptions and a persistent state volume. The existing SemrushBot, DotBot and YandexBot 403 policy is in Nginx. Check real client IPs through Docker and the actual VM network before relying on per-client limits or exemptions; the configuration assumes Traefik directly receives clients. If a load balancer is later placed in front, configure narrowly scoped trusted proxy addresses and test spoof resistance. CAPTCHA's circuit breaker may bypass the challenge when Turnstile is unavailable. Certificates are operator-managed; arrange renewal and a Traefik restart when files change.

## Acceptance

- Compare DB counts, book slugs and representative media checksums to the coordinated snapshot. Test the homepage, old and new book URLs, media, navigation and all production rewrite rules. Confirm external URLs use `https://scalar.lehigh.edu/`.
- Test LDAP login and certificate validation, authorized editing, creation and deletion of a disposable staging book, file uploads, permissions, mail and outbound HTTPS. Verify cron and any external tools. Use a separate staging DB and credentials, and prevent external side effects.
- Confirm no SQL archives, `.git`, hidden files, backup files, patches, or config secrets are accessible via HTTP, including nested, encoded, rewritten and symlink paths. Nginx deny rules are defense in depth; move historical dumps and sensitive material outside the webroot after testing compatibility. Audit other extensions and app endpoints. Confirm the DB and app are not publicly exposed and confirm bot blocks, challenge completion, client IPs and logs. Never put secrets into image layers, repository, logs or tickets.
- Monitor `docker compose logs` and application/PHP-FPM logs; test a full backup restore. Keep environment files mode 0600; environment variables are visible to Docker administrators and may appear in rendered Compose configuration. Do not enable simultaneous production and staging writes to the same data.

## Cutover and rollback

Coordinate a maintenance window and stop all writes. Create a final consistent DB/files snapshot, restore it to the reviewed destination, compare checksums and counts, and repeat acceptance checks. Stop the old application before starting the new production writer; never have both writing to the same DB and files. Direct public ports 80/443 and DNS to Traefik only after the checks succeed, then monitor.

Keep the old service configuration and matched original snapshot until rollback is no longer needed. For rollback, stop the containers and all writers, restore the prior service and a consistent DB/files snapshot as needed, restore routing, and validate. Account for writes made after cutover: restoring an older snapshot discards them. Test recovery periodically. `docker compose down` preserves the host tree; `down -v` removes the CAPTCHA state volume. Review Scalar, PHP, plugin and DB upgrades separately on a restored staging clone; the bundled release differs from the unknown production version; audit and test any required database upgrade and the existing LDAP patch before proceeding.
