# Scalar Compose

Scalar runs in production at https://scalar.lehigh.edu/ using the published Buildkit image, Traefik, a persistent books-only directory, and an external database. The image includes the LDAP contribution from upstream PR #272.

## Operations

`make build` pulls the pinned published images. `make up` pulls images and starts services, waiting for health checks, database connectivity, and book permissions. `make down` stops services while preserving book data and CAPTCHA state. The CAPTCHA plugin is vendored under `conf/traefik/plugins/captcha-protect`; its `UPSTREAM` file records the source revision.

Use Docker Engine 25 or newer and Docker Compose 2.24.4 or newer. Install ShellCheck locally (for example, `brew install shellcheck` on macOS). Run `make lint` to validate scripts and Compose without local credentials. Run `make test` to exercise the pinned images, HTTPS routing, and CAPTCHA in an isolated temporary Compose project. This test requires no production data or credentials.

GitHub Actions runs the same `make lint` and `make test` targets on pushes and pull requests.

Nginx and PHP-FPM run as UID 100 / GID 101 in the pinned image. Startup sets the books directory itself to `root:nginx` with mode `1775`; existing book files also need to be writable by the worker. `make up` checks this using the actual container user. For a copied books-only directory with old Apache ownership, stop the application with `make down`, run `make fix-permissions`, then `make up`. The repair changes ownership and owner permissions of book files and directories without following symlinks into application code. Use it only on the books-only data directory while the application is stopped. Run `make permissions` to repeat the check.

Scalar and Traefik check health every second during a 15-second startup period;
the first success marks them healthy immediately. Normal checks run every 30 seconds.

`make up` now also waits up to approximately one minute for a database connection and `SELECT 1` using Scalar's bundled configuration and application account. Run `make database` to repeat the read-only check. The container health check still tests PHP-FPM separately; it does not monitor the database continuously or validate the schema. HAProxy must use Galera-aware backend health checks.

### Systemd

The production checkout is `/opt/scalar-docker-compose`; `scalar.service` uses
`scripts/systemd/scalar.service`. Inspect its status with
`systemctl status scalar.service`.

The unit starts after Docker, HAProxy, and network readiness; waits for container
health; then checks database connectivity and book permissions. It uses the
pinned images without pulling updates at boot. Enabling it also adds it to
Docker's startup dependencies so it starts again after Docker is restarted.
Stopping the unit stops the containers while preserving their network, volumes,
and data. Docker restart policies still apply independently, so startup ordering
does not replace database retries. Inspect unit failures with
`journalctl -u scalar.service` and application logs with `docker compose logs`.

### Campus monitoring

Requests to `/` from campus source IPs (`128.180.0.0/16`) with a Host header
other than `scalar.lehigh.edu` receive a plain `200 OK` from Traefik's internal
ping service on HTTP or HTTPS. This checks Traefik availability only, not Scalar
or Galera. The canonical hostname continues through the application router,
HTTP-to-HTTPS redirect, and existing CAPTCHA rules. Other paths and non-campus
clients do not match the health fallback. Matching uses the connection's source
IP, not `X-Forwarded-For`. HTTPS still requires a certificate matching the
hostname used by the monitor.

### HAProxy and Galera on the Docker host

Scalar connects to the host HAProxy listener through
`SCALAR_DB_HOSTNAME=host.docker.internal`. Docker pins the host gateway to
`172.17.0.1/16`; HAProxy listens on `172.17.0.1:3306` and uses Galera-aware
backend checks. `scripts/systemd/haproxy-docker.conf` orders HAProxy after Docker
and adds a five-second restart delay.

The Compose network uses `SCALAR_NETWORK_SUBNET` (default `172.18.0.0/16`).
UFW allows that source subnet to reach the host listener on port 3306.
Keep the firewall rule aligned with the subnet if it changes.

Run `make database` to check connectivity using the application account.
If it times out, inspect the listener and test TCP from the container:

```sh
sudo ss -ltnp '( sport = :3306 )'
docker compose exec scalar php -r '
$c = @fsockopen("host.docker.internal", 3306, $errno, $error, 3);
echo $c ? "TCP connected\n" : "TCP failed: $errno $error\n";
'
```

A TCP timeout points to networking or firewall rules. A successful TCP connection
still requires healthy Galera backends and valid application credentials.

### Local development

Add this to your local `.env`:

```dotenv
COMPOSE_FILE=compose.yaml:compose.local.yaml
```

`compose.local.yaml` lets Docker allocate an available subnet. Local development
does not require the production HAProxy, UFW, or Docker daemon configuration.
CI's smoke test uses its own isolated subnet.

### Startup-rendered Scalar configuration

The buildkit confd image change renders `database.php`, `config.php`, and
`local_settings.php` from environment variables or `/run/secrets/NAME` files
before PHP-FPM starts. Configuration is root-owned and worker-readable (0640);
PHP-FPM keeps `clear_env=yes` with no Scalar environment passthrough.
`SCALAR_BASE_URL` controls generated links independently of request Host headers.
The templates start from Scalar 2.6.10. New upstream
settings, including media URL and filesystem storage options, are preserved.

