#!/usr/bin/env bash
#
# Deploys (or upgrades) ClickTrail on the VM. Run it ON the VM.
#
#   bash /opt/clicktrail/scripts/aws/deploy.sh <version>      for example: 0.1.0
#
# Steps: set the version, pull the images, start the stack, wait until it is healthy, run the smoke test.
# The images must already be published (tag a service repository with vX.Y.Z and let its release workflow finish).

set -euo pipefail

VERSION="${1:-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/clicktrail}"
COMPOSE_DIR="${INSTALL_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   (for example 0.1.0, without the leading v)" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must look like 1.2.3" >&2
  exit 2
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "${ENV_FILE} not found. Run scripts/aws/bootstrap-ec2.sh first." >&2
  exit 1
fi

cd "$COMPOSE_DIR"

echo "==> Deploying version ${VERSION}"
sed -i "s/^CLICKTRAIL_VERSION=.*/CLICKTRAIL_VERSION=${VERSION}/" "$ENV_FILE"

docker compose config --quiet
docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 300

echo "==> Containers"
docker compose ps

echo "==> Smoke test"
# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a
PROMETHEUS_URL="http://127.0.0.1:9090" "${INSTALL_DIR}/scripts/smoke-test.sh" \
  "http://127.0.0.1:8080" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"

docker image prune -f > /dev/null
echo "==> Version ${VERSION} is running"
