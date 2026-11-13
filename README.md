# Scalar Compose deployment

A production-oriented, **unverified staging** Compose proposal for the existing Lehigh deployment is documented in [DEPLOYMENT.md](DEPLOYMENT.md). It mounts a separate books-only directory, uses the Scalar release bundled in the image, and retains the existing external database. The image includes the LDAP contribution from upstream PR #272; verify authentication against the staging directory. Complete discovery and acceptance before any production changes; the published Scalar 2.6.10 image with PHP 8.4 is a compatibility candidate that must be validated before use.

Start by copying `sample.env` to `.env` and setting the isolated book directory and Turnstile keys. Supply application credentials in `./secrets` and place the TLS pair in `./certs` as described below. Then run:

```sh
make up
```

`make build` pulls the published images from buildkit. The CAPTCHA plugin is vendored under `conf/traefik/plugins/captcha-protect`; its `UPSTREAM` file records the source revision. No plugin clone is needed at deployment or test time. `make up` prepares those dependencies and starts the services, waiting for health checks. `make down` stops the services while preserving book data and CAPTCHA state.

Use Docker Engine 25 or newer and Docker Compose 2.24.4 or newer. Install ShellCheck locally (for example, `brew install shellcheck` on macOS). Run `make lint` to validate scripts and Compose without local credentials. Run `make test` to exercise the pinned images, HTTPS routing, and CAPTCHA in an isolated temporary Compose project. This test requires no production data or credentials.

GitHub Actions runs the same `make lint` and `make test` targets on pushes and pull requests.

Nginx and PHP-FPM run as UID 100 / GID 101 in the pinned image. Startup sets the books directory itself to `root:nginx` with mode `1775`; existing book files also need to be writable by the worker. `make up` checks this using the actual container user. For a copied books-only directory with old Apache ownership, stop the application with `make down`, run `make fix-permissions`, then `make up`. The repair changes ownership and owner permissions of book files and directories without following symlinks into application code. Use it only on the staged book-data copy. Run `make permissions` to repeat the check.

Scalar and Traefik check health every second during a 15-second startup period;
the first success marks them healthy immediately. Normal checks run every 30 seconds.

`make up` now also waits up to approximately one minute for a database connection and `SELECT 1` using Scalar's bundled configuration and application account. Run `make database` to repeat the read-only check. The container health check still tests PHP-FPM separately; it does not monitor the database continuously or validate the schema. HAProxy must use Galera-aware backend health checks.

### Start Scalar with systemd

For the production checkout at `/opt/scalar-docker-compose`, install the unit
after configuring `.env`, secret files, certificates, HAProxy, and UFW:

```sh
sudo install -m 0644 /opt/scalar-docker-compose/scripts/systemd/scalar.service /etc/systemd/system/scalar.service
sudo systemctl daemon-reload
sudo systemctl enable --now scalar.service
sudo systemctl status scalar.service
```

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

For a local HAProxy listener, set `SCALAR_DB_HOSTNAME=host.docker.internal` in `.env`.
The application service already maps that hostname to Docker's host gateway.
Verify the gateway on the VM instead of assuming its address:

```sh
docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}'
sudo ss -ltnp '( sport = :3306 )'
```

Bind the HAProxy MySQL frontend to that gateway and port 3306, retaining its
loopback listener if host applications need it. A Compose-created gateway can
be absent when HAProxy starts after reboot; `network-online.target` does not
create it. Do not expose MySQL on all interfaces to work around this race.

`scripts/systemd/haproxy-docker.conf` orders HAProxy after Docker and adds a
five-second restart delay, preserving the packaged restart policy. An operator
can install it after reviewing the host's existing drop-ins:

```sh
sudo install -d /etc/systemd/system/haproxy.service.d
sudo install -m 0644 scripts/systemd/haproxy-docker.conf /etc/systemd/system/haproxy.service.d/docker.conf
sudo systemctl daemon-reload
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl reset-failed haproxy
sudo systemctl restart haproxy
```

The drop-in does not change HAProxy listener addresses or create a project
network. Add and verify the stable listener before switching the application
to it, then remove the old project-gateway bind. Keep the port private using
the host firewall. If a custom project bridge must be retained, provision it
independently before HAProxy and declare it external in Compose.

