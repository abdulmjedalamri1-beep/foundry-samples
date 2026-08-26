#!/usr/bin/env bash
# Validates operator-supplied additional paths and asserts that a generated
# sync branch changes only the configured default scope plus those paths.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  assert-sync-scope.sh --normalize-only <colon-separated-paths>
  assert-sync-scope.sh --repo <path> --base-ref <ref> --head-ref <ref> \
      --config <sync-config.json> [--additional-paths <colon-separated-paths>]
EOF
    exit 2
}

normalize_additional_paths() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && return 0

    if [[ "$raw" == :* || "$raw" == *: || "$raw" == *::* ]]; then
        echo "ERROR: additional_paths contains an empty entry" >&2
        return 1
    fi

    local -a entries=()
    IFS=':' read -r -a entries <<< "$raw"
    local -A seen=()
    local -a normalized=()
    local entry bare component

    for entry in "${entries[@]}"; do
        if [[ ! "$entry" =~ ^[A-Za-z0-9._/-]+$ ]]; then
            echo "ERROR: additional path '$entry' contains unsupported characters" >&2
            return 1
        fi
        if [[ "$entry" == /* || "$entry" == "." || "$entry" == "/" || "$entry" == *"//"* ]]; then
            echo "ERROR: additional path '$entry' must be a canonical repo-relative path" >&2
            return 1
        fi

        bare="${entry%/}"
        IFS='/' read -r -a components <<< "$bare"
        for component in "${components[@]}"; do
            if [[ "$component" == "." || "$component" == ".." || -z "$component" ]]; then
                echo "ERROR: additional path '$entry' contains an unsafe path component" >&2
                return 1
            fi
        done

        case "$bare" in
            README.md|CONTRIBUTING.md|.github|.github/*|public-overlay|public-overlay/*)
                echo "ERROR: '$entry' is public-owned metadata and cannot be synced by this bridge" >&2
                return 1
                ;;
        esac

        if [[ -z "${seen[$entry]:-}" ]]; then
            seen["$entry"]=1
            normalized+=("$entry")
        fi
    done

    local joined=""
    for entry in "${normalized[@]}"; do
        joined="${joined:+$joined:}$entry"
    done
    printf '%s\n' "$joined"
}

path_is_allowed() {
    local path="$1"
    local allowed bare

    for allowed in "${DEFAULT_PATHS[@]}"; do
        if [[ "$allowed" == */ ]]; then
            bare="${allowed%/}"
            if [[ "$path" == "$bare" || "$path" == "$bare"/* ]]; then
                return 0
            fi
        elif [[ "$path" == "$allowed" ]]; then
            return 0
        fi
    done

    for allowed in "${ADDITIONAL_PATHS[@]}"; do
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

if [[ "${1:-}" == "--normalize-only" ]]; then
    [[ $# -eq 2 ]] || usage
    normalize_additional_paths "$2"
    exit $?
fi

REPO=""
BASE_REF=""
HEAD_REF=""
CONFIG_FILE=""
RAW_ADDITIONAL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --base-ref) BASE_REF="${2:-}"; shift 2 ;;
        --head-ref) HEAD_REF="${2:-}"; shift 2 ;;
        --config) CONFIG_FILE="${2:-}"; shift 2 ;;
        --additional-paths) RAW_ADDITIONAL="${2:-}"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -n "$REPO" && -n "$BASE_REF" && -n "$HEAD_REF" && -n "$CONFIG_FILE" ]] || usage
[[ -d "$REPO/.git" && -f "$CONFIG_FILE" ]] || {
    echo "ERROR: sync scope assertion received an invalid repository or config path" >&2
    exit 1
}

NORMALIZED_ADDITIONAL="$(normalize_additional_paths "$RAW_ADDITIONAL")"
declare -a ADDITIONAL_PATHS=()
if [[ -n "$NORMALIZED_ADDITIONAL" ]]; then
    IFS=':' read -r -a ADDITIONAL_PATHS <<< "$NORMALIZED_ADDITIONAL"
fi

mapfile -t DEFAULT_PATHS < <(
    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
for path in config.get("default_include_paths", []):
    path = str(path)
    if path:
        sys.stdout.buffer.write((path + "\n").encode())
PY
)
if [[ ${#DEFAULT_PATHS[@]} -eq 0 ]]; then
    echo "ERROR: sync config has no default_include_paths" >&2
    exit 1
fi

if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO" fetch --quiet origin main
    if git -C "$REPO" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
        BASE_REF="refs/remotes/origin/main"
    fi
fi

git -C "$REPO" rev-parse --verify "$HEAD_REF^{commit}" >/dev/null

if git -C "$REPO" rev-parse --verify "$BASE_REF^{commit}" >/dev/null 2>&1; then
    BASE_TREE="$(git -C "$REPO" rev-parse "$BASE_REF^{tree}")"
elif ! git -C "$REPO" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
    && ! git -C "$REPO" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
    echo "Public main does not exist; checking the first sync branch against an empty tree" >&2
    BASE_TREE="$(git -C "$REPO" hash-object -t tree /dev/null)"
    BASE_REF=""
else
    echo "ERROR: cannot resolve public base ref '$BASE_REF'" >&2
    exit 1
fi

if [[ -n "$BASE_REF" ]] && git -C "$REPO" merge-base "$BASE_REF" "$HEAD_REF" >/dev/null 2>&1; then
    MERGE_OUTPUT="$(git -C "$REPO" merge-tree --write-tree "$BASE_REF" "$HEAD_REF")"
    RESULT_TREE="$(printf '%s\n' "$MERGE_OUTPUT" | head -n 1)"
else
    [[ -z "$BASE_REF" ]] || echo "WARNING: sync branch has no common ancestor; checking its tree as the prospective result" >&2
    RESULT_TREE="$(git -C "$REPO" rev-parse "$HEAD_REF^{tree}")"
fi
git -C "$REPO" rev-parse --verify "$RESULT_TREE^{tree}" >/dev/null

declare -a COMMITS=() COMMIT_PATHS=()
if [[ -n "$BASE_REF" ]]; then
    mapfile -t COMMITS < <(git -C "$REPO" rev-list --reverse "$HEAD_REF" --not "$BASE_REF")
else
    mapfile -t COMMITS < <(git -C "$REPO" rev-list --reverse "$HEAD_REF")
fi

HISTORY_FAILED=0
for commit in "${COMMITS[@]}"; do
    COMMIT_PATHS=()
    mapfile -d '' -t COMMIT_PATHS < <(
        git -C "$REPO" diff-tree --root -m --no-commit-id \
            --name-only -r --no-renames -z "$commit"
    )
    for path in "${COMMIT_PATHS[@]}"; do
        if ! path_is_allowed "$path"; then
            echo "::error file=$path::Commit $commit changes a path outside the allowed sync scope" >&2
            echo "ERROR: commit $commit changes unexpected path: $path" >&2
            HISTORY_FAILED=1
        fi
    done
done

declare -a UNEXPECTED=()
while IFS= read -r -d '' path; do
    if ! path_is_allowed "$path"; then
        UNEXPECTED+=("$path")
    fi
done < <(git -C "$REPO" diff --no-renames --name-only -z "$BASE_TREE" "$RESULT_TREE")

if [[ $HISTORY_FAILED -ne 0 || ${#UNEXPECTED[@]} -gt 0 ]]; then
    if [[ ${#UNEXPECTED[@]} -eq 0 ]]; then
        echo "ERROR: generated sync history contains paths outside the allowed scope" >&2
        exit 1
    fi
    echo "ERROR: generated sync result contains paths outside the allowed scope:" >&2
    for path in "${UNEXPECTED[@]}"; do
        echo "::error file=$path::Unexpected path in generated sync result" >&2
        echo "  $path" >&2
    done
    exit 1
fi

echo "Sync scope assertion passed (${DEFAULT_PATHS[*]}${NORMALIZED_ADDITIONAL:+; additional: $NORMALIZED_ADDITIONAL})" >&2
