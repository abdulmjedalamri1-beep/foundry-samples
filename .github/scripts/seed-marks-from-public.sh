#!/usr/bin/env bash
# .github/scripts/seed-marks-from-public.sh
#
# Synthesize paired fast-export/fast-import marks after verifying that a private
# commit and public commit are equivalent over the sync include-set.

set -euo pipefail

log() {
    echo "[seed-marks-from-public] $*" >&2
}

usage() {
    cat >&2 <<'EOF'
Usage: seed-marks-from-public.sh --private-sha <sha> --public-sha <sha> --marks-dir <dir>

Environment:
  PRIVATE_REPO   Path to private repo checkout (default: private-repo)
  PUBLIC_REPO    Path to public repo checkout (default: public-repo)
  CONFIG_FILE    Sync config JSON (default: $PRIVATE_REPO/.github/sync-config.json)
EOF
}

PRIVATE_SHA=""
PUBLIC_SHA=""
MARKS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --private-sha)
            PRIVATE_SHA="${2:-}"
            shift 2
            ;;
        --public-sha)
            PUBLIC_SHA="${2:-}"
            shift 2
            ;;
        --marks-dir)
            MARKS_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PRIVATE_SHA" || -z "$PUBLIC_SHA" || -z "$MARKS_DIR" ]]; then
    usage
    echo "ERROR: --private-sha, --public-sha, and --marks-dir are required" >&2
    exit 1
fi

PRIVATE_REPO="${PRIVATE_REPO:-private-repo}"
PUBLIC_REPO="${PUBLIC_REPO:-public-repo}"
CONFIG_FILE="${CONFIG_FILE:-$PRIVATE_REPO/.github/sync-config.json}"

for path in "$PRIVATE_REPO/.git" "$PUBLIC_REPO/.git" "$CONFIG_FILE"; do
    if [[ ! -e "$path" ]]; then
        echo "ERROR: Required path not found: $path" >&2
        exit 1
    fi
done

private_sha_input="$PRIVATE_SHA"
if ! PRIVATE_SHA=$(git -C "$PRIVATE_REPO" rev-parse --verify "$private_sha_input^{commit}" 2>/dev/null); then
    echo "ERROR: cannot resolve private SHA: $private_sha_input" >&2
    exit 1
fi
public_sha_input="$PUBLIC_SHA"
if ! PUBLIC_SHA=$(git -C "$PUBLIC_REPO" rev-parse --verify "$public_sha_input^{commit}" 2>/dev/null); then
    echo "ERROR: cannot resolve public SHA: $public_sha_input" >&2
    exit 1
fi

config_get() {
    local key="$1"
    python3 - "$CONFIG_FILE" "$key" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)
keys = sys.argv[2].split(".")
val = cfg
for k in keys:
    val = val[k]
if isinstance(val, list):
    output = "\n".join(str(x) for x in val)
else:
    output = str(val)
sys.stdout.buffer.write((output + "\n").encode())
PY
}

normalize_blocked_path() {
    local path="$1"

    while [[ "$path" == ./* ]]; do
        path="${path#./}"
    done
    while [[ "$path" == */ ]]; do
        path="${path%/}"
    done

    [[ -z "$path" || "$path" == "." ]] && return 1
    printf '%s\n' "$path"
}

build_dynamic_pathspecs() {
    local raw normalized
    local -a blocked_paths
    [[ -z "${SYNC_BLOCKED_PATHS:-}" ]] && return 0

    IFS=':' read -r -a blocked_paths <<< "$SYNC_BLOCKED_PATHS"
    local count=0
    for raw in "${blocked_paths[@]}"; do
        [[ -z "$raw" ]] && continue
        if ! normalized=$(normalize_blocked_path "$raw"); then
            continue
        fi
        printf ':!%s/\n' "$normalized"
        count=$((count + 1))
    done

    if [[ $count -gt 0 ]]; then
        log "WARNING: seed_blocked_paths is bypassing the tree-equivalence check for $count path(s): ${SYNC_BLOCKED_PATHS}"
        log "WARNING: Only use seed_blocked_paths for historically-excluded paths that were never synced."
        log "WARNING: Using it to silence a real content divergence will corrupt the marks cache."
        log "WARNING: If tree-equivalence fails for content you care about, stop and reconcile the trees through reviewed changes."
    fi
}

all_exclusion_pathspecs() {
    config_get "exclude_pathspecs"
    build_dynamic_pathspecs
}

