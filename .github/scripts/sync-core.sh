#!/usr/bin/env bash
# .github/scripts/sync-core.sh
#
# Orchestrator for foundry-samples-pr → foundry-samples sync.
# Performs: marks management → fast-export → filter → fast-import → scope guard.
#
# Required environment variables:
#   PRIVATE_REPO   — path to checked-out private repo (must have full history)
#   PUBLIC_REPO    — path to checked-out public repo (must have full history)
#   SYNC_BRANCH    — name of sync branch on public repo (e.g., sync/private-to-public-YYYYMMDD)
#   MARKS_DIR      — directory to read/write marks files (persists across runs via cache)
#   CONFIG_FILE    — path to .github/sync-config.json
#   MAILMAP_FILE   — path to .github/sync-mailmap
#
# Optional environment variables:
#   DRY_RUN=1            — perform full pipeline but don't push or create PR
#   SYNC_BLOCKED_PATHS   — colon-separated repo-relative paths to exclude for this run
#   SYNC_ADDITIONAL_PATHS — colon-separated exact files or trailing-slash directories
#
# Exit codes:
#   0 — success (sync completed, ref updated)
#   1 — error (pipeline failed)
#   2 — no changes (nothing to sync, clean exit)
#
# ── Gotchas ───────────────────────────────────────────────────────────────────
#
# fast-export --refspec=<src>:<dst> rewrites the LITERAL ref name emitted in
# the stream. When given a positional ref arg (e.g. HEAD, a branch name, or a
# SHA), fast-export resolves it to the underlying branch and emits
# `commit refs/heads/<branch>` directives — NOT the literal string you passed.
# So `--refspec=HEAD:refs/heads/main` silently fails to match in CI, where
# HEAD is a detached checkout of a feature branch.
#
# When that happens, the failure mode is silent and confusing:
#   - Stream's commit directives target the original branch name.
#   - Filter's --source-ref/--target-ref also fails to match → no rewrite.
#   - fast-import creates the original branch name in the public repo's
#     local clone (e.g. refs/heads/<feature-branch>), never pushed.
#   - refs/heads/$SYNC_BRANCH is never created by fast-import.
#   - refs/heads/$SYNC_BRANCH is missing, so the pipeline fails before push.
#
# Mitigation: run_fast_export pins SOURCE_REF to a fixed temp ref
# (refs/heads/sync-export-source) in the private repo before exporting, so
# the stream deterministically emits `commit refs/heads/main`, and our
# refspec + filter rewrites are predictable.
#
# Stale marks can also break fast-import when PUBLIC_MARKS references an
# object that no longer exists in the public repo. Recovery re-pairs the marks
# against a verified public/private SHA pair; it never publishes an orphan tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_SCRIPT="$SCRIPT_DIR/filter-stream.py"
SEED_MARKS_SCRIPT="$SCRIPT_DIR/seed-marks-from-public.sh"
SCOPE_ASSERT_SCRIPT="$SCRIPT_DIR/assert-sync-scope.sh"

# Source ref to export from. Default works for local tests where main is a
# local branch; CI sets this to HEAD (detached) or origin/main.
SOURCE_REF="${SOURCE_REF:-refs/heads/main}"

# ── Required env validation ───────────────────────────────────────────────────

require_env() {
    local missing=()
    for var in PRIVATE_REPO PUBLIC_REPO SYNC_BRANCH MARKS_DIR CONFIG_FILE MAILMAP_FILE; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required env vars: ${missing[*]}" >&2
        exit 1
    fi

    for path in "$PRIVATE_REPO" "$PUBLIC_REPO" "$CONFIG_FILE" "$MAILMAP_FILE" "$FILTER_SCRIPT" "$SCOPE_ASSERT_SCRIPT"; do
        if [[ ! -e "$path" ]]; then
            echo "ERROR: Required path not found: $path" >&2
            exit 1
        fi
    done

    if [[ ! -d "$PRIVATE_REPO/.git" ]] || [[ ! -d "$PUBLIC_REPO/.git" ]]; then
        echo "ERROR: PRIVATE_REPO and PUBLIC_REPO must be git repos" >&2
        exit 1
    fi
}

# ── Helpers ───────────────────────────────────────────────────────────────────

log() {
    echo "[sync-core] $*" >&2
}

# Emit a key=value pair to GITHUB_OUTPUT if defined; otherwise to stderr.
emit_output() {
    local key="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "${key}=${value}" >> "$GITHUB_OUTPUT"
    else
        log "OUTPUT ${key}=${value}"
    fi
}

# Fail closed with a structured SYNC_ERROR code (ADO 5418305 error contract).
# Emits sync_error=<CODE> plus has_changes=false, then exits non-zero. The code
# is consumed by the alerting/drift-preflight tasks (5418306 / 5418446); this
# helper only emits it — no alerting logic here.
fail_closed() {
    local code="$1"
    emit_output "sync_error" "$code"
    emit_output "has_changes" "false"
    exit 1
}

public_main_exists() {
    git -C "$PUBLIC_REPO" rev-parse --verify refs/heads/main >/dev/null 2>&1 \
        || git -C "$PUBLIC_REPO" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1
}

