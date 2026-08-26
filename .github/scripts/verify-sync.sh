#!/usr/bin/env bash
#
# verify-sync.sh — Post-sync drift verification.
#
# Compares the configured positive sync scope in the private repo's HEAD
# (after exclusions) against the same scope in the public repo's HEAD.
# Drift = any file present in one set but not the other, or with differing
# blob content. Authorship/history is intentionally NOT checked here — that
# is verified separately by the sync workflow's mailmap and filter-stream.
#
# Usage:
#   verify-sync.sh <private-repo-dir> <public-repo-dir> <sync-config-json>
#
# Environment:
#   SYNC_BLOCKED_PATHS  Optional. Colon-separated repo-relative paths that
#                       are currently held back from sync by the validation
#                       gate (Phase D4). Treated as additional excludes for
#                       drift comparison: blocked paths are not expected to
#                       be in public, and existing public copies of blocked
#                       paths do not raise *deleting drift. Matches the
#                       static-exclude bidirectional behavior (T36) and
#                       prevents a window of red CI when verify-sync runs
#                       between a sync that excluded a blocked sample and
#                       the validation pipeline turning that sample green.
#   SYNC_ADDITIONAL_PATHS Optional colon-separated exact files or trailing-slash
#                         directories included for this verification.
#
# Outputs (to fd 3, which the caller redirects to $GITHUB_OUTPUT):
#   drift=true|false
#   drift_count=<N>
#
# When drift is detected, /tmp/drift-files.txt is written with one
# "<status>\t<path>" line per drifted file:
#   >f          File expected (in private after exclusions) but missing or
#               stale (different content) in public.
#   *deleting   File present in public but should have been excluded/removed.
#
# All log output goes to stderr so the Actions log stays readable.
# Only key=value lines are written to fd 3.
#
set -euo pipefail
exec 3>&1 1>&2

PRIVATE_DIR="${1:?missing private repo dir}"
PUBLIC_DIR="${2:?missing public repo dir}"
CONFIG_FILE="${3:?missing sync-config.json path}"

# ── Load excludes ────────────────────────────────────────────────────────────
mapfile -t EXCLUDE_SPECS < <(jq -r '.exclude_pathspecs[]' "$CONFIG_FILE" | tr -d '\r')
mapfile -t INCLUDE_PATHS < <(jq -r '.default_include_paths[]' "$CONFIG_FILE" | tr -d '\r')
if [[ -n "${SYNC_ADDITIONAL_PATHS:-}" ]]; then
    IFS=':' read -r -a _additional <<< "$SYNC_ADDITIONAL_PATHS"
    INCLUDE_PATHS+=("${_additional[@]}")
fi

# Optional basename excludes (e.g. ".ci-skip" / ".code-ci-skip") — scattered
# internal marker files matched by final path component, not prefix. The key is
# optional; `[]?` tolerates its absence. Mirrors filter-stream.py's
# --exclude-basename and is applied bidirectionally below so neither private nor
# public marker files register as drift.
mapfile -t EXCLUDE_BASENAMES < <(jq -r '.exclude_basenames[]? // empty' "$CONFIG_FILE" | tr -d '\r')

# Convert pathspec (":!path/" or ":(exclude)path") to bare path "path"
spec_to_path() {
    local s="$1"
    s="${s#:!}"
    s="${s#:(exclude)}"
    s="${s%/}"
    printf '%s' "$s"
}

# Normalize a SYNC_BLOCKED_PATHS entry the same way sync-core.sh does:
# strip leading "./", strip trailing "/", reject empty/".".
# Whitespace handling matches sync-core: no trim. T50 pins this parity.
normalize_blocked() {
    local p="$1"
    while [[ "$p" == ./* ]]; do
        p="${p#./}"
    done
    while [[ "$p" == */ ]]; do
        p="${p%/}"
    done
    [[ -z "$p" || "$p" == "." ]] && return 1
    printf '%s' "$p"
}

