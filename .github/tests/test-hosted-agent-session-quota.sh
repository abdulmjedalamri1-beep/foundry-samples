#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../scripts/hosted-agent-retry.sh
source "$repo_root/.github/scripts/hosted-agent-retry.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_quota_error() {
  hosted_agent_is_session_quota_error "$1" || fail "expected quota error in $1"
}

assert_not_quota_error() {
  if hosted_agent_is_session_quota_error "$1"; then
    fail "unexpected quota error in $1"
  fi
}

printf 'x-ms-error-code: SessionQuotaExceeded\n' > "$work/subscription-header"
printf '{"error":{"code":"session_quota_exceeded"}}\n' > "$work/subscription-body"
printf 'x-ms-error-code: RegionalSessionQuotaExceeded\n' > "$work/regional-header"
printf '{"error":{"code":"regional_session_quota_exceeded"}}\n' > "$work/regional-body"
printf 'HTTP 429\n{"error":{"code":"TooManyRequests"}}\n' > "$work/throttling"
printf 'HTTP 500\n{"error":{"code":"server_error"}}\n' > "$work/server-error"

assert_quota_error "$work/subscription-header"
assert_quota_error "$work/subscription-body"
assert_quota_error "$work/regional-header"
assert_quota_error "$work/regional-body"
assert_not_quota_error "$work/throttling"
assert_not_quota_error "$work/server-error"

delays=()
for _ in $(seq 1 100); do
  delay=$(hosted_agent_quota_retry_delay)
  [ "$delay" -ge 50 ] && [ "$delay" -le 70 ] || fail "jitter outside 50-70 seconds: $delay"
  delays+=("$delay")
done
[ "$(printf '%s\n' "${delays[@]}" | sort -u | wc -l)" -gt 1 ] || fail "quota delay is not jittered"

HOSTED_AGENT_QUOTA_RETRY_DELAY_SECONDS=0
[ "$(hosted_agent_quota_retry_delay)" = "0" ] || fail "delay override was not honored"

runner="$repo_root/.github/workflows/hosted-agents-cloud-e2e-runner.yml"
responses_helper="$repo_root/.github/scripts/invoke_hosted_agent_responses.py"
grep -Fq 'CI_AGENT_SESSION_ID: ci-${{ github.run_id }}-${{ github.run_attempt }}-${{ inputs.shard }}-${{ strategy.job-index }}' "$runner" \
  || fail "runner does not define one run-specific session per cell"
response_session_uses=$((
  $(grep -Fc 'agent_session_id:$session_id' "$runner") +
  $(grep -Fc '"agent_session_id": env["CI_AGENT_SESSION_ID"]' "$responses_helper")
))
[ "$response_session_uses" -eq 4 ] \
  || fail "Responses invocation, approval continuation, and guardrails must use the cell session"
grep -Fq 'azd ai agent sessions create' "$runner" \
  || fail "runner does not explicitly create the cell session"
[ "$(grep -Fc -- '--session-id "$CI_AGENT_SESSION_ID"' "$runner")" -eq 6 ] \
  || fail "session create, invocation, files, traces, and both monitoring calls must use the cell session"
grep -Fq 'azd ai agent sessions delete "$CI_AGENT_SESSION_ID"' "$runner" \
  || fail "cleanup does not delete the cell session"
if grep -Fq 'SID=$(grep' "$runner"; then
  fail "runner still scrapes session IDs from invocation output"
fi

echo "Hosted-agent session quota helper tests passed."
