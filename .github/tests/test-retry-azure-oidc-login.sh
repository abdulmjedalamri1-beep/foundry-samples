#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
retry_script="$repo_root/.github/scripts/retry-azure-oidc-login.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat > "$work/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_CURL_ARGS_FILE"
printf '%s\n' '{"value":"header.payload.signature"}'
EOF

cat > "$work/az" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "login" ]; then
  count=0
  [ ! -f "$MOCK_COUNT_FILE" ] || count=$(cat "$MOCK_COUNT_FILE")
  count=$((count + 1))
  echo "$count" > "$MOCK_COUNT_FILE"

  echo "cli.azure.cli.core.sdk.policies: Request URL: 'https://management.azure.com/subscriptions?api-version=2022-12-01&sig=url-secret'" >&2
  echo "cli.azure.cli.core.sdk.policies: Request method: 'GET'" >&2
  echo "cli.azure.cli.core.sdk.policies: Authorization: raw-secret" >&2
  echo "cli.azure.cli.core.sdk.policies: Response status: 403" >&2
  echo "cli.azure.cli.core.sdk.policies:     'Content-Type': 'application/json; charset=utf-8'" >&2
  echo "cli.azure.cli.core.sdk.policies:     'x-ms-request-id': 'safe-request-id'" >&2
  echo "attacker: Request URL: 'https://attacker.example/prefix-secret'" >&2
  echo "cli.azure.cli.core.sdk.policies: arbitrary response body raw-body-secret" >&2
  echo "cli.azure.cli.core.sdk.policies: Response content:" >&2
  echo "cli.azure.cli.core.sdk.policies: Request URL: 'https://attacker.example/marker-secret'" >&2
  echo "ERROR: JSON is invalid: Expecting value" >&2

  [ "$count" -ge 2 ]
  exit
fi

[ "$1 $2" = "account set" ]
EOF

chmod +x "$work/curl" "$work/az"

output=$(PATH="$work:$PATH" \
  MOCK_COUNT_FILE="$work/count" \
  MOCK_CURL_ARGS_FILE="$work/curl-args" \
  AZURE_CLIENT_ID=client \
  AZURE_TENANT_ID=tenant \
  AZURE_SUBSCRIPTION_ID=subscription \
  ACTIONS_ID_TOKEN_REQUEST_URL='https://token.actions.example/id?x=1' \
  ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-secret \
  AZURE_LOGIN_MAX_ATTEMPTS=3 \
  AZURE_LOGIN_RETRY_BACKOFF_SECONDS=0 \
  "$retry_script")

grep -Fq 'Azure login attempt 2/3 (debug diagnostics enabled)' <<< "$output" \
  || fail "second attempt did not run with diagnostics"
grep -Fq 'Azure CLI login succeeded on attempt 3/3.' <<< "$output" \
  || fail "third attempt did not succeed"
grep -Fq "Request URL: 'https://management.azure.com/subscriptions?[query redacted]'" <<< "$output" \
  || fail "request URL was not safely logged"
grep -Fq "Content-Type: 'application/json; charset=utf-8'" <<< "$output" \
  || fail "content type was not safely logged"
grep -Fq "x-ms-request-id: 'safe-request-id'" <<< "$output" \
  || fail "request ID was not safely logged"
grep -Fq 'Error summary: Azure CLI received invalid JSON.' <<< "$output" \
  || fail "invalid JSON summary was not logged"
curl_args=$(paste -sd ' ' "$work/curl-args")
[[ " $curl_args " == *' --connect-timeout 10 '* ]] \
  || fail "OIDC token request does not have a 10-second connect timeout"
[[ " $curl_args " == *' --max-time 30 '* ]] \
  || fail "OIDC token request does not have a 30-second total timeout"

for secret in raw-secret raw-body-secret url-secret prefix-secret marker-secret; do
  if grep -Fq "$secret" <<< "$output"; then
    fail "diagnostic output leaked $secret"
  fi
done

[ "$(cat "$work/count")" = "2" ] || fail "expected exactly two retry attempts"

runner="$repo_root/.github/workflows/hosted-agents-cloud-e2e-runner.yml"
grep -Fq 'uses: azure/login@v3' "$runner" \
  || fail "primary login must use the supported Node 24 Azure Login action"
retry_block=$(sed -n '/name: Retry Azure login/,/run: .*retry-azure-oidc-login.sh/p' "$runner")
if grep -Fq 'continue-on-error: true' <<< "$retry_block"; then
  fail "retry step must fail the job after its final attempt"
fi
if grep -Fq 'name: Confirm Azure login' "$runner"; then
  fail "workflow still has a redundant post-retry authentication gate"
fi
auth_guard="always() && (steps.azure_login.outcome == 'success' || steps.azure_login_retry.outcome == 'success')"
[ "$(grep -Fc "$auth_guard" "$runner")" = "5" ] \
  || fail "only the five always-run Azure-dependent steps should need explicit auth guards"

workflow="$repo_root/.github/workflows/hosted-agents-cloud-e2e.yml"
classifier_regex=$(grep -F 'if echo "$changed_files" | grep -qE' "$workflow" \
  | sed -E "s/.*grep -qE '([^']+)'.*/\1/")
for path in .github/scripts/retry-azure-oidc-login.sh .github/tests/test-retry-azure-oidc-login.sh; do
  grep -qE "$classifier_regex" <<< "$path" \
    || fail "$path does not trigger the full cloud E2E matrix"
done

echo "Azure OIDC login retry tests passed."
