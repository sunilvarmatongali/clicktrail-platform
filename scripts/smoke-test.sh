#!/usr/bin/env bash
#
# End-to-end smoke test: walks through the ClickTrail user stories against a running stack.
#
# Usage:
#   scripts/smoke-test.sh <gateway-url> <admin-email> <admin-password>
#   scripts/smoke-test.sh http://localhost:8080 admin@example.com 'my-admin-password'
#
# Optional environment variables:
#   PUBLIC_HOST   check from outside that the internal ports are closed (host or IP of the machine)
#   PROMETHEUS_URL  also check that Prometheus sees every service (for example http://localhost:9090)
#
# Needs: bash, curl, jq. Exit code 0 = everything passed.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <gateway-url> <admin-email> <admin-password>" >&2
  exit 2
fi

BASE_URL="${1%/}"
ADMIN_EMAIL="$2"
ADMIN_PASSWORD="$3"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }

# check "<description>" "<expected>" "<actual>"
check() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected: $2, got: $3)"; fi
}

# http_status <curl arguments...>  prints only the HTTP status code
http_status() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

# json_post <url> <json> [curl arguments...]  prints "<status> <body>"
json_post() {
  local url="$1" body="$2"
  shift 2
  curl -s --max-time 10 -w '\n%{http_code}' -H 'Content-Type: application/json' -d "$body" "$@" "$url" |
    awk 'NR==1{b=$0; next} {s=$0} END{print s " " b}'
}

require() {
  command -v "$1" > /dev/null || { echo "missing tool: $1" >&2; exit 2; }
}
require curl
require jq

echo "Smoke test against ${BASE_URL}"

# ---------------------------------------------------------------- 0. wait for the stack
echo "0. Waiting for the gateway and the URL service"
ready=false
for _ in $(seq 1 60); do
  # An unknown short code answers 404 only when gateway AND url-service (AND its databases) work.
  if [[ "$(http_status "${BASE_URL}/r/smoke-probe")" == "404" ]]; then ready=true; break; fi
  sleep 3
done
if [[ "$ready" != true ]]; then
  fail "stack did not become ready within 3 minutes"
  echo "RESULT: ${PASSED} passed, ${FAILED} failed"
  exit 1
fi
pass "gateway answers and reaches the URL service"

# A previous run ends by exhausting the login limit (step 7). If that is still active, wait for the window to end.
if [[ "$(http_status -X POST -H 'Content-Type: application/json' -d '{"email":"probe@example.com","password":"probe-password"}' "${BASE_URL}/api/v1/auth/login")" == "429" ]]; then
  echo "   The login rate limit from an earlier run is still active, waiting 65 seconds"
  sleep 65
fi

# ---------------------------------------------------------------- story 1: register and log in
echo "1. Register and log in"
SUFFIX="$(date +%s)-$RANDOM"
USER_EMAIL="smoke-${SUFFIX}@example.com"
USER_PASSWORD="smoke-password-${SUFFIX}"
OTHER_EMAIL="other-${SUFFIX}@example.com"

result="$(json_post "${BASE_URL}/api/v1/auth/register" "{\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASSWORD}\"}")"
check "register a new user -> 201" "201" "${result%% *}"

result="$(json_post "${BASE_URL}/api/v1/auth/register" "{\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASSWORD}\"}")"
check "register the same email again -> 409" "409" "${result%% *}"

result="$(json_post "${BASE_URL}/api/v1/auth/login" "{\"email\":\"${USER_EMAIL}\",\"password\":\"wrong-${USER_PASSWORD}\"}")"
check "login with a wrong password -> 401" "401" "${result%% *}"