require_seed_recovery() {
    local reason="$1"
    log "ERROR: $reason"
    log "Public main already exists, so an unanchored full export is disabled."
    log "Run workflow_dispatch with seed_from_public_sha and, when needed, seed_from_private_sha."
    log "Use dry_run=true first; investigate any tree-equivalence failure instead of bypassing it."
    fail_closed "SEED_RECOVERY_REQUIRED"
}

# Read JSON value from config using python (jq may not be available everywhere)
config_get() {
    local key="$1"
    python3 - "$CONFIG_FILE" "$key" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)
keys = sys.argv[2].split('.')
val = cfg
for k in keys:
    val = val[k]
if isinstance(val, list):
    output = '\n'.join(str(x) for x in val)
else:
    output = str(val)
sys.stdout.buffer.write((output + '\n').encode())
PY
}

# Normalize a repo-relative path supplied by the validation gate.
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

# Emit normalized dynamic exclusion pathspecs from SYNC_BLOCKED_PATHS.
build_dynamic_pathspecs() {
    local raw normalized
    local -a blocked_paths
    [[ -z "${SYNC_BLOCKED_PATHS:-}" ]] && return 0

    IFS=':' read -r -a blocked_paths <<< "$SYNC_BLOCKED_PATHS"
    for raw in "${blocked_paths[@]}"; do
        [[ -z "$raw" ]] && continue
        if ! normalized=$(normalize_blocked_path "$raw"); then
            continue
        fi
        # Validation emits sample roots. Keep the exclusion even when the path
        # was deleted privately so reconciliation cannot delete a published
        # blocked copy.
        printf ':!%s/\n' "$normalized"
    done
}

# Emit all exclusion pathspecs that affect the exported history.
all_exclusion_pathspecs() {
    config_get "exclude_pathspecs"
    build_dynamic_pathspecs
}

# Compute a hash of the *static* exclusion config to detect changes that
# durably affect history. Dynamic exclusions (SYNC_BLOCKED_PATHS) are
# intentionally excluded: they are per-run validation state and should not
# invalidate marks across runs. Folding them in caused cache thrash whenever
# a sample's validation status flipped, forcing a noisy full re-export.
pathspec_hash() {
    config_get "exclude_pathspecs" | sort | sha256sum | awk '{print $1}'
}

# Get the SHA of the root commit (first commit in private repo's history).
# Used as cache invalidation key — if root changes, all marks are stale.
root_commit_sha() {
    git -C "$PRIVATE_REPO" rev-list --max-parents=0 HEAD | head -1
}

# Emit normalized exclude paths (one per line) for filter-stream.py.
# Static exclusions come from sync-config.json's `exclude_pathspecs` (where the
# values look like `:!internal/` — the `:!` magic and trailing `/` are stripped).
# Dynamic per-run exclusions come from build_dynamic_pathspecs (SYNC_BLOCKED_PATHS).
build_filter_exclude_paths() {
    local spec path
    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        path="${spec#:!}"
        path="${path#:(exclude)}"
        path="${path%/}"
        [[ -z "$path" ]] && continue
        additional_overrides_exclusion "$path" && continue
        printf '%s\n' "$path"
    done < <(config_get "exclude_pathspecs")

    while IFS= read -r spec; do
        [[ -z "$spec" ]] && continue
        path="${spec#:!}"
        path="${path#:(exclude)}"
        path="${path%/}"
        [[ -z "$path" ]] && continue
        printf '%s\n' "$path"
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

# Emit excluded basenames (one per line) for filter-stream.py's
# `--exclude-basename`. These come from sync-config.json's optional
# `exclude_basenames` key and match scattered internal marker files (e.g.
# `.ci-skip` / `.code-ci-skip`) that have no common path prefix. The key is
# optional; a missing key yields zero lines.
#
# NOTE: basenames are deliberately NOT folded into `pathspec_hash` (see that
# function). Adding/removing a basename takes effect on the next incremental
# sync (the filter drops matching deltas) without invalidating durable marks,
# matching how the dynamic block-list is handled and avoiding a disruptive
# orphan full re-export. Already-synced marker files are therefore left in
# place on public until removed out-of-band.
build_filter_exclude_basenames() {
    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)
for b in cfg.get('exclude_basenames', []):
    b = str(b).strip()
    if b:
        sys.stdout.buffer.write((b + '\n').encode())
PY
}

build_default_include_args() {
    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    cfg = json.load(f)
for p in cfg.get('default_include_paths', []):
    p = str(p)
    if p:
        kind = "prefix" if p.endswith("/") else "file"
        sys.stdout.buffer.write((kind + "\t" + p.rstrip("/") + "\n").encode())
PY
}

build_additional_include_args() {
    local raw
    local -a paths=()
    [[ -z "${SYNC_ADDITIONAL_PATHS:-}" ]] && return 0

    IFS=':' read -r -a paths <<< "$SYNC_ADDITIONAL_PATHS"
    for raw in "${paths[@]}"; do
        if [[ "$raw" == */ ]]; then
            printf '%s\t%s\n' "prefix" "${raw%/}"
        else
            printf '%s\t%s\n' "file" "$raw"
        fi
    done
}

