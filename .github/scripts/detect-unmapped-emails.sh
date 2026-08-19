#!/usr/bin/env bash
# detect-unmapped-emails.sh — Detect internal emails not in sync-mailmap.
#
# Scans git log author/committer emails in a given commit range, cross-references
# against the sync-mailmap, and reports unmapped @microsoft.com emails.
#
# Usage:
#   detect-unmapped-emails.sh [OPTIONS]
#
# Options:
#   --mailmap PATH       Path to sync-mailmap file (default: .github/sync-mailmap)
#   --range RANGE        Git revision range to scan (default: all commits)
#   --repo PATH          Path to git repository to scan (default: current directory)
#   --json               Output JSON instead of human-readable text
#   --resolve            Attempt GitHub username resolution for unmapped emails
#   --quiet              Suppress informational output (only errors/JSON)
#
# Exit codes:
#   0  All internal emails are mapped
#   1  Unmapped internal emails found
#   2  Script error (missing mailmap, bad args, etc.)
#
# This script is the shared detection logic used by:
#   - .azure-pipelines/validation.yml (PR gate)
#   - .github/workflows/sync-to-public.yml (pre-sync check)
#   - .github/workflows/fix-unmapped-emails.yml (manual remediation)

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

MAILMAP_FILE=".github/sync-mailmap"
RANGE=""
JSON_OUTPUT=0
RESOLVE=0
QUIET=0
REPO_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Argument parsing ─────────────────────────────────────────────────────────

_require_arg() {
    if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
        echo "ERROR: $1 requires a value" >&2; exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mailmap)   _require_arg "$1" "${2:-}"; MAILMAP_FILE="$2"; shift 2 ;;
        --range)     _require_arg "$1" "${2:-}"; RANGE="$2"; shift 2 ;;
        --repo)      _require_arg "$1" "${2:-}"; REPO_DIR="$2"; shift 2 ;;
        --json)      JSON_OUTPUT=1; shift ;;
        --resolve)   RESOLVE=1; shift ;;
        --quiet)     QUIET=1; shift ;;
        -h|--help)   head -30 "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        *)           echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ ! -f "$MAILMAP_FILE" ]]; then
    echo "ERROR: Mailmap file not found: $MAILMAP_FILE" >&2
    exit 2
fi

# Build git command prefix (supports running against a repo in a different directory)
GIT_CMD=(git)
if [[ -n "$REPO_DIR" ]]; then
    GIT_CMD=(git -C "$REPO_DIR")
fi

# Verify we're in a git repo
if ! "${GIT_CMD[@]}" rev-parse --git-dir &>/dev/null; then
    echo "ERROR: Not a git repository (cwd=$(pwd), repo=$REPO_DIR)" >&2
    exit 2
fi

# ─── Load mailmap (extract internal emails into a lookup set) ─────────────────

declare -A mapped_emails=()
# Regex stored in variable to avoid bash parsing issues with special chars in [[ =~ ]]
_mailmap_re='<[^>]+>[[:space:]]+<([^>]+)>[[:space:]]*$'
# `|| [[ -n "$line" ]]` ensures a final line without a trailing newline is still
# processed. Without it, a mailmap whose last entry lacks a terminating \n would
# silently drop that entry from the lookup set — causing false-positive
# "unmapped" reports for the last mapping. See PR fixing this regression.
while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip comments
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    # Match: Name <safe-email> <internal-email>
    if [[ "$line" =~ $_mailmap_re ]]; then
        mapped_emails["${BASH_REMATCH[1],,}"]=1
    fi
done < "$MAILMAP_FILE"