Host changes are not applied by `make up`. Verify the listener, application
queries, and recovery after an approved reboot. Keep Galera-aware backend
checks: a listening TCP port alone does not establish that a node can serve
the application. See the [OJS host setup guide](https://github.com/lehigh-university-libraries/ojs#haproxy-and-galera-on-the-docker-host)
for the confirmed boot failure, diagnostics, and dependency ordering.

#### Allow the container subnet through UFW

For local development, add this to your `.env` so all `docker compose` and
Make targets use the local override:

```dotenv
COMPOSE_FILE=compose.yaml:compose.local.yaml
```

`compose.local.yaml` removes the pinned IPAM subnet and lets Docker allocate an
available range. Local development does not require the production HAProxy,
UFW, or Docker daemon changes below. CI's smoke test also overrides the subnet
with its own isolated test range.

On a host with UFW's default incoming policy set to deny, the HAProxy bind is
not sufficient: allow the Scalar network to reach the host's MySQL listener.
Compose pins its default network to `SCALAR_NETWORK_SUBNET`, which defaults to
`172.18.0.0/16` and is listed in `sample.env`. Keep that value in `.env` so
network recreation uses the same source subnet. Choose a range that does not
overlap host, VPN, or other Docker networks. HAProxy continues listening on the
separately pinned Docker host gateway, `172.17.0.1`; it does not bind the
application network's gateway.

Find the destination address and the Compose network's source subnet separately:

```sh
docker compose exec scalar getent hosts host.docker.internal
docker network inspect scalar-docker-compose_default \
  --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
```

On this VM these return `172.17.0.1` and `172.18.0.0/16`, respectively. Use the
actual network name and addresses on other hosts. Allow only that source subnet
to reach the listener:

```sh
sudo ufw allow from 172.18.0.0/16 to 172.17.0.1 port 3306 proto tcp
make database
```

This requires an incoming rule because the destination is the Docker host,
rather than a routed rule. Use the subnet instead of a container's individual
IP so container recreation does not break access. If the temporary rule for
`172.18.0.2` was added while troubleshooting, remove it after adding the subnet
rule:

```sh
sudo ufw delete allow from 172.18.0.2 to 172.17.0.1 port 3306 proto tcp
```

If HAProxy is listening on the correct address but `make database` times out,
test TCP from the application container:

```sh
docker compose exec scalar php -r '
$c = @fsockopen("host.docker.internal", 3306, $errno, $error, 3);
echo $c ? "TCP connected\n" : "TCP failed: $errno $error\n";
'
```

A TCP timeout points to networking or firewall rules. A successful TCP connection
still requires healthy Galera backends and valid application credentials.
Docker preserves existing networks across reboots, and the explicit subnet also
keeps the UFW rule valid after `docker compose down` / `up`. UFW saves the rule
across reboots. To adopt this configuration for an existing auto-allocated
network, recreate the network during a service interruption:

```sh
docker compose down
docker compose up -d --wait
make database
```

Do not add `--volumes`: retain book data and CAPTCHA state. If deliberately
changing `SCALAR_NETWORK_SUBNET`, update the UFW source range to match. The
HAProxy host-gateway bind remains unchanged.

#### Pin the host gateway

This host configuration is for production Linux VMs only. Do not apply it to
Docker Desktop or a local development engine; the application Compose overrides
do not change daemon settings.

The Linux VM standard is an explicit Docker default-bridge address of
`172.17.0.1/16`. Merge the setting from `scripts/docker/daemon.example.json`
into `/etc/docker/daemon.json`:

```json
{
  "bip": "172.17.0.1/16"
}
```

Preserve all other daemon settings, including an existing `data-root`. Do not
copy this fragment over an existing daemon configuration. Confirm the subnet
does not overlap host routes or other Docker networks, and reconcile any
`bridge`, `--bip`, or custom `host-gateway-ip` configuration. Do not assign this
same subnet to a Compose network.

After an approved Docker restart, verify `docker0` and `docker network inspect
bridge` show `172.17.0.1`. Compose continues using
`host.docker.internal:host-gateway`, which resolves to this daemon-level address
on these Linux VMs. Application networks can remain separate; OJS's existing
`172.23.0.1` project gateway is not this database listener address.

In the existing HAProxy `mysql-cluster` listener, retain the host loopback bind
if needed and use the pinned gateway:

```haproxy
bind 127.0.0.1:3306
bind 172.17.0.1:3306
```

Keep the existing Galera servers and health checks. Add and test the new bind
and application connection before removing the old `172.23.0.1` bind. On a
running VM, perform this migration only when the new address already exists;
otherwise HAProxy will reject the reload. The systemd drop-in orders HAProxy
after Docker so the pinned address is available at boot, independent of any
application Compose project. Apply daemon changes in a maintenance window;
`make up` does not alter host networking.

Docker documents the daemon's [`bip` setting](https://docs.docker.com/engine/network/drivers/bridge/#configure-the-default-bridge-network)
and [`host-gateway` resolution](https://docs.docker.com/reference/cli/dockerd/#configure-host-gateway-ip).

### Startup-rendered Scalar configuration

The buildkit confd image change renders `database.php`, `config.php`, and
`local_settings.php` from environment variables or `/run/secrets/NAME` files
before PHP-FPM starts. Configuration is root-owned and worker-readable (0640);
PHP-FPM keeps `clear_env=yes` with no Scalar environment passthrough.
`SCALAR_BASE_URL` controls generated links independently of request Host headers.
The templates start from Scalar 2.6.10, the latest upstream release verified on
2026-11-12, rather than the legacy production configuration. New upstream
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
names when migrating. Preserve legacy LDAP domain/object-class restrictions
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

Copy the pair before the initial `make up`. After a renewal, run the helper
again and recreate only Traefik so Docker remounts the replaced secret files:

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
This requires a Scalar image rebuilt from the updated Nginx base; promote its
published digest before using the endpoint. Verify the public URL returns 200
and `google-site-verification: google204a4e549d4da46a.html`.

## Database backup copies

`db-backup` runs at 02:00 UTC, writing compressed SQL to `./backups/daily/`
and the latest successful dump of each month to `./backups/monthly/`.
It retains seven daily dates and the previous twelve completed months, plus the
current month's latest copy. Pruning runs only after a successful dump.
SET backs up Galera every 30 days; these additional copies are a LOCKSS
(Lots of Copies Keep Stuff Safe) precaution. They cover the configured application
database; uploaded files and other volumes still need their own backups.

Build/publish Buildkit's `mysql-backup` image before rollout, then set
`MYSQL_BACKUP_IMAGE` in `.env` to its published GHCR image reference **with digest**.
The default `:main` is the release handoff reference, not an immutable pin.
For an immediate dump: `docker compose exec db-backup /command/with-contenv mysql-backup.sh`.
See Buildkit's `images/mysql-backup/README.md` for restore instructions and limits.
