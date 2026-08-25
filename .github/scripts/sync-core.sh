#!/usr/bin/env bash
# .github/scripts/sync-core.sh
#
# Orchestrator for foundry-samples-pr → foundry-samples sync.
# Performs: marks management → fast-export → filter → fast-import →
# CODEOWNERS handling → ref update → optional push.
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
#   - apply_codeowners falls into the "branch missing → create from main"
#     fallback and amends public main's tip. Pushed branch is essentially
#     public main + 1 amend commit, with no imported authorship at all.
#
# Mitigation: run_fast_export pins SOURCE_REF to a fixed temp ref
# (refs/heads/sync-export-source) in the private repo before exporting, so
# the stream deterministically emits `commit refs/heads/main`, and our
# refspec + filter rewrites are predictable.
#
# Defensive check: apply_codeowners hard-fails if has_imports==1 but
# refs/heads/$SYNC_BRANCH is missing — would catch a regression of this bug
# immediately. See T28 in .github/tests/test-sync.sh for the regression test.
#
# Stale marks can also break fast-import when PUBLIC_MARKS references an
# object that no longer exists in the public repo. Recovery re-pairs the marks
# against a verified public/private SHA pair; it never publishes an orphan tree.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER_SCRIPT="$SCRIPT_DIR/filter-stream.py"
SEED_MARKS_SCRIPT="$SCRIPT_DIR/seed-marks-from-public.sh"

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

    for path in "$PRIVATE_REPO" "$PUBLIC_REPO" "$CONFIG_FILE" "$MAILMAP_FILE" "$FILTER_SCRIPT"; do
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
    python3 -c "
import json, sys
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
keys = '$key'.split('.')
val = cfg
for k in keys:
    val = val[k]
if isinstance(val, list):
    print('\n'.join(str(x) for x in val))
else:
    print(val)
"
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
        if [[ -d "$PRIVATE_REPO/$normalized" ]]; then
            printf ':!%s/\n' "$normalized"
        elif [[ -e "$PRIVATE_REPO/$normalized" ]]; then
            printf ':!%s\n' "$normalized"
        fi
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
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
for b in cfg.get('exclude_basenames', []):
    b = str(b).strip()
    if b:
        print(b)
"
}

# ── Protected-paths guard ─────────────────────────────────────────────────────
#
# Public-only files (e.g., GitHub Actions workflows) live exclusively on public
# main and are not in the sync include-set (`.github/` is excluded). They are
# preserved across syncs by fast-import's marks-anchored ancestry: each sync
# branch inherits the parent tree from the previous sync's commit, which has
# inherited public's workflows.
#
# When that ancestry chain breaks — most commonly when the discard-and-full-
# reexport recovery path (line ~770) fires without seed inputs — the resulting
# sync branch is orphaned and lacks public-only files. Pushing and merging that
# branch wipes them from public. (Incidents: PR #705/#707; PRs #758/#763 in
# 2026-06.)
#
# The guard runs after the sync branch is fully built (post-overlay,
# post-CODEOWNERS) and before the script exits. For each path listed in
# sync-config.json's `protected_paths`, it compares the blob SHA on fresh
# `origin/main` against the blob SHA on the local sync branch. Any deletion or
# content drift hard-fails the sync with a prescriptive recovery error.

# Read protected_paths from CONFIG_FILE. Returns 0 lines if the key is absent.
read_protected_paths() {
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
for p in cfg.get('protected_paths', []):
    print(p)
"
}