if [[ ${#mapped_emails[@]} -eq 0 ]]; then
    echo "ERROR: No entries loaded from mailmap (parsing error?)" >&2
    exit 2
fi

[[ $QUIET -eq 0 ]] && echo "Loaded ${#mapped_emails[@]} mailmap entries." >&2

# ─── Scan git log for author/committer emails ────────────────────────────────

GIT_LOG_ARGS=(--format='%ae%n%ce' --all)
if [[ -n "$RANGE" ]]; then
    GIT_LOG_ARGS=(--format='%ae%n%ce' "$RANGE")
fi

mapfile -t all_emails < <("${GIT_CMD[@]}" log "${GIT_LOG_ARGS[@]}" | sort -uf)

# ─── Cross-reference against mailmap ─────────────────────────────────────────

INTERNAL_DOMAINS="microsoft.com"
declare -a unmapped=()

for email in "${all_emails[@]}"; do
    [[ -z "$email" ]] && continue
    email_lower="${email,,}"
    
    # Check if it's an internal domain
    domain="${email_lower##*@}"
    is_internal=0
    if [[ "$domain" == "microsoft.com" ]]; then
        is_internal=1
    fi
    
    [[ $is_internal -eq 0 ]] && continue

    # Skip empty-alias internal emails (e.g. "@microsoft.com" with no local
    # part). These appear when an upstream commit has a malformed author
    # email; emitting a placeholder mailmap entry for them would just
    # pollute the auto-fix PR (see ADO 5356763, PR #479's empty-alias row).
    alias_check="${email_lower%%@*}"
    if [[ -z "$alias_check" ]]; then
        echo "WARN: skipping empty-alias internal email '$email' (no local part before @microsoft.com)" >&2
        continue
    fi
    
    # Check if mapped
    if [[ -z "${mapped_emails[$email_lower]:-}" ]]; then
        unmapped+=("$email_lower")
    fi
done

# ─── Report results ──────────────────────────────────────────────────────────

if [[ ${#unmapped[@]} -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && echo "✅ All internal emails are mapped." >&2
    if [[ $JSON_OUTPUT -eq 1 ]]; then
        echo '{"unmapped":[],"resolved":[]}'
    fi
    exit 0
fi

# ─── Attempt resolution if requested ─────────────────────────────────────────

declare -A resolutions=()

if [[ $RESOLVE -eq 1 ]] && command -v gh &>/dev/null; then
    for email in "${unmapped[@]}"; do
        alias="${email%%@*}"
        result=$("$SCRIPT_DIR/resolve-mailmap-entry.sh" "$alias" 2>/dev/null || true)
        if [[ -n "$result" ]]; then
            resolutions["$email"]="$result"
        fi
    done
fi

# ─── Output ──────────────────────────────────────────────────────────────────

if [[ $JSON_OUTPUT -eq 1 ]]; then
    # Use python for proper JSON escaping (handles quotes, backslashes, unicode)
    _json_items=""
    for email in "${unmapped[@]}"; do
        alias="${email%%@*}"
        resolution="${resolutions[$email]:-}"
        _json_items+="${email}"$'\t'"${alias}"$'\t'"${resolution}"$'\n'
    done
    echo "$_json_items" | python3 -c "
import json, sys
items = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    parts = line.split('\t', 2)
    items.append({
        'email': parts[0],
        'alias': parts[1] if len(parts) > 1 else '',
        'suggested_entry': parts[2] if len(parts) > 2 else ''
    })
print(json.dumps({'unmapped': items}, indent=2))
"
else
    echo "" >&2
    echo "❌ Found ${#unmapped[@]} unmapped internal email(s):" >&2
    echo "" >&2
    for email in "${unmapped[@]}"; do
        alias="${email%%@*}"
        echo "  • $email" >&2
        if [[ -n "${resolutions[$email]:-}" ]]; then
            echo "    Suggested mailmap entry: ${resolutions[$email]}" >&2
        else
            echo "    Lookup: https://repos.opensource.microsoft.com/people?q=$alias" >&2
        fi
    done
    echo "" >&2
    echo "══════════════════════════════════════════════════════════════════════" >&2
    echo "HOW TO FIX:" >&2
    echo "" >&2
    echo "  1. Find your GitHub noreply email at: https://github.com/settings/emails" >&2
    echo "     (Under 'Keep my email addresses private' — format: 12345678+user@users.noreply.github.com)" >&2
    echo "" >&2
    echo "  2. Add a line to .github/sync-mailmap:" >&2
    echo "     Your Name <12345678+username@users.noreply.github.com> <alias@microsoft.com>" >&2
    echo "" >&2
    echo "  3. Commit that change in your PR." >&2
    echo "" >&2
    echo "See CONTRIBUTING.md → 'Sync mailmap' for full details." >&2
    echo "══════════════════════════════════════════════════════════════════════" >&2
fi

exit 1