`sample.env` contains deployment settings and overrides of image defaults.
Set `SCALAR_DB_USERNAME` and `SCALAR_DB_DATABASE` in `.env`.
Store application secrets in the following Git-ignored files, one value per
file (the filename must match exactly):

```
secrets/SCALAR_DB_PASSWORD
secrets/SCALAR_SHASALT
secrets/SCALAR_ENCRYPTION_KEY
secrets/SCALAR_GOOGLE_MAPS_KEY
secrets/SCALAR_RECAPTCHA2_SITE_KEY
secrets/SCALAR_RECAPTCHA2_SECRET_KEY
```

Create `./secrets` with mode `0700` and its files with mode `0600`. Supply the
existing database password, salt, and encryption key; leave unused API-key
files empty. All six files must exist before starting Compose. Compose mounts
them only into Scalar at `/run/secrets/NAME`; s6 imports their contents before
confd renders the PHP configuration. Application secrets do not belong in `.env`.
The pinned published image includes this startup-rendered configuration.
See buildkit's `images/scalar/README.md` for the complete image contract.

Application logs and PHP errors go to stderr, Nginx access logs to stdout, and
Nginx errors to stderr; inspect them with `docker compose logs scalar`.
Preserve existing salts, encryption keys, database prefixes and session-table
names when updating configuration. Preserve legacy LDAP domain/object-class restrictions
using `SCALAR_LDAP_EMAIL_DOMAIN` and `SCALAR_LDAP_OBJECT_CLASS`; the new upstream
configuration does not use the legacy `ldap_domain`/`ldap_user_object_class`
keys. Set the approved directory URI/base DN and secrets privately.

### TLS certificates

As in ArchivesSpace, Compose reads the certificate chain from
`./certs/cert.pem` and its private key from `./certs/privkey.pem`. Only Traefik
receives these files, through Compose secrets. Certificate files are ignored by
Git; `certs/.keep` preserves the directory.

On the Linux host, copy the host-managed certificate pair with:

```sh
make lehigh-certs
```

The helper defaults to `/etc/ssl/certs/le/lehigh.edu.pem` and
`/etc/ssl/private/le/lehigh.edu.key`. If the host uses different filenames,
run it with explicit source paths:

```sh
sudo SOURCE_CERT=/path/to/fullchain.pem SOURCE_KEY=/path/to/private.key \
  ./scripts/lehigh-certs.sh
```

The helper checks trust, hostname coverage for `scalar.lehigh.edu`, at least
24 hours of remaining validity, and a matching private key before copying.
It installs the chain with mode `0644` and the private key with mode `0600`.
A `*.lib.lehigh.edu` certificate cannot cover `scalar.lehigh.edu`. For an
isolated staging hostname, supply `EXPECTED_HOST` and a matching trusted
certificate; locally trusted staging CAs can be selected with `SSL_CERT_FILE`.

After a renewal, run the helper again and recreate only Traefik so Docker remounts the replaced secret files:

```sh
docker compose up -d --no-deps --force-recreate --wait traefik
```

The helper copies files only; it does not restart services, install a renewal
hook, or change the host certificate updater. Keep these renewal steps in the
host certificate renewal procedure.

### PHP log severity

`SCALAR_PHP_ERROR_REPORTING` accepts a numeric PHP error-reporting bitmask.
Use `4437` for fatal/error categories (`E_ERROR`, `E_PARSE`, `E_CORE_ERROR`,
`E_COMPILE_ERROR`, `E_USER_ERROR`, `E_RECOVERABLE_ERROR`), or `32767` to include
warnings, notices, and deprecations. `0` disables PHP error logging through
Scalar's error handler. The mask applies to native PHP reporting and
CodeIgniter's PHP-error logger; application messages such as login events still
follow `SCALAR_LOG_THRESHOLD`. Logs continue to go to stderr. The deployment
Compose defaults to `4437`; the image defaults to `32767`. Recreate Scalar after
changing the setting. This requires an image built with the severity-filter
support; PHP-FPM does not read application environment variables directly.

### Google Search Console

The shared Buildkit Nginx image reserves `/google204a4e549d4da46a.html` and serves
its image-owned verification file outside Scalar's document root. The exact path
is excluded from captcha-protect so Google can fetch it without a challenge.
The public URL returns 200 and `google-site-verification: google204a4e549d4da46a.html`.

## Database backup copies

`db-backup` runs at 02:00 UTC, writing compressed SQL to `./backups/daily/`
and the latest successful dump of each month to `./backups/monthly/`.
It retains seven daily dates and the previous twelve completed months, plus the
current month's latest copy. Pruning runs only after a successful dump.
SET backs up Galera every 30 days; these additional copies are a LOCKSS
(Lots of Copies Keep Stuff Safe) precaution. They cover the configured application
database; uploaded files and other volumes still need their own backups.

The backup image is pinned by digest directly in Compose. Update that reference
when promoting a new published Buildkit `mysql-backup` image.
For an immediate dump: `docker compose exec db-backup /command/with-contenv mysql-backup.sh`.
See Buildkit's `images/mysql-backup/README.md` for restore instructions and limits.