pathspec_hash() {
    # Hash only the *static* exclusion config; dynamic SYNC_BLOCKED_PATHS are
    # per-run state and must not be folded into the durable marks-validity
    # hash. Stays in lockstep with sync-core.sh::pathspec_hash.
    config_get "exclude_pathspecs" | sort | sha256sum | awk '{print $1}'
}

root_commit_sha() {
    git -C "$PRIVATE_REPO" rev-list --max-parents=0 HEAD | head -1
}

spec_to_path() {
    local spec="$1"
    spec="${spec#:!}"
    spec="${spec#:(exclude)}"
    spec="${spec%/}"
    printf '%s\n' "$spec"
}

build_exclude_paths() {
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        local path
        path=$(spec_to_path "$spec")
        additional_overrides_exclusion "$path" && continue
        printf '%s\n' "$path"
    done < <(config_get "exclude_pathspecs")

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        spec_to_path "$spec"
    done < <(build_dynamic_pathspecs)
}

additional_overrides_exclusion() {
    local excluded="$1"
    local allowed bare
    local -a additions=()
    [[ -z "${SYNC_ADDITIONAL_PATHS:-}" ]] && return 1

    IFS=':' read -r -a additions <<< "$SYNC_ADDITIONAL_PATHS"
    for allowed in "${additions[@]}"; do
        bare="${allowed%/}"
        if [[ "$bare" == "$excluded" || "$bare" == "$excluded"/* ]]; then
            return 0
        fi
    done
    return 1
}

# Optional basename excludes (e.g. ".ci-skip" / ".code-ci-skip") — scattered
# internal marker files matched by final path component, not prefix. Mirrors
# sync-core.sh::build_filter_exclude_basenames and verify-sync.sh so the
# seed-marks tree-equivalence check uses the SAME include-set as the sync
# stream. The key is optional; a missing key yields zero lines. Deliberately
# NOT folded into pathspec_hash (kept in lockstep with sync-core.sh).
build_exclude_basenames() {
    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)
for b in cfg.get("exclude_basenames", []):
    b = str(b).strip()
    if b:
        sys.stdout.buffer.write((b + "\n").encode())
PY
}

build_include_paths() {
    config_get "default_include_paths"
    if [[ -n "${SYNC_ADDITIONAL_PATHS:-}" ]]; then
        tr ':' '\n' <<< "$SYNC_ADDITIONAL_PATHS"
    fi
}

is_included_path() {
    local path="$1"
    local allowed bare
    for allowed in "${INCLUDE_PATHS[@]:-}"; do
        [[ -z "$allowed" ]] && continue
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

is_excluded_path() {
    local path="$1"
    local base
    for base in "${EXCLUDE_PATHS[@]:-}"; do
        [[ -z "$base" ]] && continue
        if [[ "$path" == "$base" || "$path" == "$base"/* ]]; then
            return 0
        fi
    done
    local name="${path##*/}"
    local bn
    for bn in "${EXCLUDE_BASENAMES[@]:-}"; do
        [[ -z "$bn" ]] && continue
        if [[ "$name" == "$bn" ]]; then
            return 0
        fi
    done
    return 1
}

write_filtered_tree() {
    local repo="$1"
    local sha="$2"
    local output="$3"
    while IFS=$'\t' read -r meta path; do
        [[ -z "$path" ]] && continue
        is_included_path "$path" || continue
        is_excluded_path "$path" && continue
        printf '%s\t%s\n' "$meta" "$path"
    done < <(git -C "$repo" ls-tree -r --full-tree "$sha") | sort > "$output"
}

main() {
    local -a INCLUDE_PATHS
    mapfile -t INCLUDE_PATHS < <(build_include_paths)
    if [[ ${#INCLUDE_PATHS[@]} -eq 0 ]]; then
        echo "Sync config has no default include paths" >&2
        exit 1
    fi
    local -a EXCLUDE_PATHS
    mapfile -t EXCLUDE_PATHS < <(build_exclude_paths)
    local -a EXCLUDE_BASENAMES
    mapfile -t EXCLUDE_BASENAMES < <(build_exclude_basenames)

    local parent_dir tmp_dir private_tree public_tree
    parent_dir=$(dirname "$MARKS_DIR")
    mkdir -p "$parent_dir"
    tmp_dir="$parent_dir/.seed-marks-from-public.$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    trap "rm -rf '$tmp_dir'" EXIT

    private_tree="$tmp_dir/private.tree"
    public_tree="$tmp_dir/public.tree"

    write_filtered_tree "$PRIVATE_REPO" "$PRIVATE_SHA" "$private_tree"
    write_filtered_tree "$PUBLIC_REPO" "$PUBLIC_SHA" "$public_tree"

    local mismatch=0
    if ! diff -u "$private_tree" "$public_tree" >&2; then
        echo "Tree mismatch between private $PRIVATE_SHA and public $PUBLIC_SHA over sync include-set" >&2
        mismatch=1
    fi
    if [[ $mismatch -ne 0 ]]; then
        echo "Refusing to synthesize marks; marks-dir left unchanged: $MARKS_DIR" >&2
        exit 1
    fi

    # Write marks for PRIVATE_SHA AND every ancestor of it. The single-mark
    # form (":1 <sha>") is insufficient: git fast-export's --import-marks only
    # suppresses emission of explicitly-marked commits — it does NOT prune the
    # rev-list walk. With one mark, fast-export emits the seed's entire ancestor
    # history (~all commits) and produces a giant orphan-style PR. By marking
    # every ancestor, fast-export skips them all and emits only commits newer
    # than PRIVATE_SHA. Ancestors get ":2", ":3", ... in oldest-first order;
    # PRIVATE_SHA is written LAST as ":1" so that:
    #   (a) The seed-pair anchor (":1") is consistent with the public side.
    #   (b) The convention "last line = most-recently-synced commit" holds —
    #       sync-core.sh::last_synced_private_sha uses awk 'END{print $2}' on
    #       PRIVATE_MARKS to recover from chained stale-marks scenarios.
    # See PR #701 / run 25581810668 for the failure mode this avoids, and test
    # T60 for the regression assertion.
    {
        local n=2 commit
        while IFS= read -r commit; do
            [[ "$commit" == "$PRIVATE_SHA" ]] && continue
            printf ':%d %s\n' "$n" "$commit"
            n=$((n + 1))
        done < <(git -C "$PRIVATE_REPO" rev-list --reverse "$PRIVATE_SHA")
        printf ':1 %s\n' "$PRIVATE_SHA"
    } > "$tmp_dir/private.marks"

    # Public side mirrors every private mark, all pointing to PUBLIC_SHA.
    # Earlier designs only wrote ":1 PUBLIC_SHA", on the theory that fast-export
    # would only emit "from :PARENT" references for the seed (mark :1) when
    # producing a linear delta. That theory was wrong: when fast-export is run
    # with pathspec filters (which we always do — see sync-config.json), it
    # performs PARENT REWRITING. A post-seed commit's parent in the emitted
    # stream may be ANY ancestor mark whose filtered tree fast-export decides
    # the commit chains off. We have observed in production fast-export choosing
    # an arbitrary ancestor mark (e.g. ":219") as the parent of a post-seed
    # commit even when the underlying git parent is the seed. fast-import then
    # fails with "fatal: mark :N not declared". Historical recovery then fell
    # back to a discard-and-full-export, producing an orphan-style PR with
    # hundreds of files of bidirectional divergence (PR #702 / run 25584711501).
    # Current recovery fails closed instead. Mirroring every private mark to
    # PUBLIC_SHA makes any such rewritten "from :N" reference resolve to public
    # main, so the resulting commit on the public side is correctly anchored.
    # The trade-off: we lose
    # the "fail loud" property for actual private-side merges into pre-seed
    # ancestors, but the seed-pair tree-equivalence check above already
    # guarantees the public side has the same content under the include-set,
    # which is the only correctness guarantee we can offer in degraded-public
    # state. See test T61 for the regression assertion.
    awk -v sha="$PUBLIC_SHA" '{ print $1 " " sha }' "$tmp_dir/private.marks" \
        > "$tmp_dir/public.marks"
    pathspec_hash > "$tmp_dir/pathspec.hash"
    root_commit_sha > "$tmp_dir/root.sha"
    # Sentinel: after seed, PRIVATE_SHA is the last-known-good reconciliation
    # point with PUBLIC_SHA (validated by the tree-equivalence check above).
    # sync-core.sh reads this in preference to awk-tailing private.marks.
    printf '%s\n' "$PRIVATE_SHA" > "$tmp_dir/last-synced-private.sha"

    mkdir -p "$MARKS_DIR"
    mv "$tmp_dir/private.marks" "$MARKS_DIR/private.marks"
    mv "$tmp_dir/public.marks" "$MARKS_DIR/public.marks"
    mv "$tmp_dir/pathspec.hash" "$MARKS_DIR/pathspec.hash"
    mv "$tmp_dir/root.sha" "$MARKS_DIR/root.sha"
    mv "$tmp_dir/last-synced-private.sha" "$MARKS_DIR/last-synced-private.sha"

    log "Seeded paired marks for private ${PRIVATE_SHA:0:8} ↔ public ${PUBLIC_SHA:0:8}"
}

main "$@"