additional_overrides_exclusion() {
    local excluded="$1"
    local allowed bare
    for allowed in "${_additional[@]:-}"; do
        bare="${allowed%/}"
        if [[ "$bare" == "$excluded" || "$bare" == "$excluded"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Pre-compute bare exclude paths for fast membership checks
declare -a EXCLUDE_PATHS=()
for spec in "${EXCLUDE_SPECS[@]:-}"; do
    [[ -z "$spec" ]] && continue
    bare_spec="$(spec_to_path "$spec")"
    additional_overrides_exclusion "$bare_spec" && continue
    EXCLUDE_PATHS+=("$bare_spec")
done

# Layer dynamic block-list on top of static excludes.
# Block-list paths are treated as additional excludes (bidirectional): they
# are skipped on both EXPECTED and ACTUAL sides, matching the static-exclude
# semantics validated by T36.
declare -a BLOCKED_PATHS=()
if [[ -n "${SYNC_BLOCKED_PATHS:-}" ]]; then
    IFS=':' read -r -a _raw_blocked <<< "$SYNC_BLOCKED_PATHS"
    for raw in "${_raw_blocked[@]}"; do
        [[ -z "$raw" ]] && continue
        if normalized="$(normalize_blocked "$raw")"; then
            BLOCKED_PATHS+=("$normalized")
            EXCLUDE_PATHS+=("$normalized")
        fi
    done
fi

# Test whether a repo-relative path is matched by any exclude (exact match
# for files, prefix-match for directories, or a matching basename).
is_excluded() {
    local path="$1"
    for base in "${EXCLUDE_PATHS[@]:-}"; do
        [[ -z "$base" ]] && continue
        if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
            return 0
        fi
    done
    local name="${path##*/}"
    for bn in "${EXCLUDE_BASENAMES[@]:-}"; do
        [[ -z "$bn" ]] && continue
        if [[ "$name" == "$bn" ]]; then
            return 0
        fi
    done
    return 1
}

is_included() {
    local path="$1"
    local allowed bare
    for allowed in "${INCLUDE_PATHS[@]}"; do
        if [[ "$allowed" == */ ]]; then
            bare="${allowed%/}"
            if [[ "$path" == "$bare" || "$path" == "$bare"/* ]]; then
                return 0
            fi
        elif [[ "$path" == "$allowed" ]]; then
            return 0
        fi
    done
    return 1
}

echo "Private dir:   $PRIVATE_DIR"
echo "Public dir:    $PUBLIC_DIR"
echo "Excludes:      ${EXCLUDE_PATHS[*]:-<none>}"
echo "Includes:      ${INCLUDE_PATHS[*]:-<none>}"
echo "Basenames:     ${EXCLUDE_BASENAMES[*]:-<none>}"
echo "Block-list:    ${BLOCKED_PATHS[*]:-<none>}"

# ── Build expected and actual maps (path → blob sha) ─────────────────────────
declare -A EXPECTED=() ACTUAL=()

while IFS=$'\t' read -r meta path; do
    [[ -z "$path" ]] && continue
    is_included "$path" || continue
    is_excluded "$path" && continue
    sha="${meta##* }"
    EXPECTED["$path"]="$sha"
done < <(git -C "$PRIVATE_DIR" ls-tree -r HEAD)

while IFS=$'\t' read -r meta path; do
    [[ -z "$path" ]] && continue
    is_included "$path" || continue
    # Exclusions are bidirectional: paths that sync doesn't manage should not be
    # checked for drift in either direction. Public may legitimately contain
    # files in excluded paths (e.g., a public-only .github/CODEOWNERS).
    is_excluded "$path" && continue
    sha="${meta##* }"
    ACTUAL["$path"]="$sha"
done < <(git -C "$PUBLIC_DIR" ls-tree -r HEAD)

echo "Expected files: ${#EXPECTED[@]}"
echo "Actual files:   ${#ACTUAL[@]}"

# ── Diff ─────────────────────────────────────────────────────────────────────
DRIFT_FILE=/tmp/drift-files.txt
: > "$DRIFT_FILE"
DRIFT_COUNT=0

for path in "${!EXPECTED[@]}"; do
    if [[ -z "${ACTUAL[$path]:-}" ]]; then
        printf '>f\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    elif [[ "${EXPECTED[$path]}" != "${ACTUAL[$path]}" ]]; then
        printf '>f\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done

for path in "${!ACTUAL[@]}"; do
    if [[ -z "${EXPECTED[$path]:-}" ]]; then
        printf '*deleting\t%s\n' "$path" >> "$DRIFT_FILE"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
done

# Stable, deterministic ordering
sort -k2 "$DRIFT_FILE" -o "$DRIFT_FILE"

if [[ $DRIFT_COUNT -gt 0 ]]; then
    echo ""
    echo "❌ Drift detected ($DRIFT_COUNT file(s)):"
    sed 's/^/  /' "$DRIFT_FILE"
    echo "drift=true" >&3
    echo "drift_count=$DRIFT_COUNT" >&3
else
    echo "✅ No drift detected."
    echo "drift=false" >&3
    echo "drift_count=0" >&3
fi
