.DEFAULT_GOAL := up

.PHONY: up build down lint test database permissions fix-permissions lehigh-certs

# Application images are built in buildkit; prepare their pinned releases here.
build:
	docker compose pull

up: build
	docker compose up -d --wait --wait-timeout 180
	$(MAKE) database permissions

# Keep book files and CAPTCHA state for the next deployment.
down:
	docker compose down

# Validate without requiring local credentials or a populated .env.
lint:
	find scripts -type f -name '*.sh' -exec shellcheck {} +
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	SCALAR_DATA_DIR=/tmp/scalar-staging \
	TURNSTILE_SITE_KEY=test-site-key TURNSTILE_SECRET_KEY=test-secret-key \
	docker compose --env-file /dev/null config --quiet

test:
	./scripts/test-certs.sh
	./scripts/smoke-test.sh

permissions:
	docker compose exec -T --user nginx scalar sh -s -- check < scripts/permissions.sh

# Run only on a staged books-only directory while the application is stopped.
fix-permissions:
	@test -z "$$(docker compose ps --status running -q scalar)" || { echo 'Run make down before repairing book-data permissions.' >&2; exit 1; }
	docker compose run --rm -T --no-deps --user root --entrypoint sh scalar -s -- fix < scripts/permissions.sh

database:
	./scripts/database.sh

# Copy the host-managed certificate/key into the local Compose secret files.
lehigh-certs:
	sudo ./scripts/lehigh-certs.sh