result="$(json_post "${BASE_URL}/api/v1/auth/login" "{\"email\":\"${USER_EMAIL}\",\"password\":\"${USER_PASSWORD}\"}")"
check "login with the right password -> 200" "200" "${result%% *}"
USER_TOKEN="$(jq -r '.accessToken // empty' <<< "${result#* }")"
check "login returns an access token" "true" "$([[ -n "$USER_TOKEN" ]] && echo true || echo false)"

# a second user, used to prove that users cannot see each other's data
json_post "${BASE_URL}/api/v1/auth/register" "{\"email\":\"${OTHER_EMAIL}\",\"password\":\"${USER_PASSWORD}\"}" > /dev/null
result="$(json_post "${BASE_URL}/api/v1/auth/login" "{\"email\":\"${OTHER_EMAIL}\",\"password\":\"${USER_PASSWORD}\"}")"
OTHER_TOKEN="$(jq -r '.accessToken // empty' <<< "${result#* }")"

# ---------------------------------------------------------------- story 2: create a short link and open it
echo "2. Create a short link and open it"
TARGET="https://example.com/clicktrail/smoke/${SUFFIX}"
result="$(json_post "${BASE_URL}/api/v1/links" "{\"originalUrl\":\"${TARGET}\"}" -H "Authorization: Bearer ${USER_TOKEN}")"
check "create a link -> 201" "201" "${result%% *}"
SHORT_CODE="$(jq -r '.shortCode // empty' <<< "${result#* }")"
check "the response contains a short code" "true" "$([[ -n "$SHORT_CODE" ]] && echo true || echo false)"

status="$(http_status "${BASE_URL}/api/v1/links" -X POST -H 'Content-Type: application/json' -d "{\"originalUrl\":\"${TARGET}\"}")"
check "create a link without a token -> 401" "401" "$status"

status="$(http_status "${BASE_URL}/api/v1/links" -X POST -H "Authorization: Bearer ${USER_TOKEN}" -H 'Content-Type: application/json' -d '{"originalUrl":"javascript:alert(1)"}')"
check "create a link with a javascript: address -> 400" "400" "$status"

for attempt in 1 2 3; do
  redirect="$(curl -s -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}' "${BASE_URL}/r/${SHORT_CODE}")"
  check "open the short link (#${attempt}) -> 302 to the target" "302 ${TARGET}" "$redirect"
done
check "open an unknown short link -> 404" "404" "$(http_status "${BASE_URL}/r/doesnotexist")"

# ---------------------------------------------------------------- story 3: click statistics
echo "3. Click statistics (events travel through Kafka, so we wait for them)"
count=0
for _ in $(seq 1 30); do
  body="$(curl -s --max-time 10 -H "Authorization: Bearer ${USER_TOKEN}" "${BASE_URL}/api/v1/links/${SHORT_CODE}/stats")"
  count="$(jq -r '.clickCount // 0' <<< "$body")"
  [[ "$count" -ge 3 ]] && break
  sleep 2
done
check "my link shows 3 clicks" "3" "$count"

check "another user cannot see my link's statistics -> 404" "404" \
  "$(http_status -H "Authorization: Bearer ${OTHER_TOKEN}" "${BASE_URL}/api/v1/links/${SHORT_CODE}/stats")"
check "statistics without a token -> 401" "401" "$(http_status "${BASE_URL}/api/v1/links/${SHORT_CODE}/stats")"
body="$(curl -s --max-time 10 -H "Authorization: Bearer ${USER_TOKEN}" "${BASE_URL}/api/v1/links")"
check "my link list contains my link" "true" "$(jq -r --arg code "$SHORT_CODE" '[.items[].shortCode] | index($code) != null' <<< "$body")"

# ---------------------------------------------------------------- story 4: admin totals (RBAC)
echo "4. Admin totals (role-based access)"
check "a normal user is refused the admin total -> 403" "403" \
  "$(http_status -H "Authorization: Bearer ${USER_TOKEN}" "${BASE_URL}/api/v1/admin/stats/total")"
check "an anonymous caller is refused the admin total -> 401" "401" "$(http_status "${BASE_URL}/api/v1/admin/stats/total")"

result="$(json_post "${BASE_URL}/api/v1/auth/login" "{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASSWORD}\"}")"
check "the admin can log in -> 200" "200" "${result%% *}"
ADMIN_TOKEN="$(jq -r '.accessToken // empty' <<< "${result#* }")"
body="$(curl -s --max-time 10 -H "Authorization: Bearer ${ADMIN_TOKEN}" "${BASE_URL}/api/v1/admin/stats/total")"
total="$(jq -r '.totalClickCount // 0' <<< "$body")"
check "the admin sees a total of at least 3 clicks" "true" "$([[ "$total" -ge 3 ]] && echo true || echo false)"

# ---------------------------------------------------------------- security checks
echo "5. Security checks"
check "a client-sent X-User-Id without a token is ignored -> 401" "401" \
  "$(http_status -H 'X-User-Id: 1' -H 'X-User-Role: admin' "${BASE_URL}/api/v1/links")"
check "a client-sent X-User-Role does not make a user an admin -> 403" "403" \
  "$(http_status -H "Authorization: Bearer ${USER_TOKEN}" -H 'X-User-Role: admin' "${BASE_URL}/api/v1/admin/stats/total")"
check "metrics are not served on the public port -> 404" "404" "$(http_status "${BASE_URL}/metrics")"

if [[ -n "${PUBLIC_HOST:-}" ]]; then
  echo "   Checking from outside that internal ports are closed on ${PUBLIC_HOST}"
  for port in 8081 8082 8083 8090 9083 3306 5432 27017 6379 9092 9090 3000; do
    if timeout 3 bash -c "exec 3<>/dev/tcp/${PUBLIC_HOST}/${port}" 2> /dev/null; then
      fail "port ${port} is reachable from outside"
    else
      pass "port ${port} is closed"
    fi
  done
fi

# ---------------------------------------------------------------- story 5: observability
if [[ -n "${PROMETHEUS_URL:-}" ]]; then
  echo "6. Observability"
  # Prometheus scrapes every 15 seconds, so a service that started a moment ago may need one more round.
  down="unknown"
  for _ in $(seq 1 12); do
    targets="$(curl -s --max-time 10 "${PROMETHEUS_URL%/}/api/v1/targets" || true)"
    down="$(jq -r '[.data.activeTargets[] | select(.health != "up") | .labels.job] | join(",")' <<< "$targets" 2> /dev/null || echo unknown)"
    [[ -z "$down" ]] && break
    sleep 5
  done
  check "every Prometheus target is up" "" "$down"
fi

# ---------------------------------------------------------------- rate limiting (last: it uses up the login allowance)
echo "7. Rate limiting"
limited=false
for _ in $(seq 1 15); do
  status="$(http_status -X POST -H 'Content-Type: application/json' -d '{"email":"nobody@example.com","password":"wrong-password"}' "${BASE_URL}/api/v1/auth/login")"
  if [[ "$status" == "429" ]]; then limited=true; break; fi
done
check "too many login attempts are answered with 429" "true" "$limited"

echo
echo "RESULT: ${PASSED} passed, ${FAILED} failed"
[[ "$FAILED" -eq 0 ]]