# ── State management ──────────────────────────────────────────────────────────

# Marks file paths
PRIVATE_MARKS=""
PUBLIC_MARKS=""
HASH_FILE=""
ROOT_FILE=""
LAST_SYNCED_FILE=""

setup_marks_state() {
    PRIVATE_MARKS="$MARKS_DIR/private.marks"
    PUBLIC_MARKS="$MARKS_DIR/public.marks"
    HASH_FILE="$MARKS_DIR/pathspec.hash"
    ROOT_FILE="$MARKS_DIR/root.sha"
    # Authoritative record of "last private SHA successfully reconciled with
    # public main". Decoupled from the marks file so stale-marks recovery has
    # a trustworthy anchor regardless of fast-export's export-marks output
    # order or whether any new commits were emitted on a given run.
    # See PR for the 2026-05-11 production failure where awk-tail of private.marks
    # returned a stale ancestor and seed-recovery refused to synthesize.
    LAST_SYNCED_FILE="$MARKS_DIR/last-synced-private.sha"
    mkdir -p "$MARKS_DIR"
}

# Atomically write the sentinel. Called at every successful exit from main()
# (post-import, post-no-op clean-exit, post-dry-run). The value is the private
# SHA resolved from SOURCE_REF at the start of the run — i.e., what we just
# proved is reconciled with public main over the include-set.
write_last_synced_sentinel() {
    local sha="$1"
    [[ -z "$sha" ]] && return 0
    [[ -z "$LAST_SYNCED_FILE" ]] && return 0
    local tmp="${LAST_SYNCED_FILE}.tmp.$$"
    printf '%s\n' "$sha" > "$tmp"
    mv -f "$tmp" "$LAST_SYNCED_FILE"
}

# Recover the last-synced private SHA. Prefers the sentinel file; falls back to
# the marks-file tail for forward compatibility with pre-sentinel caches (the
# first scheduled run after this fix deploys will hit the awk fallback).
read_last_synced_sentinel() {
    if [[ -s "$LAST_SYNCED_FILE" ]]; then
        # Strip whitespace; reject empty lines.
        local sha
        sha=$(head -n 1 "$LAST_SYNCED_FILE" | tr -d '[:space:]')
        if [[ -n "$sha" ]]; then
            printf '%s\n' "$sha"
            return 0
        fi
    fi
    if [[ -s "$PRIVATE_MARKS" ]]; then
        awk 'END { if (NF >= 2) print $2 }' "$PRIVATE_MARKS"
    fi
}

# State check:
#   - No public main → first-ever bootstrap may perform a full export.
#   - Public main exists → complete, matching marks are required.
#   - Missing, inconsistent, or invalid state fails closed and requires a
#     tree-equivalent seed; established repositories never rebuild an orphan.
# Note: only static `exclude_pathspecs` participate in the hash. The per-run
# validation block-list (SYNC_BLOCKED_PATHS) does not invalidate marks; its
# effect is applied at filter-stream time via build_filter_exclude_paths.
check_marks_validity() {
    local current_hash current_root stored_hash stored_root
    current_hash=$(pathspec_hash)
    current_root=$(root_commit_sha)

    local has_marks=0
    if [[ -f "$PRIVATE_MARKS" && -f "$PUBLIC_MARKS" ]]; then
        has_marks=1
    fi

    local has_state=0
    if [[ -f "$HASH_FILE" && -f "$ROOT_FILE" ]]; then
        has_state=1
        stored_hash=$(cat "$HASH_FILE")
        stored_root=$(cat "$ROOT_FILE")
    fi

    if [[ $has_marks -eq 0 && $has_state -eq 0 ]]; then
        if public_main_exists; then
            require_seed_recovery "Marks cache is missing."
        fi
        log "First-ever bootstrap detected — public main is absent; full export allowed"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        rm -f "$LAST_SYNCED_FILE"
        return 0
    fi

    if [[ $has_marks -eq 0 || $has_state -eq 0 ]]; then
        if public_main_exists; then
            require_seed_recovery "Marks cache is incomplete."
        fi
        log "WARNING: Incomplete bootstrap state with no public main — rebuilding state."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS" "$LAST_SYNCED_FILE"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        return 0
    fi

    if [[ "$stored_root" != "$current_root" ]]; then
        if public_main_exists; then
            require_seed_recovery "Private root commit changed ($stored_root → $current_root)."
        fi
        log "WARNING: Private root changed before first public bootstrap — rebuilding state."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS" "$LAST_SYNCED_FILE"
        echo "$current_hash" > "$HASH_FILE"
        echo "$current_root" > "$ROOT_FILE"
        return 0
    fi

    if [[ "$stored_hash" != "$current_hash" ]]; then
        if public_main_exists; then
            require_seed_recovery "Static path exclusions changed."
        fi
        log "WARNING: Path exclusions changed before first public bootstrap — rebuilding state."
        rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS" "$LAST_SYNCED_FILE"
        echo "$current_hash" > "$HASH_FILE"
        return 0
    fi

    log "Marks valid — incremental sync"
    return 0
}

