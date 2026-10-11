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
#
# Steps:
#   1. set the versions in config.env (non-secret settings),
#   2. read the secrets from AWS Secrets Manager (with the instance role, nothing is stored in git or GitHub)
#      and build the .env file for Docker Compose,
#   3. log in to the image registry (if the secret contains a token), pull the images, start the stack, wait for health,
#   4. run the smoke test.
# The images must already be published (tag a service repository with vX.Y.Z and let its release workflow finish).
#
# Settings (environment variables, all optional):
#   SECRET_ID    name of the secret in Secrets Manager        (default: clicktrail/prod)
#   AWS_REGION   region of the secret                         (default: the region of this instance)

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/clicktrail}"
COMPOSE_DIR="${INSTALL_DIR}/compose"
CONFIG_FILE="${COMPOSE_DIR}/config.env"
ENV_FILE="${COMPOSE_DIR}/.env"
SECRET_ID="${SECRET_ID:-clicktrail/prod}"
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

cd "$COMPOSE_DIR"

# --- Step 0: the non-secret settings live in config.env. Create it from an older .env if this is the first run. ---
if [[ ! -f "$CONFIG_FILE" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    echo "==> Creating config.env from the existing .env (first run of the new secret handling)"
    grep -E '^(GITHUB_OWNER|CLICKTRAIL_VERSION|PUBLIC_BASE_URL|(GATEWAY|AUTH_SERVICE|URL_SERVICE|ANALYTICS_SERVICE)_VERSION)=' "$ENV_FILE" > "$CONFIG_FILE"
  else
    echo "${CONFIG_FILE} not found. Run scripts/aws/bootstrap-ec2.sh first." >&2
    exit 1
  fi
fi

# set_config NAME VALUE: updates a line in config.env, or adds it.
set_config() {
  if grep -q "^$1=" "$CONFIG_FILE"; then
    sed -i "s/^$1=.*/$1=$2/" "$CONFIG_FILE"
  else
    echo "$1=$2" >> "$CONFIG_FILE"
  fi
}

# --- Step 1: versions ---
echo "==> Deploying version ${VERSION}"
set_config CLICKTRAIL_VERSION "$VERSION"
# Forget per-service versions from an earlier deployment, so what runs is always what this command says.
sed -i -E '/^(GATEWAY|AUTH_SERVICE|URL_SERVICE|ANALYTICS_SERVICE)_VERSION=/d' "$CONFIG_FILE"

for override in "$@"; do
  if [[ ! "$override" =~ ^(gateway|auth-service|url-service|analytics-service)=([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "bad argument '${override}': use service=version, for example gateway=0.1.1" >&2
    exit 2
  fi
  service="${BASH_REMATCH[1]}"
  service_version="${BASH_REMATCH[2]}"
  variable="$(echo "$service" | tr 'a-z-' 'A-Z_')_VERSION"
  echo "    ${service} -> ${service_version}"
  set_config "$variable" "$service_version"
done

# --- Step 2: secrets from AWS Secrets Manager ---
if [[ -z "${AWS_REGION:-}" ]]; then
  imds_token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
  AWS_REGION="$(curl -fsS -H "X-aws-ec2-metadata-token: ${imds_token}" http://169.254.169.254/latest/meta-data/placement/region)"
fi
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "==> Reading the secrets (${SECRET_ID}, ${AWS_REGION})"
secret_json="$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text)"

# The .env file is built in a temporary file with owner-only permissions and only then put in place.
umask 077
temporary_env="$(mktemp "${COMPOSE_DIR}/.env.XXXXXX")"
trap 'rm -f "$temporary_env"' EXIT
"${INSTALL_DIR}/scripts/aws/render-env.sh" "$CONFIG_FILE" <<< "$secret_json" > "$temporary_env"
mv "$temporary_env" "$ENV_FILE"
trap - EXIT

# --- Step 3: registry login, images, start ---
registry_user="$(jq -r '.GHCR_PULL_USER // empty' <<< "$secret_json")"
registry_token="$(jq -r '.GHCR_PULL_TOKEN // empty' <<< "$secret_json")"
if [[ -n "$registry_user" && -n "$registry_token" ]]; then
  echo "==> Logging in to the image registry (credentials from the secret)"
  printf '%s' "$registry_token" | docker login ghcr.io -u "$registry_user" --password-stdin > /dev/null
else
  echo "==> No registry credentials in the secret: using the existing docker login"
fi
unset secret_json registry_token

docker compose config --quiet
docker compose pull
docker compose up -d --remove-orphans --wait --wait-timeout 300

echo "==> Containers"
docker compose ps

# --- Step 4: smoke test ---
echo "==> Smoke test"
# shellcheck disable=SC1090
set -a && source "$ENV_FILE" && set +a
PROMETHEUS_URL="http://127.0.0.1:9090" "${INSTALL_DIR}/scripts/smoke-test.sh" \
  "http://127.0.0.1:8080" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"

docker image prune -f > /dev/null
echo "==> Version ${VERSION} is running"
