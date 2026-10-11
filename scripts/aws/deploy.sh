#!/usr/bin/env bash
#
# Deploys (or upgrades) ClickTrail on the VM. Run it ON the VM.
#
#   bash /opt/clicktrail/scripts/aws/deploy.sh <version> [service=version ...]
#
# Examples:
#   deploy.sh 0.1.0                      every service at 0.1.0
#   deploy.sh 0.1.0 gateway=0.1.1        everything at 0.1.0, except the gateway at 0.1.1 (a patch release)
#
# Services: gateway, auth-service, url-service, analytics-service.
# Steps: set the versions, pull the images, start the stack, wait until it is healthy, run the smoke test.
# The images must already be published (tag a service repository with vX.Y.Z and let its release workflow finish).

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/clicktrail}"
COMPOSE_DIR="${INSTALL_DIR}/compose"
ENV_FILE="${COMPOSE_DIR}/.env"
VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version> [service=version ...]   (for example: $0 0.1.0 gateway=0.1.1)" >&2
  exit 2
fi
VERSION="$1"
shift

if [[ ! "$VERSION" =~ $VERSION_PATTERN ]]; then
  echo "version must look like 1.2.3 (without the leading v)" >&2
  exit 2
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "${ENV_FILE} not found. Run scripts/aws/bootstrap-ec2.sh first." >&2
  exit 1
fi

# set_env NAME VALUE: updates a line in .env, or adds it.
set_env() {
  if grep -q "^$1=" "$ENV_FILE"; then
    sed -i "s/^$1=.*/$1=$2/" "$ENV_FILE"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}

cd "$COMPOSE_DIR"

echo "==> Deploying version ${VERSION}"
set_env CLICKTRAIL_VERSION "$VERSION"
# Forget per-service versions from an earlier deployment, so what runs is always what this command says.
sed -i -E '/^(GATEWAY|AUTH_SERVICE|URL_SERVICE|ANALYTICS_SERVICE)_VERSION=/d' "$ENV_FILE"

for override in "$@"; do
  if [[ ! "$override" =~ ^(gateway|auth-service|url-service|analytics-service)=([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "bad argument '${override}': use service=version, for example gateway=0.1.1" >&2
    exit 2
  fi
  service="${BASH_REMATCH[1]}"
  service_version="${BASH_REMATCH[2]}"
  variable="$(echo "$service" | tr 'a-z-' 'A-Z_')_VERSION"
  echo "    ${service} -> ${service_version}"
  set_env "$variable" "$service_version"
done

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