guard_protected_paths() {
    local -a protected_paths=()
    mapfile -t protected_paths < <(read_protected_paths)

    if [[ ${#protected_paths[@]} -eq 0 ]]; then
        return 0
    fi

    # Refresh public main so the comparison reflects current ground truth, not
    # the local checkout taken at workflow start. A human PR that lands on
    # public during the sync run shifts the base; comparing against stale local
    # main risks a false-positive guard fire.
    if ! git -C "$PUBLIC_REPO" fetch --quiet origin main 2>/dev/null; then
        log "WARNING: protected-paths guard could not fetch origin/main; comparing against local main"
    fi

    local base_ref
    if git -C "$PUBLIC_REPO" rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
        base_ref="refs/remotes/origin/main"
    elif git -C "$PUBLIC_REPO" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
        base_ref="refs/heads/main"
    else
        log "Protected-paths guard: public has no main ref — skipping (first-ever sync)"
        return 0
    fi

    local head_ref="refs/heads/$SYNC_BRANCH"
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "$head_ref" >/dev/null 2>&1; then
        log "ERROR: Protected-paths guard: sync branch $SYNC_BRANCH not present at guard time"
        return 1
    fi

    # Compute the prospective post-rebase-merge tree (ADO 5347121 / 5347427).
    # We do NOT compare blobs at the sync-branch tip directly: the sync branch
    # is always built by importing a delta-mode fast-export stream filtered by
    # `filter-stream.py --exclude-path` (see `run_fast_export` /
    # `run_filter`). For excluded paths, each sync-branch commit's tree
    # inherits content from its marks-anchored parent — but that parent's
    # tree may differ from current public main (e.g. when a human PR has
    # landed since the marks were last anchored, or when seed-marks-recovery
    # repointed the marks at PUBLIC_SHA but public main has since advanced).
    # The post-rebase-merge tree is therefore the correct ground truth:
    # simulating the merge GitHub will perform reveals whether the eventual
    # land would delete or modify a protected path, regardless of how the
    # sync-branch and public-main trees diverge mid-flight.
    #
    # GitHub merges sync PRs via `gh pr merge --rebase`. For the
    # common-ancestor case (handled by the `if` branch below), the 3-way
    # simulation computes the tree that the rebase merge will land.
    #
    # For an orphan sync branch (no common ancestor — handled by the
    # `else` branch below), `merge-tree` cannot soundly simulate either
    # strategy without `--allow-unrelated-histories`, which we deliberately
    # omit (it would produce a UNION tree and silently false-pass orphan
    # wipes — see the inline comment in the `else` branch). The orphan path
    # therefore treats the sync-branch tip tree as the prospective merge
    # result directly — that direct-tree check is what catches orphan wipes
    # (ADO 5349966), NOT the merge-tree simulation.
    #
    # `git merge-tree --write-tree` (git >= 2.38) computes the merged tree
    # OID without touching refs or the working tree — safe for dry-run.

    local git_version_line git_major git_minor
    git_version_line=$(git --version)
    git_major=$(printf '%s' "$git_version_line" | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1/')
    git_minor=$(printf '%s' "$git_version_line" | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\2/')
    if ! [[ "$git_major" =~ ^[0-9]+$ ]] || ! [[ "$git_minor" =~ ^[0-9]+$ ]]; then
        log "ERROR: Protected-paths guard: could not parse git version from '$git_version_line'"
        return 1
    fi
    if (( git_major < 2 )) || { (( git_major == 2 )) && (( git_minor < 38 )); }; then
        log "ERROR: Protected-paths guard requires git >= 2.38 (for 'merge-tree --write-tree'); found $git_version_line"
        return 1
    fi

    # Decide the prospective merge tree. In real sync topology, sync_branch
    # always anchors back to a previous public state via --import-marks, so
    # the merge base exists and merge-tree gives us the post-rebase tree.
    # For a true orphan sync branch (no common ancestor — only synthetic test
    # fixtures hit this in practice), fall back to the head tree directly:
    # an orphan rebase-merge would replace public main wholesale, so the head
    # tree IS the prospective result. Note: do NOT pass
    # `--allow-unrelated-histories` to merge-tree — with an empty merge base
    # it produces a UNION tree that would preserve protected files from base
    # and silently false-pass orphan wipes.
    local result_tree merge_output

    if git -C "$PUBLIC_REPO" merge-base "$base_ref" "$head_ref" >/dev/null 2>&1; then
        # Capture inside `if !` so `set -e` doesn't terminate the script on
        # non-zero exit before our distinct conflict-error path runs.
        if ! merge_output=$(git -C "$PUBLIC_REPO" merge-tree --write-tree "$base_ref" "$head_ref" 2>&1); then
            log "ERROR: Protected-paths guard: prospective merge of $head_ref into $base_ref has conflicts or 'git merge-tree' failed. This is NOT a protected-paths violation — the sync cannot proceed because the eventual rebase-merge would not apply cleanly."
            log "merge-tree output:"
            while IFS= read -r line; do
                log "  $line"
            done <<< "$merge_output"
            return 1
        fi
        # On success, stdout is exactly the result-tree OID on the first line.
        result_tree=$(printf '%s\n' "$merge_output" | head -n 1)
    else
        log "Protected-paths guard: no common ancestor between $base_ref and $head_ref — treating sync branch tree as the prospective merge result (orphan-rebase semantics)"
        result_tree=$(git -C "$PUBLIC_REPO" rev-parse --verify "$head_ref^{tree}" 2>/dev/null || echo "")
        if [[ -z "$result_tree" ]]; then
            log "ERROR: Protected-paths guard: could not resolve tree for $head_ref"
            return 1
        fi
    fi

    if ! git -C "$PUBLIC_REPO" rev-parse --verify "${result_tree}^{tree}" >/dev/null 2>&1; then
        log "ERROR: Protected-paths guard: 'git merge-tree --write-tree' returned an unexpected value: '$result_tree'"
        return 1
    fi

    local failed=0
    local path base_blob result_blob
    for path in "${protected_paths[@]}"; do
        base_blob=$(git -C "$PUBLIC_REPO" rev-parse --verify "$base_ref:$path" 2>/dev/null || echo "")
        result_blob=$(git -C "$PUBLIC_REPO" rev-parse --verify "$result_tree:$path" 2>/dev/null || echo "")

        if [[ -z "$base_blob" ]]; then
            # Path is not on public main. Two interpretations: (a) it was
            # intentionally removed on public, or (b) it was lost in a prior
            # wipe that has not yet been recovered. Either way, the sync branch
            # cannot be expected to preserve content that no longer exists on
            # the base. Skip silently.
            log "Protected-paths guard: $path absent from public main — skipping"
            continue
        fi

        if [[ -z "$result_blob" ]]; then
            # Phrased "MISSING from sync branch" for historical continuity
            # (tests grep this string); semantically the path is missing from
            # the prospective post-rebase-merge tree, which means a real
            # rebase-merge of this sync branch would delete the protected file.
            log "ERROR: Protected-paths guard: $path is on public main (blob ${base_blob:0:8}) but MISSING from sync branch $SYNC_BRANCH"
            failed=1
            continue
        fi

        if [[ "$base_blob" != "$result_blob" ]]; then
            # result_blob is the blob in the prospective post-rebase-merge tree
            # (not the sync-branch-tip tree), which is what would actually land
            # on public main after `gh pr merge --rebase`.
            log "ERROR: Protected-paths guard: $path has divergent content — public main blob ${base_blob:0:8} vs prospective merge result blob ${result_blob:0:8}"
            failed=1
            continue
        fi
    done

    if [[ $failed -ne 0 ]]; then
        log ""
        log "Protected-paths guard FAILED — refusing to push a sync branch that"
        log "would delete or modify public-only files."
        log ""
        log "Most common cause: a stale-marks or orphan-recovery code path"
        log "produced a sync branch whose tree does not inherit current public"
        log "main's workflow files. The marks state needs to be re-anchored."
        log ""
        log "Recovery procedure:"
        log "  1. If the protected files are missing on public main itself,"
        log "     restore them via a direct human PR (the human PR is the"
        log "     audit trail; the sync App should not be the actor)."
        log "  2. Trigger this sync workflow via workflow_dispatch with the"
        log "     'seed_from_public_sha' input set to the current public main"
        log "     HEAD. seed-marks-from-public.sh will validate tree-equivalence"
        log "     over the include-set and re-pair the marks."
        log "     Supply seed_from_private_sha when the matching private state is"
        log "     older than HEAD, and use dry_run=true first."
        log "  3. The next manual sync will resume with re-anchored marks."
        log ""
        log "See docs/repo-sync-automation.md for the full recovery procedure."
        return 1
    fi

    log "Protected-paths guard passed (${#protected_paths[@]} path(s) checked against prospective merge of $head_ref into $base_ref)"
    return 0
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
    # public main correctly wipes those files, and the protected-paths guard
    # fires. Instead, we emit a delta-mode stream (M/D ops vs the marks-
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
    python3 "$FILTER_SCRIPT" --mailmap "$MAILMAP_FILE" "${ref_args[@]}" "${exclude_args[@]}" \
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

# Copy CODEOWNERS from private to public if it changed.
# Returns 0 if a change was made (caller may want to amend or commit), 1 if unchanged.
sync_codeowners() {
    local src="$PRIVATE_REPO/.github/CODEOWNERS"
    local dst="$PUBLIC_REPO/.github/CODEOWNERS"

    if [[ ! -f "$src" ]]; then
        log "No CODEOWNERS in private repo — skipping"
        return 1
    fi

    # Check the public repo's HEAD on the sync branch (or main if branch doesn't exist yet)
    local ref="$SYNC_BRANCH"
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$ref" >/dev/null 2>&1; then
        ref="main"
    fi

    local existing=""
    if existing=$(git -C "$PUBLIC_REPO" show "$ref:.github/CODEOWNERS" 2>/dev/null); then
        if [[ "$existing" == "$(cat "$src")" ]]; then
            log "CODEOWNERS unchanged"
            return 1
        fi
    fi

    log "CODEOWNERS differs — will sync"
    return 0
}

# Check whether the public-overlay/ tree differs from public.
# Returns 0 if at least one overlay file is missing or differs on the public side
# (caller will apply), 1 if every overlay file already matches public.
#
# The overlay mechanism exists because git fast-import does not merge with prior
# public state — anything not in the import stream is wiped on fresh-marks
# rebuilds. Files placed at private:public-overlay/<path> are restored to
# public:<path> after import. See ADO 5255033 / Feature 5255019.
sync_public_overlay() {
    local overlay_root="$PRIVATE_REPO/public-overlay"

    if [[ ! -d "$overlay_root" ]]; then
        log "No public-overlay/ directory in private repo — skipping"
        return 1
    fi

    # Empty directory → no-op
    if [[ -z "$(find "$overlay_root" -mindepth 1 -type f -print -quit 2>/dev/null)" ]]; then
        log "public-overlay/ is empty — skipping"
        return 1
    fi

    # Compare against the public sync branch if it already exists, else main.
    local ref="$SYNC_BRANCH"
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$ref" >/dev/null 2>&1; then
        ref="main"
    fi

    local rel existing
    while IFS= read -r -d '' file; do
        rel="${file#"$overlay_root"/}"
        if existing=$(git -C "$PUBLIC_REPO" show "$ref:$rel" 2>/dev/null); then
            if [[ "$existing" == "$(cat "$file")" ]]; then
                continue
            fi
        fi
        log "public-overlay/$rel differs from public:$rel — will sync"
        return 0
    done < <(find "$overlay_root" -type f -print0)

    log "public-overlay/ unchanged"
    return 1
}

# Apply CODEOWNERS as a commit on the sync branch.
# If the sync branch already has imported commits, amend into the last one.
# If no imported commits exist, create a standalone bot commit.
apply_codeowners() {
    local src="$PRIVATE_REPO/.github/CODEOWNERS"
    local has_imports="$1"  # "1" if imports happened, "0" otherwise

    # If imports happened, the sync branch already exists — check it out without -B
    # (which would reset it to HEAD and lose the imported commits).
    # If no imports happened, create the sync branch from main.
    if git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        git -C "$PUBLIC_REPO" checkout "$SYNC_BRANCH" --quiet
    elif [[ "$has_imports" == "1" ]]; then
        # Imports were reported as successful but the sync branch is missing.
        # This means fast-import wrote the imported commits to a different ref —
        # almost certainly the refspec rewrite didn't take effect. Fail loudly
        # rather than silently creating an empty branch from main.
        log "ERROR: imports reported but refs/heads/$SYNC_BRANCH is missing"
        log "  fast-import likely wrote to a different ref name. Existing refs:"
        git -C "$PUBLIC_REPO" for-each-ref --format='    %(refname)' refs/heads >&2 || true
        return 1
    else
        # No imports — create sync branch from main
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" main --quiet 2>/dev/null || \
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" --quiet
    fi

    mkdir -p "$PUBLIC_REPO/.github"
    cp "$src" "$PUBLIC_REPO/.github/CODEOWNERS"
    git -C "$PUBLIC_REPO" add .github/CODEOWNERS

    if ! git -C "$PUBLIC_REPO" diff --cached --quiet; then
        if [[ "$has_imports" == "1" ]]; then
            log "Amending CODEOWNERS into last imported commit"
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit --amend --no-edit --quiet
        else
            log "Creating standalone bot commit for CODEOWNERS"
            GIT_AUTHOR_NAME="foundry-samples-sync[bot]" \
            GIT_AUTHOR_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit -m "chore: sync CODEOWNERS" --quiet
        fi
        return 0
    else
        log "No CODEOWNERS staging diff — nothing to commit"
        return 0
    fi
}

# Apply public-overlay/ files as a commit on the sync branch.
# Each file at private:public-overlay/<path> is copied to public:<path>
# (NOT public:public-overlay/<path>). If the sync branch already has imported
# commits, amend into the last one. Otherwise create a standalone bot commit.
#
# The bot identity matches apply_codeowners so authorship is consistent across
# both overlay mechanisms. CODEOWNERS continues to live in its own dedicated
# function (parallel mechanism); consolidation tracked separately.
apply_public_overlay() {
    local overlay_root="$PRIVATE_REPO/public-overlay"
    local has_imports="$1"  # "1" if imports happened, "0" otherwise

    if git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        git -C "$PUBLIC_REPO" checkout "$SYNC_BRANCH" --quiet
    elif [[ "$has_imports" == "1" ]]; then
        log "ERROR: imports reported but refs/heads/$SYNC_BRANCH is missing (public-overlay)"
        log "  fast-import likely wrote to a different ref name. Existing refs:"
        git -C "$PUBLIC_REPO" for-each-ref --format='    %(refname)' refs/heads >&2 || true
        return 1
    else
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" main --quiet 2>/dev/null || \
        git -C "$PUBLIC_REPO" checkout -B "$SYNC_BRANCH" --quiet
    fi

    # Copy each overlay file to its target path under PUBLIC_REPO. Use -print0
    # so paths with whitespace or special characters are preserved, and cp -p so
    # mode bits (executable, etc.) are carried over.
    local rel parent_dir
    while IFS= read -r -d '' file; do
        rel="${file#"$overlay_root"/}"
        parent_dir="$(dirname -- "$rel")"
        if [[ "$parent_dir" != "." ]]; then
            mkdir -p -- "$PUBLIC_REPO/$parent_dir"
        fi
        cp -p -- "$file" "$PUBLIC_REPO/$rel"
        git -C "$PUBLIC_REPO" add -- "$rel"
    done < <(find "$overlay_root" -type f -print0)

    if ! git -C "$PUBLIC_REPO" diff --cached --quiet; then
        if [[ "$has_imports" == "1" ]]; then
            log "Amending public-overlay into last imported commit"
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit --amend --no-edit --quiet
        else
            log "Creating standalone bot commit for public-overlay"
            GIT_AUTHOR_NAME="foundry-samples-sync[bot]" \
            GIT_AUTHOR_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            GIT_COMMITTER_NAME="foundry-samples-sync[bot]" \
            GIT_COMMITTER_EMAIL="foundry-samples-sync[bot]@users.noreply.github.com" \
            git -C "$PUBLIC_REPO" commit -m "chore: sync public overlay" --quiet
        fi
        return 0
    else
        log "No public-overlay staging diff — nothing to commit"
        return 0
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
    if [[ -n "${FORCE_FULL:-}" && "${FORCE_FULL}" != "0" ]]; then
        log "ERROR: FORCE_FULL is disabled; direct or full-tree replacement sync is not supported."
        fail_closed "FORCE_FULL_DISABLED"
    fi

    require_env
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

    # Step 3: Check public-overlay + CODEOWNERS BEFORE deciding "nothing to sync"
    # (overlay-only and CODEOWNERS-only changes still need a public commit even
    # when no private code changed.)
    local overlay_available=0
    if [[ -d "$PRIVATE_REPO/public-overlay" \
        && -n "$(find "$PRIVATE_REPO/public-overlay" -mindepth 1 -type f -print -quit 2>/dev/null)" ]]; then
        overlay_available=1
    fi

    local overlay_changed=0
    if sync_public_overlay; then
        overlay_changed=1
    fi

    local codeowners_available=0
    if [[ -f "$PRIVATE_REPO/.github/CODEOWNERS" ]]; then
        codeowners_available=1
    fi

    local codeowners_changed=0
    if sync_codeowners; then
        codeowners_changed=1
    fi

    # Step 4: Import (if there are commits)
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

    # Step 5: Decide whether to do anything else
    if [[ $has_imports -eq 0 && $codeowners_changed -eq 0 && $overlay_changed -eq 0 ]]; then
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

    # Step 6: Apply public-overlay first, then CODEOWNERS.
    # Order matters: when both apply with imports, CODEOWNERS amends last so its
    # state is the final one on the imported commit. When both apply without
    # imports, each function creates its own standalone bot commit (acceptable —
    # both happen on the same sync branch).
    if [[ $overlay_available -eq 1 && ( $has_imports -eq 1 || $overlay_changed -eq 1 ) ]]; then
        apply_public_overlay "$has_imports"
    fi

    # Step 7: Apply CODEOWNERS (if changed, or after imports may have removed it)
    if [[ $codeowners_available -eq 1 && ( $has_imports -eq 1 || $codeowners_changed -eq 1 ) ]]; then
        apply_codeowners "$has_imports"
    fi

    # Step 8: Verify sync branch exists
    if ! git -C "$PUBLIC_REPO" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        log "ERROR: Sync branch $SYNC_BRANCH was not created"
        emit_output "has_changes" "false"
        exit 1
    fi

    # Step 8.5: Protected-paths invariant — fail-stop before push if any
    # public-only file would be deleted or modified by this sync branch.
    if ! guard_protected_paths; then
        emit_output "has_changes" "false"
        exit 1
    fi

    # Step 9: Emit summary outputs
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
        # local writes won't pollute scheduled-run state.
        write_last_synced_sentinel "$current_source_sha"
        exit 0
    fi

    write_last_synced_sentinel "$current_source_sha"
    log "Sync complete. Branch $SYNC_BRANCH ready in $PUBLIC_REPO"
    log "Caller is responsible for: git push, gh pr create, wait for checks, and merge"
    exit 0
}

main "$@"
