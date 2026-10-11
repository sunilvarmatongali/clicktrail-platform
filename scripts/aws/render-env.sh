#!/usr/bin/env bash
#
# Builds the .env file for Docker Compose from two sources:
#   - a config file with the NON-secret settings (versions, owner, public address)   -> first argument
#   - the secrets, as a JSON object read from standard input (AWS Secrets Manager)    -> stdin
#
# The result is printed to standard output. Nothing is written to disk by this script, and it never prints the secrets
# anywhere else. Unknown keys in the JSON are ignored. Usage:
#
#   render-env.sh /opt/clicktrail/compose/config.env < secret.json > .env
#
# The secret must contain exactly the keys listed in REQUIRED below. Values are checked, because they end up in a file that
# Docker Compose interprets: a stray "$" or newline could change the meaning of the file.

set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "usage: $0 <config.env>   (secret JSON on standard input)" >&2
  exit 2
fi
CONFIG="$1"

REQUIRED=(MYSQL_ROOT_PASSWORD MYSQL_PASSWORD POSTGRES_PASSWORD JWT_SECRET GRAFANA_ADMIN_PASSWORD ADMIN_EMAIL ADMIN_PASSWORD)
ALLOWED_CHARACTERS='^[A-Za-z0-9@._:+=/-]+$'
MINIMUM_JWT_SECRET_LENGTH=32

json="$(cat)"
if ! jq -e 'type == "object"' <<< "$json" > /dev/null 2>&1; then
  echo "the secret is not a JSON object" >&2
  exit 1
fi

for key in "${REQUIRED[@]}"; do
  value="$(jq -r --arg k "$key" '.[$k] // empty | tostring' <<< "$json")"
  if [[ -z "$value" ]]; then
    echo "the secret has no value for ${key}" >&2
    exit 1
  fi
  if [[ ! "$value" =~ $ALLOWED_CHARACTERS ]]; then
    echo "the value of ${key} contains characters that are not allowed (use letters, digits and @ . _ : + = / -)" >&2
    exit 1
  fi
done

jwt_length="$(jq -r '.JWT_SECRET | length' <<< "$json")"
if [[ "$jwt_length" -lt "$MINIMUM_JWT_SECRET_LENGTH" ]]; then
  echo "JWT_SECRET must have at least ${MINIMUM_JWT_SECRET_LENGTH} characters" >&2
  exit 1
fi

cat "$CONFIG"
echo
echo "# ---- secrets: rendered at deploy time from AWS Secrets Manager. Do not edit this part. ----"
for key in "${REQUIRED[@]}"; do
  printf '%s=%s\n' "$key" "$(jq -r --arg k "$key" '.[$k] | tostring' <<< "$json")"
done
