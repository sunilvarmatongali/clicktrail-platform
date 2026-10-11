#!/usr/bin/env bash
#
# ONE-TIME MIGRATION HELPER. Run it ON the VM (over SSH or Session Manager).
#
# Prints the current secrets from /opt/clicktrail/compose/.env as a JSON object, ready to paste into AWS Secrets Manager
# ("Other type of secret" -> "Plaintext"). Reusing the SAME values matters: the databases already exist with these passwords,
# and a changed password would lock the services out of their own data.
#
# The output contains secrets. Copy it straight into the console and close the terminal; do not save it in a file or a chat.

set -euo pipefail

ENV_FILE="${1:-/opt/clicktrail/compose/.env}"
[[ -f "$ENV_FILE" ]] || { echo "${ENV_FILE} not found" >&2; exit 1; }

KEYS=(MYSQL_ROOT_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD JWT_SECRET GRAFANA_ADMIN_PASSWORD ADMIN_EMAIL ADMIN_PASSWORD)

filter='{}'
for key in "${KEYS[@]}"; do
  value="$(grep -E "^${key}=" "$ENV_FILE" | head -n 1 | cut -d= -f2-)"
  [[ -n "$value" ]] || { echo "${key} is missing in ${ENV_FILE}" >&2; exit 1; }
  filter="${filter} | .${key} = \"${value}\""
done

jq -n "$filter"
echo >&2
echo "Optional: add GHCR_PULL_USER and GHCR_PULL_TOKEN to the secret so that deployments log in to the image registry themselves." >&2
