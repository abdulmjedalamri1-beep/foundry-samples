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
#   SYNC_SCOPE_ASSERT_SCRIPT  path to assert-sync-scope.sh
#   SYNC_SCOPE_PUBLIC_REPO    checked-out public repo path
#   SYNC_SCOPE_CONFIG         private sync-config.json path
#   SYNC_BRANCH               generated public branch name
#   SYNC_ADDITIONAL_PATHS     normalized optional scope additions
#
# Exit codes:
#   0  merged successfully
#   1  conflict / timeout / merge call failed
set -euo pipefail

PR_URL="${1:?PR_URL is required as arg 1}"
REPO="${2:?REPO (owner/name) is required as arg 2}"
: "${SYNC_SCOPE_ASSERT_SCRIPT:?SYNC_SCOPE_ASSERT_SCRIPT is required}"
: "${SYNC_SCOPE_PUBLIC_REPO:?SYNC_SCOPE_PUBLIC_REPO is required}"
: "${SYNC_SCOPE_CONFIG:?SYNC_SCOPE_CONFIG is required}"
: "${SYNC_BRANCH:?SYNC_BRANCH is required}"

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
        --json headRefOid,mergeable,mergeStateStatus,statusCheckRollup)

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
        PR_HEAD_OID=$(echo "$VIEW" | jq -r '.headRefOid')
        if [[ ! "$PR_HEAD_OID" =~ ^[0-9a-fA-F]{40}$ ]]; then
            echo "::error::Could not resolve the PR head commit."
            exit 1
        fi
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
echo "Rechecking generated path scope against current public main..."
git -C "$SYNC_SCOPE_PUBLIC_REPO" fetch --quiet origin \
    "refs/heads/$SYNC_BRANCH:refs/remotes/origin/$SYNC_BRANCH"
FETCHED_HEAD=$(git -C "$SYNC_SCOPE_PUBLIC_REPO" rev-parse \
    "refs/remotes/origin/$SYNC_BRANCH")
if [[ "$FETCHED_HEAD" != "$PR_HEAD_OID" ]]; then
    echo "::error::Fetched sync branch head $FETCHED_HEAD does not match PR head $PR_HEAD_OID."
    exit 1
fi

bash "$SYNC_SCOPE_ASSERT_SCRIPT" \
    --repo "$SYNC_SCOPE_PUBLIC_REPO" \
    --base-ref main \
    --head-ref "refs/remotes/origin/$SYNC_BRANCH" \
    --config "$SYNC_SCOPE_CONFIG" \
    --additional-paths "${SYNC_ADDITIONAL_PATHS:-}"

GUARDED_BASE=$(git -C "$SYNC_SCOPE_PUBLIC_REPO" rev-parse \
    refs/remotes/origin/main)
FINAL_VIEW=$(gh pr view "$PR_URL" --repo "$REPO" \
    --json baseRefName,baseRefOid,headRefOid)
FINAL_BASE_REF=$(echo "$FINAL_VIEW" | jq -r '.baseRefName')
FINAL_BASE_OID=$(echo "$FINAL_VIEW" | jq -r '.baseRefOid')
FINAL_HEAD_OID=$(echo "$FINAL_VIEW" | jq -r '.headRefOid')
if [[ "$FINAL_BASE_REF" != "main" ]]; then
    echo "::error::PR base branch changed to '$FINAL_BASE_REF'; refusing to merge anywhere except main."
    exit 1
fi
if [[ "$FINAL_HEAD_OID" != "$PR_HEAD_OID" ]]; then
    echo "::error::PR head moved after the scope assertion; refusing to merge."
    exit 1
fi
if [[ "$FINAL_BASE_OID" != "$GUARDED_BASE" ]]; then
    echo "::error::Public main moved after the scope assertion; refusing to merge."
    exit 1
fi

if ! gh pr merge "$PR_URL" --repo "$REPO" --rebase \
    --match-head-commit "$PR_HEAD_OID" 2> /tmp/merge_err; then
    cat /tmp/merge_err >&2
    exit 1
fi
echo "Merged: $PR_URL"