# ── Pipeline steps ────────────────────────────────────────────────────────────

run_fast_export() {
    local stream_file="$1"

    local -a import_marks_arg=()
    if [[ -f "$PRIVATE_MARKS" ]]; then
        import_marks_arg=("--import-marks=$PRIVATE_MARKS")
    fi

    # fast-export's --refspec rewrites the literal ref name emitted in the stream.
    # When given an arbitrary ref (e.g. "HEAD" or "refs/heads/feature"), fast-export
    # resolves it to the underlying branch name and emits `commit refs/heads/<branch>`.
    # That makes our refspec target ("refs/heads/main") unpredictable. We pin the
    # source by writing a temporary local ref (refs/heads/sync-export-source) so the
    # stream always emits `commit refs/heads/main` after the refspec rewrite.
    local export_ref="refs/heads/sync-export-source"
    local source_sha
    if ! source_sha=$(git -C "$PRIVATE_REPO" rev-parse --verify "$SOURCE_REF^{commit}" 2>/dev/null); then
        log "ERROR: cannot resolve SOURCE_REF=$SOURCE_REF in $PRIVATE_REPO"
        return 1
    fi
    git -C "$PRIVATE_REPO" update-ref "$export_ref" "$source_sha"
    # Make sure the temp ref is cleaned up no matter how this function exits.
    # shellcheck disable=SC2064
    trap "git -C '$PRIVATE_REPO' update-ref -d '$export_ref' 2>/dev/null || true" RETURN

    # NOTE (ADO 5347427): we deliberately do NOT pass pathspec args here.
    # `git fast-export` with any positional pathspec implicitly turns on
    # `--full-tree`, which emits every commit as `from :PARENT / deleteall /
    # M ...` against the post-filter include-set. When `--import-marks`
    # anchors `:PARENT` at a real public commit (e.g. after seed-marks
    # recovery anchors all marks at PUBLIC_SHA), each new sync-branch commit's
    # tree then represents a DELETE of all excluded paths (`.github/`, etc.)
    # relative to that parent's tree. A rebase-merge of that sync branch into
    # public main correctly wipes those files, and the generated-diff guard
    # rejects the result. Instead, we emit a delta-mode stream (M/D ops vs the marks-
    # anchored parent) and apply the include-set filter in filter-stream.py.
    # `--no-renames` decomposes renames into D+M pairs so the filter handles
    # each side independently — a rename out of the include-set becomes a
    # plain delete on the sync side, and a rename into the include-set
    # becomes a plain add. See `build_filter_exclude_paths`.
    log "Running fast-export (delta mode, source=$SOURCE_REF -> $export_ref @ ${source_sha:0:8})"
    if ! git -C "$PRIVATE_REPO" fast-export \
        "${import_marks_arg[@]}" \
        --export-marks="$PRIVATE_MARKS" \
        --refspec="$export_ref:refs/heads/main" \
        "$export_ref" \
        --tag-of-filtered-object=drop \
        --no-renames \
        > "$stream_file" 2>"$stream_file.err"; then

        cat "$stream_file.err" >&2
        if [[ ${#import_marks_arg[@]} -gt 0 ]] && public_main_exists; then
            log "ERROR: fast-export failed with marks; refusing to retry as an unanchored full export."
            log "Seed recovery is required before retrying."
        fi
        return 1
    fi

    local size
    size=$(wc -c < "$stream_file")
    log "Exported $size bytes"
}

run_filter() {
    local input="$1"
    local output="$2"
    local source_ref="${3:-}"
    local target_ref="${4:-}"
    log "Filtering stream"
    local -a ref_args=()
    if [[ -n "$source_ref" && -n "$target_ref" ]]; then
        ref_args=(--source-ref "$source_ref" --target-ref "$target_ref")
    fi
    # Materialize the positive default scope plus operator-supplied additions.
    local -a include_args=()
    local include_path include_type
    while IFS=$'\t' read -r include_type include_path; do
        [[ -z "$include_path" ]] && continue
        if [[ "$include_type" == "prefix" ]]; then
            include_args+=(--include-prefix "$include_path")
        else
            include_args+=(--include-file "$include_path")
        fi
    done < <(build_default_include_args)
    while IFS=$'\t' read -r include_type include_path; do
        [[ -z "$include_path" ]] && continue
        if [[ "$include_type" == "prefix" ]]; then
            include_args+=(--include-prefix "$include_path")
        else
            include_args+=(--include-file "$include_path")
        fi
    done < <(build_additional_include_args)

    if [[ ${#include_args[@]} -eq 0 ]]; then
        log "ERROR: sync config produced an empty include scope"
        return 1
    fi

    # Materialize --exclude-path args from sync-config + SYNC_BLOCKED_PATHS.
    # Build the array carefully so an empty exclude list produces zero
    # args (vs a stray empty string).
    local -a exclude_args=()
    local exclude_path
    while IFS= read -r exclude_path; do
        [[ -z "$exclude_path" ]] && continue
        exclude_args+=(--exclude-path "$exclude_path")
    done < <(build_filter_exclude_paths)
    local exclude_basename
    while IFS= read -r exclude_basename; do
        [[ -z "$exclude_basename" ]] && continue
        exclude_args+=(--exclude-basename "$exclude_basename")
    done < <(build_filter_exclude_basenames)
    python3 "$FILTER_SCRIPT" --mailmap "$MAILMAP_FILE" "${ref_args[@]}" \
        "${include_args[@]}" "${exclude_args[@]}" \
        < "$input" > "$output" 2>"$output.err" || {
        log "ERROR: Filter failed"
        cat "$output.err" >&2
        return 1
    }
    local size
    size=$(wc -c < "$output")
    log "Filtered output: $size bytes"
}

# Returns 0 if the stream contains at least one real fast-import commit
# command, 1 otherwise. Blob data blocks can contain arbitrary text —
# including lines that look like fast-import commands (e.g., documentation
# about git internals). We detect real commit commands by looking for the
# canonical two-line pattern: a "commit refs/..." line immediately followed
# by a "mark :" line. In well-formed fast-export output, blob payloads are
# emitted as "data N" + exactly N raw bytes, so protocol-level "mark :"
# lines do not appear inside them. This makes false positives extremely
# unlikely, though not provably impossible for malformed streams.
#
# The post-import ref verification in run_fast_import is the authoritative
# safety net; this function is a fast-path to skip invoking fast-import on
# streams with zero real commits.
stream_has_commits() {
    awk '
    prev_is_commit == 1 && /^mark :/ { found = 1; exit }
    { prev_is_commit = 0 }
    /^commit refs\// { prev_is_commit = 1 }
    END { exit (found ? 0 : 1) }
    ' "$1" 2>/dev/null
}

run_fast_import() {
    local stream="$1"

    if ! stream_has_commits "$stream"; then
        log "No commits in filtered stream — skipping import"
        return 2
    fi

    local -a import_marks_arg=()
    if [[ -f "$PUBLIC_MARKS" ]]; then
        import_marks_arg=("--import-marks=$PUBLIC_MARKS")
    fi

    local import_err="$stream.import.err"
    log "Running fast-import to refs/heads/$SYNC_BRANCH"
    if git -C "$PUBLIC_REPO" fast-import \
        --force \
        "${import_marks_arg[@]}" \
        --export-marks="$PUBLIC_MARKS" \
        < "$stream" > /dev/null 2>"$import_err"; then
        rm -f "$import_err"
        # Verify the target ref was actually created. fast-import exits 0 even
        # when the stream contained only blobs/resets without any commit commands
        # (e.g., stream_has_commits false-positive from blob data). If the ref
        # doesn't exist, treat as "no commits imported" rather than success.
        if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
            log "fast-import exited 0 but refs/heads/$SYNC_BRANCH was not created — treating as no-op"
            return 2
        fi
        return 0
    fi

    cat "$import_err" >&2

    # Stale marks recovery: if import failed and we had public marks, ask the
    # caller to discard both paired marks files and retry export+filter+import.
    if [[ ${#import_marks_arg[@]} -gt 0 ]]; then
        return 3
    fi

    log "ERROR: fast-import failed"
    return 1
}

path_matches_exclusions() {
    local path="$1"
    local prefixes_name="$2"
    local basenames_name="$3"
    local -n prefixes="$prefixes_name"
    local -n basenames="$basenames_name"
    local prefix basename

    for prefix in "${prefixes[@]:-}"; do
        [[ -z "$prefix" ]] && continue
        if [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]]; then
            return 0
        fi
    done
    basename="${path##*/}"
    for prefix in "${basenames[@]:-}"; do
        if [[ "$basename" == "$prefix" ]]; then
            return 0
        fi
    done
    return 1
}

assert_safe_reconciliation_ancestors() {
    local ref="$1"
    local path="$2"
    local current=""
    local entry mode
    local -a components=()
    local i

    IFS='/' read -r -a components <<< "$path"
    for ((i = 0; i + 1 < ${#components[@]}; i++)); do
        current="${current:+$current/}${components[$i]}"
        entry=$(git -C "$PUBLIC_REPO" ls-tree "$ref" -- "$current")
        mode="${entry%% *}"
        if [[ "$mode" == "120000" || -L "$PUBLIC_REPO/$current" ]]; then
            log "ERROR: refusing to reconcile '$path' through symlink ancestor '$current'"
            return 1
        fi
    done
    return 0
}

collect_reconciliation_paths() {
    local repo="$1"
    local ref="$2"
    local include_type="$3"
    local bare="$4"
    local output_name="$5"
    local -n output="$output_name"
    local root_entry root_meta root_type entry meta path mode type oid
    local -a entries=()

    root_entry=$(git -C "$repo" ls-tree "$ref" -- "$bare")
    [[ -z "$root_entry" ]] && return 0
    root_meta="${root_entry%%$'\t'*}"
    root_type=$(awk '{ print $2 }' <<< "$root_meta")

    if [[ "$include_type" == "file" ]]; then
        if [[ "$root_type" != "blob" ]]; then
            log "ERROR: additional file '$bare' resolves to a $root_type"
            return 1
        fi
        mode=$(awk '{ print $1 }' <<< "$root_meta")
        oid=$(awk '{ print $3 }' <<< "$root_meta")
        output["$bare"]="$mode:$oid"
        return 0
    fi

    if [[ "$root_type" != "tree" ]]; then
        log "ERROR: included directory '$bare/' resolves to a $root_type"
        return 1
    fi

    mapfile -d '' -t entries < <(git -C "$repo" ls-tree -r -z "$ref" -- "$bare")
    for entry in "${entries[@]}"; do
        meta="${entry%%$'\t'*}"
        path="${entry#*$'\t'}"
        read -r mode type oid <<< "$meta"
        if [[ "$type" != "blob" ]]; then
            log "ERROR: included path '$path' has unsupported git object type '$type'"
            return 1
        fi
        output["$path"]="$mode:$oid"
    done
}

reconcile_allowed_paths() {
    local target_ref=""
    if git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        target_ref="refs/heads/$SYNC_BRANCH"
    elif git -C "$PUBLIC_REPO" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
        target_ref="refs/heads/main"
    else
        return 2
    fi

    local -a include_types=() include_paths=()
    local path include_type
    while IFS=$'\t' read -r include_type path; do
        [[ -z "$path" ]] && continue
        include_types+=("$include_type")
        include_paths+=("$path")
    done < <(build_default_include_args)
    while IFS=$'\t' read -r include_type path; do
        [[ -z "$path" ]] && continue
        include_types+=("$include_type")
        include_paths+=("$path")
    done < <(build_additional_include_args)

    local -a exclude_paths=() exclude_basenames=()
    mapfile -t exclude_paths < <(build_filter_exclude_paths)
    mapfile -t exclude_basenames < <(build_filter_exclude_basenames)

    local -A private_files=() public_files=()
    local i
    for ((i = 0; i < ${#include_paths[@]}; i++)); do
        collect_reconciliation_paths "$PRIVATE_REPO" "$SOURCE_REF" \
            "${include_types[$i]}" "${include_paths[$i]}" private_files || return 1
        collect_reconciliation_paths "$PUBLIC_REPO" "$target_ref" \
            "${include_types[$i]}" "${include_paths[$i]}" public_files || return 1
    done

    local needs_reconciliation=0
    for path in "${!public_files[@]}"; do
        path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
        if [[ -z "${private_files[$path]:-}" ]]; then
            needs_reconciliation=1
            break
        fi
    done
    if [[ $needs_reconciliation -eq 0 ]]; then
        for path in "${!private_files[@]}"; do
            path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
            if [[ "${private_files[$path]}" != "${public_files[$path]:-}" ]]; then
                needs_reconciliation=1
                break
            fi
        done
    fi
    [[ $needs_reconciliation -eq 0 ]] && return 2

    for path in "${!public_files[@]}"; do
        path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
        [[ -n "${private_files[$path]:-}" ]] && continue
        assert_safe_reconciliation_ancestors "$target_ref" "$path" || return 1
    done
    for path in "${!private_files[@]}"; do
        path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
        [[ "${private_files[$path]}" == "${public_files[$path]:-}" ]] && continue
        assert_safe_reconciliation_ancestors "$target_ref" "$path" || return 1
    done

    if [[ "$target_ref" == "refs/heads/main" ]]; then
        git -C "$PUBLIC_REPO" branch "$SYNC_BRANCH" "$target_ref"
    fi
    git -C "$PUBLIC_REPO" checkout --quiet "$SYNC_BRANCH"

    for path in "${!public_files[@]}"; do
        path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
        if [[ -z "${private_files[$path]:-}" ]]; then
            rm -rf -- "$PUBLIC_REPO/$path"
        fi
    done
    for path in "${!private_files[@]}"; do
        path_matches_exclusions "$path" exclude_paths exclude_basenames && continue
        [[ "${private_files[$path]}" == "${public_files[$path]:-}" ]] && continue
        rm -rf -- "$PUBLIC_REPO/$path"
        git -C "$PRIVATE_REPO" archive "$SOURCE_REF" -- "$path" \
            | tar -xf - -C "$PUBLIC_REPO"
    done

    git -C "$PUBLIC_REPO" add -A
    if git -C "$PUBLIC_REPO" diff --cached --quiet; then
        return 2
    fi
    git -C "$PUBLIC_REPO" \
        -c user.name="foundry-samples sync" \
        -c user.email="foundry-samples-sync@users.noreply.github.com" \
        commit --quiet -m "Reconcile allowed sync paths"
    log "Reconciled current private content over the allowed sync scope"
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ -n "${FORCE_FULL:-}" && "${FORCE_FULL}" != "0" ]]; then
        log "ERROR: FORCE_FULL is disabled; direct or full-tree replacement sync is not supported."
        fail_closed "FORCE_FULL_DISABLED"
    fi

    require_env
    if ! SYNC_ADDITIONAL_PATHS="$(bash "$SCOPE_ASSERT_SCRIPT" \
        --normalize-only "${SYNC_ADDITIONAL_PATHS:-}")"; then
        fail_closed "INVALID_ADDITIONAL_PATHS"
    fi
    export SYNC_ADDITIONAL_PATHS
    setup_marks_state
    check_marks_validity

    # Capture public repo state BEFORE any modifications (for rollback)
    local public_head_before=""
    if git -C "$PUBLIC_REPO" rev-parse --verify main >/dev/null 2>&1; then
        public_head_before=$(git -C "$PUBLIC_REPO" rev-parse main)
    fi
    emit_output "public_head_before" "$public_head_before"

    local tmp_dir
    tmp_dir="$MARKS_DIR/sync-core-tmp-$$"
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"
    trap "rm -rf '$tmp_dir'" EXIT

    local export_stream="$tmp_dir/export.stream"
    local filtered_stream="$tmp_dir/filtered.stream"

    # Snapshot the source SHA — the private commit we are about to reconcile
    # with public main. Used (a) by stale-marks recovery to anchor seed-from-
    # public against the LAST known-good private SHA (see below), and (b) at
    # successful exit to update the last-synced sentinel.
    local current_source_sha=""
    if ! current_source_sha=$(git -C "$PRIVATE_REPO" rev-parse --verify "$SOURCE_REF^{commit}" 2>/dev/null); then
        log "ERROR: cannot resolve SOURCE_REF=$SOURCE_REF in $PRIVATE_REPO"
        emit_output "has_changes" "false"
        exit 1
    fi

    # Recover the LAST-SYNCED private SHA. Prefer the sentinel file (written
    # atomically after every successful import) over the marks-file tail —
    # `awk 'END' private.marks` was the historical source but is unreliable:
    # fast-export's --export-marks rewrites the file each run, and no-op
    # incremental runs can leave a mark for an excluded-paths-only commit at
    # the tail. Used by stale-marks recovery to seed against
    # (public main HEAD ↔ last-synced private SHA). Empty if no prior state.
    local last_synced_private_sha=""
    last_synced_private_sha=$(read_last_synced_sentinel)

    # Step 1: Export from private
    if ! run_fast_export "$export_stream"; then
        fail_closed "EXPORT_FAILED"
    fi

    # Step 2: Filter the stream (rewrite refs/heads/main -> refs/heads/$SYNC_BRANCH safely)
    run_filter "$export_stream" "$filtered_stream" \
        "refs/heads/main" "refs/heads/$SYNC_BRANCH"

    # Step 3: Import (if there are commits)
    local has_imports=0
    local import_result=0
    run_fast_import "$filtered_stream" && import_result=$? || import_result=$?
    if [[ $import_result -eq 3 ]]; then
        # Stale-marks recovery. The dominant cause in production is the
        # rebase-merge SHA-rewrite pattern: when the public PR was landed via
        # `gh pr merge --rebase`, GitHub rewrote the sync-branch commit SHAs,
        # and "Close stale sync PRs" + gc later pruned the originals. Public
        # main HEAD now holds the same trees under different SHAs, but
        # PUBLIC_MARKS still points at the (now-unreachable) sync-branch SHAs.
        #
        # Try seed-marks-from-public against (public main HEAD ↔ last private
        # SHA in PRIVATE_MARKS) FIRST. When the trees match — the common case —
        # this re-pairs the marks against the rebased SHAs and the retry
        # imports as a single delta on top of public main HEAD.
        #
        # Tree-mismatch during seed indicates real drift on public main. Fail
        # closed rather than producing an orphan branch.
        local public_main_sha="" seed_recovered=0
        if git -C "$PUBLIC_REPO" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
            public_main_sha=$(git -C "$PUBLIC_REPO" rev-parse refs/heads/main)
        fi

        if [[ -n "$last_synced_private_sha" && -n "$public_main_sha" ]]; then
            log "WARNING: fast-import failed with marks — attempting seed-marks recovery (private ${last_synced_private_sha:0:8} ↔ public main ${public_main_sha:0:8})"
            local seed_err="$tmp_dir/seed-recovery.err"
            if PRIVATE_REPO="$PRIVATE_REPO" PUBLIC_REPO="$PUBLIC_REPO" \
               CONFIG_FILE="$CONFIG_FILE" \
               SYNC_BLOCKED_PATHS="${SYNC_BLOCKED_PATHS:-}" \
               bash "$SEED_MARKS_SCRIPT" \
                   --private-sha "$last_synced_private_sha" \
                   --public-sha "$public_main_sha" \
                   --marks-dir "$MARKS_DIR" 2>"$seed_err"; then
                log "Seed-marks recovery succeeded — retrying export+import with re-paired marks"
                if ! run_fast_export "$export_stream"; then
                    fail_closed "EXPORT_FAILED"
                fi
                run_filter "$export_stream" "$filtered_stream" \
                    "refs/heads/main" "refs/heads/$SYNC_BRANCH"
                import_result=0
                run_fast_import "$filtered_stream" && import_result=$? || import_result=$?
                if [[ $import_result -eq 0 || $import_result -eq 2 ]]; then
                    seed_recovered=1
                fi
            else
                cat "$seed_err" >&2 || true
                log "ERROR: seed-marks recovery failed — likely true drift on public main HEAD relative to last-synced private SHA. Investigate before retrying; do NOT discard marks blindly."
                fail_closed "SEED_RECOVERY_TREE_MISMATCH"
            fi
        fi

        if [[ $seed_recovered -eq 0 ]]; then
            if public_main_exists; then
                require_seed_recovery "Fast-import marks are stale and no verified seed anchor is available."
            fi
            log "WARNING: stale bootstrap marks with no public main — rebuilding first-public state."
            rm -f "$PRIVATE_MARKS" "$PUBLIC_MARKS" "$LAST_SYNCED_FILE"
            if ! run_fast_export "$export_stream"; then
                fail_closed "EXPORT_FAILED"
            fi
            run_filter "$export_stream" "$filtered_stream" \
                "refs/heads/main" "refs/heads/$SYNC_BRANCH"
            import_result=0
            run_fast_import "$filtered_stream" && import_result=$? || import_result=$?
        fi
    fi

    if [[ $import_result -eq 0 ]]; then
        has_imports=1
    elif [[ $import_result -eq 1 || $import_result -eq 3 ]]; then
        log "ERROR: fast-import failed"
        emit_output "has_changes" "false"
        exit 1
    fi
    # import_result==2 means no commits, that's fine

    # Step 4: Reconcile the current allowed tree. Marks intentionally remain
    # scope-independent, so this materializes paths that become eligible after
    # their original commits were already marked (additional paths or samples
    # released from a prior validation block-list).
    local reconcile_result=0
    reconcile_allowed_paths && reconcile_result=$? || reconcile_result=$?
    if [[ $reconcile_result -eq 0 ]]; then
        has_imports=1
    elif [[ $reconcile_result -ne 2 ]]; then
        fail_closed "RECONCILIATION_FAILED"
    fi

    # Step 5: Decide whether to do anything else
    if [[ $has_imports -eq 0 ]]; then
        log "Nothing to sync — clean exit"
        # Even on no-op, the source SHA is reconciled with public main (the
        # filtered stream was empty, meaning every commit in
        # last-synced..source is excluded-paths-only). Advance the sentinel
        # so the next run sees this SHA as the recovery anchor.
        write_last_synced_sentinel "$current_source_sha"
        emit_output "has_changes" "false"
        emit_output "commit_count" "0"
        emit_output "authors" ""
        exit 0
    fi

    # Step 6: Verify sync branch exists
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        log "ERROR: Sync branch $SYNC_BRANCH was not created"
        emit_output "has_changes" "false"
        exit 1
    fi

    # Step 7: Final path-scope invariant against the prospective merge result.
    if ! bash "$SCOPE_ASSERT_SCRIPT" \
        --repo "$PUBLIC_REPO" \
        --base-ref main \
        --head-ref "refs/heads/$SYNC_BRANCH" \
        --config "$CONFIG_FILE" \
        --additional-paths "$SYNC_ADDITIONAL_PATHS"; then
        fail_closed "SYNC_SCOPE_VIOLATION"
    fi

    # Step 8: Emit summary outputs
    local commit_count authors
    if [[ -n "$public_head_before" ]]; then
        commit_count=$(git -C "$PUBLIC_REPO" rev-list --count "${public_head_before}..${SYNC_BRANCH}" 2>/dev/null || echo 0)
        authors=$(git -C "$PUBLIC_REPO" log "${public_head_before}..${SYNC_BRANCH}" --format="%an" 2>/dev/null | sort -u | paste -sd ", " - || echo "")
    else
        commit_count=$(git -C "$PUBLIC_REPO" rev-list --count "$SYNC_BRANCH" 2>/dev/null || echo 0)
        authors=$(git -C "$PUBLIC_REPO" log "$SYNC_BRANCH" --format="%an" 2>/dev/null | sort -u | paste -sd ", " - || echo "")
    fi
    emit_output "has_changes" "true"
    emit_output "commit_count" "$commit_count"
    emit_output "authors" "$authors"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log "DRY_RUN=1 — sync branch built locally"
        log "Sync branch: $SYNC_BRANCH"
        log "Commits on sync branch:"
        git -C "$PUBLIC_REPO" log --oneline "$SYNC_BRANCH" -10 >&2 || true
        # Sentinel reflects what we just reconciled — write it even in dry-run.
        # The workflow's cache-save step is gated on dry_run=false (except for
        # seed_from_public_sha dispatches, which DO save), so dry-run-only
        # local writes won't pollute the next operator-run state.
        write_last_synced_sentinel "$current_source_sha"
        exit 0
    fi

    write_last_synced_sentinel "$current_source_sha"
    log "Sync complete. Branch $SYNC_BRANCH ready in $PUBLIC_REPO"
    log "Caller is responsible for: git push, gh pr create, wait for checks, and merge"
    exit 0
}

main "$@"
