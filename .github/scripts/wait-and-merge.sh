#!/usr/bin/env bash
# .github/scripts/wait-and-merge.sh
#
# Polls a pull request until it is mergeable (no conflicts, no pending checks),
# then merges it directly via `gh pr merge --rebase`.
#
# WHY DIRECT MERGE INSTEAD OF `gh pr merge --auto`:
#   The sync workflow must observe the merge before it saves marks. Polling and
#   merging within the run keeps that ordering explicit and avoids deferred
#   auto-merge state that would require open-PR/marks reconciliation.
#
# Args:
#   $1  PR_URL  — full PR URL or number (passed through to gh)
#   $2  REPO    — owner/name of the public repo
#
# Env (with defaults):
#   MERGE_POLL_TIMEOUT   seconds before giving up        (default 600)
#   MERGE_POLL_INTERVAL  seconds between polls           (default 15)
#   GH_TOKEN             required — token with merge permission
#
# Exit codes:
#   0  merged successfully
#   1  conflict / timeout / merge call failed
set -euo pipefail

PR_URL="${1:?PR_URL is required as arg 1}"
REPO="${2:?REPO (owner/name) is required as arg 2}"

TIMEOUT_SECONDS="${MERGE_POLL_TIMEOUT:-600}"
POLL_INTERVAL="${MERGE_POLL_INTERVAL:-15}"
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

echo "Polling $PR_URL for mergeability (timeout: ${TIMEOUT_SECONDS}s, interval: ${POLL_INTERVAL}s)..."

while :; do
    if [[ "$(date +%s)" -ge "$DEADLINE" ]]; then
        echo "::error::Timed out waiting for PR to become mergeable after ${TIMEOUT_SECONDS}s."
        gh pr view "$PR_URL" --repo "$REPO" --json mergeable,mergeStateStatus,statusCheckRollup || true
        exit 1
    fi

    VIEW=$(gh pr view "$PR_URL" --repo "$REPO" \
        --json mergeable,mergeStateStatus,statusCheckRollup)

    MERGEABLE=$(echo "$VIEW" | jq -r '.mergeable')
    MERGE_STATE=$(echo "$VIEW" | jq -r '.mergeStateStatus')
    # Count checks still running. Treat empty/missing rollup as 0.
    PENDING=$(echo "$VIEW" | jq '[.statusCheckRollup[]? | select(.status == "PENDING" or .status == "QUEUED" or .status == "IN_PROGRESS")] | length')

    echo "  mergeable=$MERGEABLE mergeStateStatus=$MERGE_STATE pending_checks=$PENDING"

    if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
        echo "::error::PR has merge conflicts. Cannot merge."
        exit 1
    fi

    if [[ "$MERGEABLE" == "MERGEABLE" && "$PENDING" == "0" ]]; then
        echo "PR is mergeable with no pending checks; merging..."
        break
    fi

    sleep "$POLL_INTERVAL"
done

# Direct merge runs as the App and remains subject to the public main ruleset.
# Do not use --auto (the workflow must observe the merge) or --admin.
#
# Rebase is the only supported merge strategy. An unrelated-history branch is
# not an incremental sync and must fail rather than land as a tree replacement.
if ! gh pr merge "$PR_URL" --repo "$REPO" --rebase 2> /tmp/merge_err; then
    cat /tmp/merge_err >&2
    exit 1
fi
echo "Merged: $PR_URL"
