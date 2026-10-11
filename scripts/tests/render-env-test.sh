#!/usr/bin/env bash
#
# Tests for scripts/aws/render-env.sh. Run: scripts/tests/render-env-test.sh   (needs bash and jq; no AWS needed)

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../aws" && pwd)/render-env.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'GITHUB_OWNER=sunilvarmatongali\nCLICKTRAIL_VERSION=0.1.0\nPUBLIC_BASE_URL=http://example.com:8080\n' > "$WORK/config.env"

VALID='{
  "MYSQL_ROOT_PASSWORD": "rootpass1234",
  "MYSQL_PASSWORD": "mysqlpass1234",
  "POSTGRES_PASSWORD": "pgpass1234",
  "JWT_SECRET": "0123456789abcdef0123456789abcdef",
  "GRAFANA_ADMIN_PASSWORD": "grafanapass1",
  "ADMIN_EMAIL": "admin@example.com",
  "ADMIN_PASSWORD": "adminpass1234",
  "SOMETHING_ELSE": "ignored"
}'

PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "  PASS  $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL  $1"; }

# expect_failure <description> <json> <text that must appear in the error>
expect_failure() {
  local description="$1" json="$2" expected="$3" output
  if output="$("$SCRIPT" "$WORK/config.env" <<< "$json" 2>&1 > /dev/null)"; then
    fail "$description (it should have been rejected)"
  elif [[ "$output" == *"$expected"* ]]; then
    pass "$description"
  else
    fail "$description (wrong error: $output)"
  fi
}

echo "render-env.sh"

rendered="$("$SCRIPT" "$WORK/config.env" <<< "$VALID")"

if [[ "$rendered" == *"CLICKTRAIL_VERSION=0.1.0"* ]]; then pass "keeps the non-secret settings"; else fail "keeps the non-secret settings"; fi
if [[ "$rendered" == *"JWT_SECRET=0123456789abcdef0123456789abcdef"* ]]; then pass "adds the secrets"; else fail "adds the secrets"; fi
if [[ "$rendered" != *"SOMETHING_ELSE"* ]]; then pass "ignores unknown keys"; else fail "ignores unknown keys"; fi

expect_failure "rejects input that is not a JSON object" '"just a string"' "not a JSON object"
expect_failure "rejects a missing key" "$(jq 'del(.POSTGRES_PASSWORD)' <<< "$VALID")" "POSTGRES_PASSWORD"
expect_failure "rejects an empty value" "$(jq '.MYSQL_PASSWORD = ""' <<< "$VALID")" "MYSQL_PASSWORD"
expect_failure "rejects a dollar sign (Compose would interpret it)" "$(jq '.ADMIN_PASSWORD = "pa$$word1234"' <<< "$VALID")" "ADMIN_PASSWORD"
expect_failure "rejects a newline in a value" "$(jq '.MYSQL_ROOT_PASSWORD = "line1\nline2"' <<< "$VALID")" "MYSQL_ROOT_PASSWORD"
expect_failure "rejects a space in a value" "$(jq '.GRAFANA_ADMIN_PASSWORD = "has space"' <<< "$VALID")" "GRAFANA_ADMIN_PASSWORD"
expect_failure "rejects a short JWT secret" "$(jq '.JWT_SECRET = "tooshort"' <<< "$VALID")" "at least 32"

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]]
