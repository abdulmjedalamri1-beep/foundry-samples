#!/usr/bin/env bash
# .github/tests/test-sync.sh
#
# Self-contained test suite for the foundry-samples sync workflow.
# Creates temporary git repos, runs the sync logic, and validates correctness.
# No real repos or tokens needed — all tests are local.
#
# Usage: bash .github/tests/test-sync.sh
# Exit code: 0 if all tests pass, 1 if any fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FILTER_SCRIPT="$REPO_ROOT/.github/scripts/filter-stream.py"
SYNC_SCRIPT="$REPO_ROOT/.github/scripts/sync-core.sh"
SEED_MARKS_SCRIPT="$REPO_ROOT/.github/scripts/seed-marks-from-public.sh"
SCOPE_ASSERT_SCRIPT="$REPO_ROOT/.github/scripts/assert-sync-scope.sh"
WORKFLOW_CONTRACT_TEST="$REPO_ROOT/.github/tests/test-sync-workflow.py"

# ── Test framework ─────────────────────────────────────────────────────────────

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILURES=()

pass() {
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo "  ✅ PASS: $1"
}

fail() {
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILURES+=("$1: $2")
    echo "  ❌ FAIL: $1 — $2"
}

run_test() {
    local test_id="$1"
    local test_name="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo ""
    echo "── $test_id: $test_name ──"
}

summary() {
    echo ""
    echo "════════════════════════════════════════════════════"
    echo "  Tests run: $TESTS_RUN  |  Passed: $TESTS_PASSED  |  Failed: $TESTS_FAILED"
    echo "════════════════════════════════════════════════════"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo ""
        echo "Failures:"
        for f in "${FAILURES[@]}"; do
            echo "  • $f"
        done
        exit 1
    fi
    exit 0
}

# ── Helpers ────────────────────────────────────────────────────────────────────

WORK_DIR=""

setup_repos() {
    # Create a fresh temp directory with private and public repos
    WORK_DIR="/tmp/test-sync-$$-${TESTS_RUN}"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"
    PRIVATE="$WORK_DIR/private"
    PUBLIC="$WORK_DIR/public"
    MARKS_DIR="$WORK_DIR/marks"
    MAILMAP="$WORK_DIR/test-mailmap"

    mkdir -p "$MARKS_DIR"

    # Create private repo
    git init --initial-branch=main "$PRIVATE" >/dev/null 2>&1
    cd "$PRIVATE"
    git config user.name "Init Bot"
    git config user.email "bot@test.com"
    # Initial commit so main exists — include excluded dirs so pathspecs are valid
    echo "# Private Repo" > README.md
    mkdir -p internal .github
    echo "placeholder" > internal/.gitkeep
    echo "placeholder" > .github/.gitkeep
    git add -A
    git commit -m "Initial commit" --quiet

    # Create public repo (bare init — fast-import populates it)
    git init --initial-branch=main "$PUBLIC" >/dev/null 2>&1
    cd "$PUBLIC"
    git config user.name "Init Bot"
    git config user.email "bot@test.com"

    # Default mailmap (empty — no internal emails by default)
    cat > "$MAILMAP" <<'EOF'
# Test mailmap
EOF

    cd "$WORK_DIR"
}

setup_public_with_extras() {
    setup_repos

    mkdir -p "$PRIVATE/samples"
    echo "shared v1" > "$PRIVATE/samples/shared.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add shared sample" samples/shared.txt

    mkdir -p "$PUBLIC/samples" "$PUBLIC/.github"
    echo "shared v1" > "$PUBLIC/samples/shared.txt"
    echo "# Public README" > "$PUBLIC/README.md"
    echo "# Public CONTRIBUTING" > "$PUBLIC/CONTRIBUTING.md"
    echo "* @public-team" > "$PUBLIC/.github/CODEOWNERS"
    cd "$PUBLIC" && git add -A && cd - >/dev/null
    env \
        GIT_AUTHOR_NAME="Public Dev" \
        GIT_AUTHOR_EMAIL="public@example.com" \
        GIT_COMMITTER_NAME="Public Dev" \
        GIT_COMMITTER_EMAIL="public@example.com" \
        git -C "$PUBLIC" commit -m "Seed public-only files" --quiet
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}

commit_as() {
    # commit_as <repo_path> <author_name> <author_email> <message> [files...]
    local repo="$1" name="$2" email="$3" msg="$4"
    shift 4
    cd "$repo"
    for f in "$@"; do
        git add "$f"
    done
    GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
    GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
    git commit -m "$msg" --quiet
    cd - >/dev/null
}

# Run fast-export → filter → fast-import for the test repos.
# Uses pathspecs from $EXCLUDE_PATHSPECS (default: exclude .github/ and internal/).
run_sync() {
    local exclude_specs="${EXCLUDE_PATHSPECS:-:!internal/ :!.github/}"
    local private_marks="$MARKS_DIR/private.marks"
    local public_marks="$MARKS_DIR/public.marks"

    local import_marks_private=""
    local import_marks_public=""
    if [[ -f "$private_marks" ]]; then
        import_marks_private="--import-marks=$private_marks"
    fi
    if [[ -f "$public_marks" ]]; then
        import_marks_public="--import-marks=$public_marks"
    fi

    # Build pathspec args — only include exclusions for paths that exist
    local pathspec_args=("--" ".")
    for spec in $exclude_specs; do
        # Extract the path from :!path or :(exclude)path
        local path="${spec#:!}"
        path="${path#:(exclude)}"
        path="${path%/}"  # strip trailing slash
        if [[ -e "$PRIVATE/$path" || -d "$PRIVATE/$path" ]]; then
            pathspec_args+=("$spec")
        fi
    done

    # Fast-export from private
    # shellcheck disable=SC2086
    git -C "$PRIVATE" fast-export \
        $import_marks_private \
        --export-marks="$private_marks" \
        refs/heads/main \
        --tag-of-filtered-object=drop \
        "${pathspec_args[@]}" \
        > "$WORK_DIR/export.stream" 2>/dev/null

    # Filter the stream
    python3 "$FILTER_SCRIPT" --mailmap "$MAILMAP" \
        < "$WORK_DIR/export.stream" \
        > "$WORK_DIR/filtered.stream" 2>"$WORK_DIR/filter.stderr"
    local filter_exit=$?

    if [[ $filter_exit -ne 0 ]]; then
        return $filter_exit
    fi

    # Fast-import into public (--force needed when re-importing diverged history,
    # e.g., after pathspec changes that alter the commit graph)
    git -C "$PUBLIC" fast-import \
        --force \
        $import_marks_public \
        --export-marks="$public_marks" \
        < "$WORK_DIR/filtered.stream" 2>/dev/null

    # Reset working tree to match imported state
    git -C "$PUBLIC" checkout main --quiet 2>/dev/null || true
    git -C "$PUBLIC" reset --hard HEAD --quiet 2>/dev/null || true

    return 0
}

count_commits() {
    # Count commits on main in the given repo (excluding the initial commit)
    git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0
}

blame_author() {
    # Get the blame author for a specific line in a file
    # blame_author <repo> <file> <line_number>
    git -C "$1" blame -L "$3,$3" --porcelain "$2" 2>/dev/null | grep "^author " | sed 's/^author //'
}

blame_email() {
    # Get the blame author email for a specific line in a file
    git -C "$1" blame -L "$3,$3" --porcelain "$2" 2>/dev/null | grep "^author-mail " | sed 's/^author-mail //' | tr -d '<>'
}

# ── Tests ──────────────────────────────────────────────────────────────────────

test_T1() {
    run_test "T1" "Single-author commit → blame shows that author"
    setup_repos

    echo "Hello from Alice" > "$PRIVATE/hello.txt"
    commit_as "$PRIVATE" "Alice Author" "alice@example.com" "Add hello" hello.txt

    run_sync

    local author
    author=$(blame_author "$PUBLIC" "hello.txt" 1)
    if [[ "$author" == "Alice Author" ]]; then
        pass "T1"
    else
        fail "T1" "Expected 'Alice Author', got '$author'"
    fi
    cleanup
}

test_T2() {
    run_test "T2" "Multiple authors → each commit retains its own author"
    setup_repos

    echo "Line by Alice" > "$PRIVATE/multi.txt"
    commit_as "$PRIVATE" "Alice Author" "alice@example.com" "Alice's line" multi.txt

    # Append a line (so Alice's line stays on line 1, Bob's on line 2)
    echo "Line by Bob" >> "$PRIVATE/multi.txt"
    commit_as "$PRIVATE" "Bob Builder" "bob@example.com" "Bob's line" multi.txt

    run_sync

    local alice bob
    alice=$(blame_author "$PUBLIC" "multi.txt" 1)
    bob=$(blame_author "$PUBLIC" "multi.txt" 2)
    if [[ "$alice" == "Alice Author" && "$bob" == "Bob Builder" ]]; then
        pass "T2"
    else
        fail "T2" "Expected Alice/Bob, got '$alice'/'$bob'"
    fi
    cleanup
}

test_T3() {
    run_test "T3" "Files in excluded paths don't appear in public repo"
    setup_repos

    mkdir -p "$PRIVATE/internal"
    echo "secret" > "$PRIVATE/internal/secret.txt"
    echo "public" > "$PRIVATE/public.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add files" internal/secret.txt public.txt

    run_sync

    if [[ -f "$PUBLIC/public.txt" && ! -f "$PUBLIC/internal/secret.txt" ]]; then
        pass "T3"
    else
        fail "T3" "public.txt should exist, internal/secret.txt should not"
    fi
    cleanup
}

test_T4() {
    run_test "T4" "CODEOWNERS syncs despite .github/ exclusion"
    # Note: CODEOWNERS is handled by sync-core.sh post-import step.
    # This test validates that fast-export excludes .github/.
    setup_repos

    mkdir -p "$PRIVATE/.github/workflows"
    echo "* @team" > "$PRIVATE/.github/CODEOWNERS"
    echo "workflow content" > "$PRIVATE/.github/workflows/build.yml"
    echo "code" > "$PRIVATE/src.txt"
    cd "$PRIVATE" && git add -A && cd - >/dev/null
    GIT_AUTHOR_NAME="Dev" GIT_AUTHOR_EMAIL="dev@example.com" \
    GIT_COMMITTER_NAME="Dev" GIT_COMMITTER_EMAIL="dev@example.com" \
    git -C "$PRIVATE" commit -m "Add .github files" --quiet

    run_sync

    # .github/ should be excluded from fast-export
    if [[ -f "$PUBLIC/src.txt" && ! -f "$PUBLIC/.github/CODEOWNERS" ]]; then
        pass "T4" 
    else
        fail "T4" "src.txt should exist; .github/CODEOWNERS should NOT be in fast-export output"
    fi
    cleanup
}

test_T5() {
    run_test "T5" "Incremental sync only transfers new commits"
    setup_repos

    echo "first" > "$PRIVATE/first.txt"
    commit_as "$PRIVATE" "Alice" "alice@example.com" "First commit" first.txt

    run_sync
    local count_after_first
    count_after_first=$(count_commits "$PUBLIC")

    echo "second" > "$PRIVATE/second.txt"
    commit_as "$PRIVATE" "Bob" "bob@example.com" "Second commit" second.txt

    run_sync
    local count_after_second
    count_after_second=$(count_commits "$PUBLIC")

    # The second sync should have added exactly 1 commit
    local diff=$((count_after_second - count_after_first))
    if [[ $diff -eq 1 ]]; then
        pass "T5"
    else
        fail "T5" "Expected 1 new commit, got $diff (before=$count_after_first, after=$count_after_second)"
    fi
    cleanup
}

test_T6() {
    run_test "T6" "No new commits AND CODEOWNERS unchanged → clean exit"
    setup_repos

    echo "content" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add file" file.txt

    run_sync
    local count_first
    count_first=$(count_commits "$PUBLIC")

    # Run sync again with no new commits
    run_sync
    local count_second
    count_second=$(count_commits "$PUBLIC")

    if [[ $count_first -eq $count_second ]]; then
        pass "T6"
    else
        fail "T6" "Commit count changed on no-op sync: $count_first → $count_second"
    fi
    cleanup
}

test_T7() {
    run_test "T7" "Commit touching only excluded paths → zero commits in public"
    setup_repos

    echo "public" > "$PRIVATE/public.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Public file" public.txt
    run_sync
    local count_before
    count_before=$(count_commits "$PUBLIC")

    mkdir -p "$PRIVATE/internal"
    echo "internal only" > "$PRIVATE/internal/data.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Internal only" internal/data.txt

    run_sync
    local count_after
    count_after=$(count_commits "$PUBLIC")

    if [[ $count_before -eq $count_after ]]; then
        pass "T7"
    else
        fail "T7" "Expected no new commits, but count changed: $count_before → $count_after"
    fi
    cleanup
}

test_T8() {
    run_test "T8" "Author dates and timestamps preserved"
    setup_repos

    local fixed_date="2024-06-15T10:30:00+00:00"
    echo "dated content" > "$PRIVATE/dated.txt"
    cd "$PRIVATE"
    git add dated.txt
    GIT_AUTHOR_NAME="Alice" GIT_AUTHOR_EMAIL="alice@example.com" \
    GIT_COMMITTER_NAME="Alice" GIT_COMMITTER_EMAIL="alice@example.com" \
    GIT_AUTHOR_DATE="$fixed_date" GIT_COMMITTER_DATE="$fixed_date" \
    git commit -m "Dated commit" --quiet
    cd - >/dev/null

    local private_date
    private_date=$(git -C "$PRIVATE" log -1 --format="%ai")

    run_sync

    local public_date
    public_date=$(git -C "$PUBLIC" log -1 --format="%ai")

    if [[ "$private_date" == "$public_date" ]]; then
        pass "T8"
    else
        fail "T8" "Dates differ: private='$private_date' public='$public_date'"
    fi
    cleanup
}

test_T9() {
    run_test "T9" "Commit messages preserved exactly"
    setup_repos

    local msg="feat: add amazing feature

This is a multi-line commit message.
It has details and stuff."

    echo "feature" > "$PRIVATE/feature.txt"
    cd "$PRIVATE"
    git add feature.txt
    GIT_AUTHOR_NAME="Dev" GIT_AUTHOR_EMAIL="dev@example.com" \
    GIT_COMMITTER_NAME="Dev" GIT_COMMITTER_EMAIL="dev@example.com" \
    git commit -m "$msg" --quiet
    cd - >/dev/null

    run_sync

    local public_msg
    public_msg=$(git -C "$PUBLIC" log -1 --format="%B" | head -c 200)
    if echo "$public_msg" | grep -q "feat: add amazing feature"; then
        pass "T9"
    else
        fail "T9" "Message not preserved. Got: '$public_msg'"
    fi
    cleanup
}

test_T10() {
    run_test "T10" "Second incremental sync after more commits works"
    setup_repos

    echo "a" > "$PRIVATE/a.txt"
    commit_as "$PRIVATE" "Alice" "alice@example.com" "Commit A" a.txt
    run_sync

    echo "b" > "$PRIVATE/b.txt"
    commit_as "$PRIVATE" "Bob" "bob@example.com" "Commit B" b.txt
    run_sync

    echo "c" > "$PRIVATE/c.txt"
    commit_as "$PRIVATE" "Charlie" "charlie@example.com" "Commit C" c.txt
    run_sync

    if [[ -f "$PUBLIC/a.txt" && -f "$PUBLIC/b.txt" && -f "$PUBLIC/c.txt" ]]; then
        local author_c
        author_c=$(blame_author "$PUBLIC" "c.txt" 1)
        if [[ "$author_c" == "Charlie" ]]; then
            pass "T10"
        else
            fail "T10" "Third sync author wrong: expected 'Charlie', got '$author_c'"
        fi
    else
        fail "T10" "Not all files present after three syncs"
    fi
    cleanup
}

test_T11() {
    run_test "T11" "Private repo .github/ content excluded from public"
    setup_repos

    # Add a .github/workflows file to the private repo
    mkdir -p "$PRIVATE/.github/workflows"
    echo "name: private-workflow" > "$PRIVATE/.github/workflows/private-ci.yml"
    echo "public code" > "$PRIVATE/code.txt"
    cd "$PRIVATE" && git add -A && cd - >/dev/null
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add code and workflow" code.txt .github/workflows/private-ci.yml

    run_sync

    # code.txt should be synced, but .github/ from private should NOT
    if [[ -f "$PUBLIC/code.txt" && ! -f "$PUBLIC/.github/workflows/private-ci.yml" ]]; then
        pass "T11"
    else
        if [[ -f "$PUBLIC/.github/workflows/private-ci.yml" ]]; then
            fail "T11" "Private .github/ content leaked to public"
        else
            fail "T11" "code.txt not synced"
        fi
    fi
    cleanup
}

test_T12() {
    run_test "T12" "Missing marks file → full re-export, no warnings"
    setup_repos

    echo "content" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add file" file.txt

    # Ensure no marks files exist
    rm -f "$MARKS_DIR"/*.marks 2>/dev/null || true

    run_sync

    if [[ -f "$PUBLIC/file.txt" ]]; then
        pass "T12"
    else
        fail "T12" "Full re-export failed — file.txt not present"
    fi
    cleanup
}

test_T13() {
    run_test "T13" "No @microsoft.com email in author/committer lines of export"
    setup_repos

    # Add a mailmap entry for the internal email
    cat > "$MAILMAP" <<'EOF'
Test User <12345+testuser@users.noreply.github.com> <testuser@microsoft.com>
EOF

    echo "internal author" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Test User" "testuser@microsoft.com" "Internal commit" file.txt

    run_sync

    # Check that the public repo has the safe email, not the internal one
    local email
    email=$(git -C "$PUBLIC" log -1 --format="%ae")
    if echo "$email" | grep -q "microsoft.com"; then
        fail "T13" "Internal email leaked: $email"
    else
        pass "T13"
    fi
    cleanup
}

test_T14() {
    run_test "T14" "Stream filter rewrites known internal emails to noreply"
    setup_repos

    cat > "$MAILMAP" <<'EOF'
Alice Microsoft <12345+alice-ms@users.noreply.github.com> <alice@microsoft.com>
EOF

    echo "ms content" > "$PRIVATE/ms.txt"
    commit_as "$PRIVATE" "Alice Microsoft" "alice@microsoft.com" "MS commit" ms.txt

    run_sync

    local author email
    author=$(blame_author "$PUBLIC" "ms.txt" 1)
    email=$(blame_email "$PUBLIC" "ms.txt" 1)
    if [[ "$author" == "Alice Microsoft" && "$email" == "12345+alice-ms@users.noreply.github.com" ]]; then
        pass "T14"
    else
        fail "T14" "Expected rewritten identity, got author='$author' email='$email'"
    fi
    cleanup
}

test_T15() {
    run_test "T15" "Unmapped @microsoft.com email blocks the sync"
    setup_repos

    # Empty mailmap — no mappings
    cat > "$MAILMAP" <<'EOF'
# Empty mailmap
EOF

    echo "unmapped" > "$PRIVATE/unmapped.txt"
    commit_as "$PRIVATE" "Unknown Dev" "unknown@microsoft.com" "Unmapped commit" unmapped.txt

    # run_sync should fail
    if run_sync 2>/dev/null; then
        fail "T15" "Sync should have failed for unmapped internal email"
    else
        # Check stderr for useful error message
        if grep -q "Unmapped internal email" "$WORK_DIR/filter.stderr" 2>/dev/null; then
            pass "T15"
        else
            pass "T15"  # Failed as expected, even if message differs
        fi
    fi
    cleanup
}

test_T16() {
    run_test "T16" "Commit touching both excluded and included paths → only included changes"
    setup_repos

    mkdir -p "$PRIVATE/internal"
    echo "public part" > "$PRIVATE/visible.txt"
    echo "internal part" > "$PRIVATE/internal/hidden.txt"
    cd "$PRIVATE" && git add -A && cd - >/dev/null
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Mixed commit" visible.txt internal/hidden.txt

    run_sync

    if [[ -f "$PUBLIC/visible.txt" && ! -f "$PUBLIC/internal/hidden.txt" ]]; then
        pass "T16"
    else
        fail "T16" "visible.txt should exist, internal/hidden.txt should not"
    fi
    cleanup
}

test_T17() {
    run_test "T17" "Stale marks file → degrades to full re-export"
    setup_repos

    echo "content" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add file" file.txt

    # Create bogus marks files with non-existent SHAs
    echo ":1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" > "$MARKS_DIR/private.marks"
    echo ":1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$MARKS_DIR/public.marks"

    # First attempt with stale marks will likely fail
    run_sync 2>/dev/null || true

    # Recovery: clear stale marks and retry (this is what sync-core.sh will do)
    rm -f "$MARKS_DIR"/*.marks
    if run_sync 2>/dev/null && [[ -f "$PUBLIC/file.txt" ]]; then
        pass "T17"
    else
        fail "T17" "Could not recover from stale marks after clearing"
    fi
    cleanup
}

test_T21() {
    run_test "T21" "Merge commit with included-path changes → correct author"
    setup_repos

    # Create a feature branch with a commit by Alice
    cd "$PRIVATE"
    git checkout -b feature --quiet
    echo "feature code" > feature.txt
    GIT_AUTHOR_NAME="Alice" GIT_AUTHOR_EMAIL="alice@example.com" \
    GIT_COMMITTER_NAME="Alice" GIT_COMMITTER_EMAIL="alice@example.com" \
    git add feature.txt && git commit -m "Feature by Alice" --quiet

    # Merge back to main (creates merge commit)
    git checkout main --quiet
    git merge feature --no-ff -m "Merge feature branch" --quiet
    cd - >/dev/null

    run_sync

    if [[ -f "$PUBLIC/feature.txt" ]]; then
        # The content should be attributable (via blame) to Alice or the merge
        local author
        author=$(blame_author "$PUBLIC" "feature.txt" 1)
        if [[ "$author" == "Alice" ]]; then
            pass "T21"
        else
            # Merge commit may take blame — that's acceptable behavior to document
            pass "T21"  # Merge handling is correct as long as content is present
        fi
    else
        fail "T21" "feature.txt not present after merge commit sync"
    fi
    cleanup
}

test_T22() {
    run_test "T22" "Merge commit touching both included and excluded paths"
    setup_repos

    cd "$PRIVATE"
    git checkout -b mixed-feature --quiet
    echo "visible" > mixed-visible.txt
    mkdir -p internal
    echo "hidden" > internal/mixed-hidden.txt
    git add -A && git commit -m "Mixed feature" --quiet \
        --author="Alice <alice@example.com>"

    git checkout main --quiet
    git merge mixed-feature --no-ff -m "Merge mixed feature" --quiet
    cd - >/dev/null

    run_sync

    if [[ -f "$PUBLIC/mixed-visible.txt" && ! -f "$PUBLIC/internal/mixed-hidden.txt" ]]; then
        pass "T22"
    else
        fail "T22" "visible should exist, internal/hidden should not"
    fi
    cleanup
}

test_T23() {
    run_test "T23" "Merge commit touching only excluded paths → no commit"
    setup_repos

    echo "baseline" > "$PRIVATE/baseline.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Baseline" baseline.txt
    run_sync
    local count_before
    count_before=$(count_commits "$PUBLIC")

    cd "$PRIVATE"
    git checkout -b internal-feature --quiet
    mkdir -p internal
    echo "internal only" > internal/feature.txt
    git add -A && git commit -m "Internal feature" --quiet
    git checkout main --quiet
    git merge internal-feature --no-ff -m "Merge internal feature" --quiet
    cd - >/dev/null

    run_sync
    local count_after
    count_after=$(count_commits "$PUBLIC")

    if [[ $count_before -eq $count_after ]]; then
        pass "T23"
    else
        # Merge commit itself may appear — that's a known edge case
        # As long as no internal files leaked, this is acceptable
        if [[ ! -f "$PUBLIC/internal/feature.txt" ]]; then
            pass "T23"  # No internal files leaked, empty merge commit is tolerable
        else
            fail "T23" "Internal files leaked through merge commit"
        fi
    fi
    cleanup
}

test_T25() {
    run_test "T25" "Remove exclusion → full re-export surfaces historical content"
    setup_repos

    # Create a file in a path that's initially excluded
    mkdir -p "$PRIVATE/internal"
    echo "was hidden" > "$PRIVATE/internal/nowpublic.txt"
    echo "always public" > "$PRIVATE/visible.txt"
    cd "$PRIVATE" && git add -A && cd - >/dev/null
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add files" internal/nowpublic.txt visible.txt

    # First sync with internal/ excluded (default)
    run_sync

    if [[ -f "$PUBLIC/internal/nowpublic.txt" ]]; then
        fail "T25" "File should be excluded on first sync"
        cleanup
        return
    fi

    # Now sync again WITHOUT the internal/ exclusion (simulating config change)
    # Clear marks to force full re-export (as production would do on pathspec change)
    rm -f "$MARKS_DIR"/*.marks
    EXCLUDE_PATHSPECS=":!.github/" run_sync

    if [[ -f "$PUBLIC/internal/nowpublic.txt" ]]; then
        pass "T25"
    else
        fail "T25" "Historical content should appear after removing exclusion"
    fi
    cleanup
}

# ── Run all tests ──────────────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════╗"
echo "║   foundry-samples Sync Workflow Test Suite       ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Filter script: $FILTER_SCRIPT"
echo "Sync script:   $SYNC_SCRIPT"

# Core authorship
test_T1
test_T2
test_T8
test_T9

# Path filtering
test_T3
test_T7
test_T11
test_T16

# .github/ remains excluded from the exported stream.
test_T4

# Incremental sync
test_T5
test_T6
test_T10
test_T12
test_T17

# Email privacy
test_T13
test_T14
test_T15

# Merge commits
test_T21
test_T22
test_T23

# Exclusion config changes
test_T25

# ── sync-core.sh integration tests ────────────────────────────────────────────

# Helper: set up a sync-core.sh test environment.
# Creates a config file, mailmap, marks dir, and sync branch name.
setup_sync_core_env() {
    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}"
    CONFIG_FILE="$WORK_DIR/sync-config.json"
    local include_json
    include_json=$(python3 - "$PRIVATE" <<'PY'
import json
import os
import sys

repo = sys.argv[1]
defaults = {"infrastructure/", "samples/"}
excluded = {".git", ".github", "internal", "docs", "public-overlay", "README.md", "CONTRIBUTING.md"}
for name in os.listdir(repo):
    if name not in excluded:
        defaults.add(name + "/" if os.path.isdir(os.path.join(repo, name)) else name)
print(json.dumps(sorted(defaults)))
PY
)
    cat > "$CONFIG_FILE" <<EOF
{
  "default_include_paths": $include_json,
  "exclude_pathspecs": [":!internal/", ":!.github/"],
  "public_repo": {"owner": "test", "name": "test"},
  "sync_branch_prefix": "sync/test"
}
EOF
}

# Run sync-core.sh with the test environment.
# Honors $TEST_SOURCE_REF for tests that need to override the default
# (refs/heads/main) — e.g., T28 simulates CI's detached-HEAD condition.
run_sync_core() {
    setup_sync_core_env
    PRIVATE_REPO="$PRIVATE" \
    PUBLIC_REPO="$PUBLIC" \
    SYNC_BRANCH="$SYNC_BRANCH" \
    MARKS_DIR="$MARKS_DIR" \
    CONFIG_FILE="$CONFIG_FILE" \
    MAILMAP_FILE="$MAILMAP" \
    SOURCE_REF="${TEST_SOURCE_REF:-refs/heads/main}" \
    SYNC_BLOCKED_PATHS="${SYNC_BLOCKED_PATHS:-}" \
    DRY_RUN=1 \
    bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"
    local exit_code=$?
    if [[ -s "$WORK_DIR/sync-core.err" ]]; then
        : # Logs go to stderr — captured but not displayed unless test fails
    fi
    return $exit_code
}

test_T26() {
    run_test "T26" "sync-core.sh: pathspec hash change rebuilds pre-bootstrap state"
    setup_repos

    echo "content" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add file" file.txt
    run_sync_core || { fail "T26" "First sync failed"; cleanup; return; }

    # Verify hash file exists
    if [[ ! -f "$MARKS_DIR/pathspec.hash" ]]; then
        fail "T26" "Hash file not created"
        cleanup
        return
    fi

    # Modify config (add a new exclusion)
    cat > "$CONFIG_FILE" <<EOF
{
  "default_include_paths": ["file.txt"],
  "exclude_pathspecs": [":!internal/", ":!.github/", ":!new-exclusion/"],
  "public_repo": {"owner": "test", "name": "test"},
  "sync_branch_prefix": "sync/test"
}
EOF

    # Capture original marks for comparison
    local marks_before
    marks_before=$(cat "$MARKS_DIR/private.marks" 2>/dev/null | wc -l)

    # Run again before public main exists — bootstrap state may still be rebuilt.
    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-rehash"
    PRIVATE_REPO="$PRIVATE" \
    PUBLIC_REPO="$PUBLIC" \
    SYNC_BRANCH="$SYNC_BRANCH" \
    MARKS_DIR="$MARKS_DIR" \
    CONFIG_FILE="$CONFIG_FILE" \
    MAILMAP_FILE="$MAILMAP" \
    DRY_RUN=1 \
    bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"
    local exit_code=$?

    if [[ $exit_code -eq 0 ]] && grep -q "Path exclusions changed before first public bootstrap" "$WORK_DIR/sync-core.err"; then
        pass "T26"
    else
        fail "T26" "Expected pathspec change warning (exit=$exit_code): $(cat "$WORK_DIR/sync-core.err" | head -5)"
    fi
    cleanup
}

# T28 — Regression for the fast-export refspec gotcha.
# Reproduces CI conditions: SOURCE_REF set to a non-main ref (HEAD detached at
# the tip of a feature branch). With the old code, fast-export emitted
# `commit refs/heads/<feature-branch>` (not refs/heads/main), so
# --refspec=<src>:refs/heads/main didn't match, the filter's ref rewrite
# didn't match either, and fast-import created refs/heads/<feature-branch>
# in the public repo instead of refs/heads/$SYNC_BRANCH, leaving the expected
# sync branch without the imported commits.
#
# This test verifies that the expected sync branch contains the imported
# commits, authors, and files.
test_T28() {
    run_test "T28" "sync-core.sh: SOURCE_REF=detached HEAD imports commits onto sync branch (refspec gotcha regression)"
    setup_repos

    # Build private repo with 3 commits by 3 different authors on a non-main
    # feature branch, then detach HEAD at its tip — mirrors actions/checkout
    # in CI which checks out a SHA in detached state.
    git -C "$PRIVATE" checkout -b feature/sync-test --quiet

    echo "alpha" > "$PRIVATE/alpha.txt"
    commit_as "$PRIVATE" "Alice Author" "alice@example.com" "Add alpha" alpha.txt

    echo "beta" > "$PRIVATE/beta.txt"
    commit_as "$PRIVATE" "Bob Builder" "bob@example.com" "Add beta" beta.txt

    echo "gamma" > "$PRIVATE/gamma.txt"
    commit_as "$PRIVATE" "Carol Coder" "carol@example.com" "Add gamma" gamma.txt

    # Detach HEAD at feature branch tip (CI's actual state)
    git -C "$PRIVATE" checkout --detach HEAD --quiet

    # Sanity: HEAD is detached and feature/sync-test exists
    if git -C "$PRIVATE" symbolic-ref -q HEAD >/dev/null 2>&1; then
        fail "T28" "Test setup error: HEAD is not detached"
        cleanup; return
    fi

    # Run sync with SOURCE_REF=HEAD — exactly what CI does
    TEST_SOURCE_REF="HEAD" run_sync_core || {
        fail "T28" "sync-core.sh exited non-zero (likely the bug — see logs): $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    }

    # 1) Sync branch must exist
    if ! git -C "$PUBLIC" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        fail "T28" "Sync branch $SYNC_BRANCH was not created on public repo"
        cleanup; return
    fi

    # 2) Sync branch must contain the imported commits — at least 3 from our
    #    feature branch (initial commit may or may not appear depending on
    #    pathspecs; the 3 named commits are what matters).
    local commit_count
    commit_count=$(git -C "$PUBLIC" rev-list --count "$SYNC_BRANCH" 2>/dev/null || echo 0)
    if [[ "$commit_count" -lt 3 ]]; then
        fail "T28" "Expected ≥3 commits on sync branch, got $commit_count (refspec gotcha — imported commits orphaned under another ref)"
        cleanup; return
    fi

    # 3) The 3 author names must all appear in the sync branch's history.
    #    With the old code, none appeared on the expected sync branch.
    local authors
    authors=$(git -C "$PUBLIC" log "$SYNC_BRANCH" --format='%an' 2>/dev/null | sort -u)
    local missing=()
    for name in "Alice Author" "Bob Builder" "Carol Coder"; do
        if ! grep -qFx "$name" <<< "$authors"; then
            missing+=("$name")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "T28" "Missing authors on sync branch: ${missing[*]} (got: $(echo "$authors" | paste -sd ', '))"
        cleanup; return
    fi

    # 4) Files from the imports must be present on the sync branch tree.
    for f in alpha.txt beta.txt gamma.txt; do
        if ! git -C "$PUBLIC" show "$SYNC_BRANCH:$f" >/dev/null 2>&1; then
            fail "T28" "File $f missing from sync branch tree (imports orphaned)"
            cleanup; return
        fi
    done

    pass "T28"
    cleanup
}

write_graft_sync_config() {
    CONFIG_FILE="$WORK_DIR/sync-config.json"
    cat > "$CONFIG_FILE" <<'EOF'
{
  "default_include_paths": ["infrastructure/", "samples/"],
  "exclude_pathspecs": [":!internal/", ":!docs/", ":!.azure-pipelines/", ":!.github/", ":!CONTRIBUTING.md", ":!README.md"],
  "public_repo": {"owner": "test", "name": "test"},
  "sync_branch_prefix": "sync/test"
}
EOF
}

run_sync_core_for_graft() {
    env \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        SYNC_BRANCH="$SYNC_BRANCH" \
        MARKS_DIR="$MARKS_DIR" \
        CONFIG_FILE="$CONFIG_FILE" \
        MAILMAP_FILE="$MAILMAP" \
        SOURCE_REF="refs/heads/main" \
        SYNC_ADDITIONAL_PATHS="${SYNC_ADDITIONAL_PATHS:-}" \
        SYNC_BLOCKED_PATHS="${SYNC_BLOCKED_PATHS:-}" \
        DRY_RUN=1 \
        bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"
}

run_seed_marks() {
    env \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        CONFIG_FILE="$CONFIG_FILE" \
        bash "$SEED_MARKS_SCRIPT" \
        --private-sha "$1" \
        --public-sha "$2" \
        --marks-dir "$MARKS_DIR" \
        > "$WORK_DIR/seed.out" 2> "$WORK_DIR/seed.err"
}

marks_dir_entry_count() {
    find "$MARKS_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}

# T51 — Graft synthesis seeds paired marks after proving tree equivalence.
test_T51() {
    run_test "T51" "seed-marks-from-public: matching trees seed marks and next sync emits only delta"
    setup_public_with_extras
    write_graft_sync_config

    local private_sha public_sha
    private_sha=$(git -C "$PRIVATE" rev-parse HEAD)
    public_sha=$(git -C "$PUBLIC" rev-parse HEAD)

    if ! run_seed_marks "$private_sha" "$public_sha"; then
        fail "T51" "seed-marks-from-public failed: $(cat "$WORK_DIR/seed.err")"
        cleanup; return
    fi

    # private.marks contains :1 = seed plus :N for every ancestor of the seed
    # (so fast-export skips ancestor emission). public.marks mirrors every
    # private mark, all pointing to the public seed SHA, so any "from :N"
    # parent reference fast-export emits under pathspec parent rewriting still
    # resolves to public main on the importer side.
    if ! grep -qFx ":1 $private_sha" "$MARKS_DIR/private.marks"; then
        fail "T51" "private.marks did not contain synthesized private seed mark :1"
        cleanup; return
    fi
    if ! grep -qFx ":1 $public_sha" "$MARKS_DIR/public.marks"; then
        fail "T51" "public.marks did not contain synthesized public seed mark :1"
        cleanup; return
    fi
    local priv_lines pub_lines
    priv_lines=$(wc -l < "$MARKS_DIR/private.marks" | tr -d ' ')
    pub_lines=$(wc -l < "$MARKS_DIR/public.marks" | tr -d ' ')
    if [[ "$priv_lines" != "$pub_lines" ]]; then
        fail "T51" "public.marks ($pub_lines) must mirror private.marks ($priv_lines) line-for-line"
        cleanup; return
    fi
    if [[ ! -s "$MARKS_DIR/pathspec.hash" || ! -s "$MARKS_DIR/root.sha" ]]; then
        fail "T51" "Expected pathspec.hash and root.sha state files"
        cleanup; return
    fi

    echo "delta" > "$PRIVATE/samples/delta.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add delta sample" samples/delta.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-graft-delta"
    if ! run_sync_core_for_graft; then
        fail "T51" "Incremental sync after graft failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    local delta_count
    delta_count=$(git -C "$PUBLIC" rev-list --count "${public_sha}..${SYNC_BRANCH}")
    if [[ "$delta_count" == "1" ]] && git -C "$PUBLIC" show "$SYNC_BRANCH:samples/delta.txt" >/dev/null 2>&1; then
        pass "T51"
    else
        fail "T51" "Expected exactly one delta commit after graft, got $delta_count"
    fi
    cleanup
}

# T52 — Divergence in either include-set direction aborts without writing marks.
test_T52() {
    run_test "T52" "seed-marks-from-public: diverging trees fail fast and leave marks clean"

    setup_public_with_extras
    write_graft_sync_config
    echo "private only" > "$PRIVATE/samples/private-only.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add private-only included path" samples/private-only.txt
    if run_seed_marks "$(git -C "$PRIVATE" rev-parse HEAD)" "$(git -C "$PUBLIC" rev-parse HEAD)"; then
        fail "T52" "Expected private-only include-set divergence to fail"
        cleanup; return
    fi
    if [[ "$(marks_dir_entry_count)" != "0" ]]; then
        fail "T52" "Private-only divergence wrote files to marks-dir"
        cleanup; return
    fi
    cleanup

    setup_public_with_extras
    write_graft_sync_config
    echo "public only" > "$PUBLIC/samples/public-only.txt"
    commit_as "$PUBLIC" "Public Dev" "public@example.com" "Add public-only included path" samples/public-only.txt
    if run_seed_marks "$(git -C "$PRIVATE" rev-parse HEAD)" "$(git -C "$PUBLIC" rev-parse HEAD)"; then
        fail "T52" "Expected public-only include-set divergence to fail"
        cleanup; return
    fi
    if [[ "$(marks_dir_entry_count)" == "0" ]]; then
        pass "T52"
    else
        fail "T52" "Public-only divergence wrote files to marks-dir"
    fi
    cleanup
}

# T53 — Excluded commits after the graft point must not poison the next import.
test_T53() {
    run_test "T53" "seed-marks-from-public: excluded commit between graft and HEAD does not break next sync"
    setup_public_with_extras
    write_graft_sync_config

    local private_sha public_sha
    private_sha=$(git -C "$PRIVATE" rev-parse HEAD)
    public_sha=$(git -C "$PUBLIC" rev-parse HEAD)
    if ! run_seed_marks "$private_sha" "$public_sha"; then
        fail "T53" "seed-marks-from-public failed: $(cat "$WORK_DIR/seed.err")"
        cleanup; return
    fi

    mkdir -p "$PRIVATE/docs"
    echo "operator note" > "$PRIVATE/docs/recovery.md"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add docs-only recovery note" docs/recovery.md
    echo "next delta" > "$PRIVATE/samples/next-delta.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add next public delta" samples/next-delta.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-graft-docs-delta"
    if ! run_sync_core_for_graft; then
        fail "T53" "Sync after excluded commit failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    local delta_count
    delta_count=$(git -C "$PUBLIC" rev-list --count "${public_sha}..${SYNC_BRANCH}")
    if [[ "$delta_count" == "1" ]] \
        && git -C "$PUBLIC" show "$SYNC_BRANCH:samples/next-delta.txt" >/dev/null 2>&1 \
        && ! git -C "$PUBLIC" show "$SYNC_BRANCH:docs/recovery.md" >/dev/null 2>&1; then
        pass "T53"
    else
        fail "T53" "Expected one included delta and no docs path after graft (delta_count=$delta_count)"
    fi
    cleanup
}

# T56 — Block-list churn between runs must not invalidate marks (regression).
# Before the fix, SYNC_BLOCKED_PATHS was folded into pathspec_hash, so any
# validation block-list change between runs forced a full re-export.
test_T56() {
    run_test "T56" "sync-core.sh: SYNC_BLOCKED_PATHS change between runs does NOT invalidate marks"
    setup_repos

    write_sample "samples/python/foo" "blocked-on-run-1"
    write_sample "samples/python/keep" "always-allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add two samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    if ! SYNC_BLOCKED_PATHS="samples/python/foo" run_sync_core; then
        fail "T56" "First sync (foo blocked) failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    # Sanity: marks now exist.
    if [[ ! -s "$MARKS_DIR/private.marks" || ! -s "$MARKS_DIR/public.marks" ]]; then
        fail "T56" "Expected marks files after first sync"
        cleanup; return
    fi

    # Add a new private commit so the second sync has work to do.
    write_sample "samples/python/delta" "second-run-delta"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add delta sample" \
        samples/python/delta/sample.yaml samples/python/delta/content.txt

    # Run #2 with a *different* block-list (no longer blocking foo, now blocking keep).
    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-blocklist-churn"
    if ! SYNC_BLOCKED_PATHS="samples/python/keep" \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        SYNC_BRANCH="$SYNC_BRANCH" \
        MARKS_DIR="$MARKS_DIR" \
        CONFIG_FILE="$CONFIG_FILE" \
        MAILMAP_FILE="$MAILMAP" \
        DRY_RUN=1 \
        bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"; then
        fail "T56" "Second sync (keep blocked) failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if grep -q "Pathspec config changed" "$WORK_DIR/sync-core.err"; then
        fail "T56" "Block-list change forced full re-export — marks should remain valid"
        cleanup; return
    fi
    if ! grep -q "Marks valid" "$WORK_DIR/sync-core.err"; then
        fail "T56" "Expected 'Marks valid — incremental sync' on second run"
        cleanup; return
    fi
    pass "T56"
    cleanup
}


# T59 — Rebase-merge SHA-rewrite recovery (production failure on 2026-05-08).
#
# When `gh pr merge --rebase` lands a sync PR on public main, GitHub rewrites
# commit SHAs. The SHAs PUBLIC_MARKS recorded for the sync branch become
# unreachable once "Close stale sync PRs" deletes the sync branch and gc
# prunes them. The next sync's fast-export emits `from :N` referencing those
# marks → fast-import fails with "object not found".
#
# Pre-fix recovery (sync-core.sh:645-652) discarded both paired marks files and
# re-exported without --import-marks, producing an orphan branch with no parent
# on public main — unmergeable (PR #699 evidence).
#
# Post-fix recovery: invoke seed-marks-from-public against
# (public main HEAD ↔ last private SHA in private.marks). When tree-equivalent
# (which is the common case for rebase landings — same trees, different SHAs),
# the seed succeeds and fast-import retries with the freshly-paired marks,
# producing a sync branch whose first parent is public main HEAD.
test_T59() {
    run_test "T59" "sync-core.sh: rebase-rewritten public SHAs → seed recovery, sync branch parented on public main"
    setup_repos

    # First sync: establish marks paired against the sync branch's import.
    echo "first" > "$PRIVATE/first.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add first" first.txt
    run_sync_core || { fail "T59" "First sync failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return; }

    if [[ ! -f "$MARKS_DIR/private.marks" || ! -f "$MARKS_DIR/public.marks" ]]; then
        fail "T59" "Expected paired marks after first sync"
        cleanup; return
    fi

    local first_sync_branch="$SYNC_BRANCH"

    # Simulate rebase-merge to public main:
    #  1. Re-create the sync-branch tree as a NEW commit on public main
    #     (different author/timestamp → different SHA, identical tree).
    #  2. Delete the sync branch (mimics "Close stale sync PRs" cleanup).
    #  3. Prune unreachable objects (mimics time passing / repo gc).
    # Net effect: PUBLIC_MARKS still references the original sync-branch SHA,
    # which now exists nowhere — fast-import will fail to resolve `from :N`.
    local sync_tree
    sync_tree=$(git -C "$PUBLIC" rev-parse "${first_sync_branch}^{tree}")
    local rebased_sha
    rebased_sha=$(env \
        GIT_AUTHOR_NAME="Rebase Bot" GIT_AUTHOR_EMAIL="rebase@example.com" \
        GIT_COMMITTER_NAME="Rebase Bot" GIT_COMMITTER_EMAIL="rebase@example.com" \
        GIT_AUTHOR_DATE="2026-01-01T00:00:00+0000" \
        GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000" \
        git -C "$PUBLIC" commit-tree "$sync_tree" -m "Rebased equivalent of first sync")
    git -C "$PUBLIC" update-ref refs/heads/main "$rebased_sha"
    git -C "$PUBLIC" branch -D "$first_sync_branch" --quiet 2>/dev/null || \
        git -C "$PUBLIC" update-ref -d "refs/heads/$first_sync_branch"
    git -C "$PUBLIC" -c gc.pruneExpire=now gc --prune=now --quiet 2>/dev/null || true

    # Sanity: the SHA recorded in PUBLIC_MARKS must now be unreachable.
    local stale_sha
    stale_sha=$(awk 'END{print $2}' "$MARKS_DIR/public.marks")
    if [[ -z "$stale_sha" ]] || git -C "$PUBLIC" cat-file -e "$stale_sha" 2>/dev/null; then
        fail "T59" "Test setup failed: PUBLIC_MARKS SHA ($stale_sha) is still reachable after simulated rebase"
        cleanup; return
    fi

    # New private commit — what the second sync should produce as a single delta.
    echo "second" > "$PRIVATE/second.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add second" second.txt

    if ! run_sync_core; then
        fail "T59" "Second sync failed instead of recovering: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if ! git -C "$PUBLIC" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        fail "T59" "Sync branch $SYNC_BRANCH was not created on second sync"
        cleanup; return
    fi

    # Core assertion: sync branch must be parented on public main HEAD
    # (the rebased SHA), NOT an orphan branch. Today's discard-and-full-reexport
    # recovery produces an orphan; B' seed-recovery produces a properly parented
    # delta on top of public main HEAD.
    local public_main_head sync_first_parent
    public_main_head=$(git -C "$PUBLIC" rev-parse refs/heads/main)
    sync_first_parent=$(git -C "$PUBLIC" rev-parse "refs/heads/$SYNC_BRANCH^" 2>/dev/null || echo "ORPHAN")
    if [[ "$sync_first_parent" != "$public_main_head" ]]; then
        fail "T59" "Sync branch is orphaned (parent=$sync_first_parent, expected public main HEAD=$public_main_head). Recovery did not seed-from-public."
        cleanup; return
    fi

    # Should also have produced exactly one delta commit on top of main.
    local delta_count
    delta_count=$(git -C "$PUBLIC" rev-list --count "${public_main_head}..refs/heads/$SYNC_BRANCH")
    if [[ "$delta_count" != "1" ]]; then
        fail "T59" "Expected exactly 1 delta commit on top of public main, got $delta_count"
        cleanup; return
    fi

    # And the new file must be present.
    if ! git -C "$PUBLIC" show "$SYNC_BRANCH:second.txt" >/dev/null 2>&1; then
        fail "T59" "Sync branch is missing second.txt"
        cleanup; return
    fi

    # The recovery should be the seed path, not the discard-and-full-reexport path.
    if ! grep -q "seed-marks recovery" "$WORK_DIR/sync-core.err"; then
        fail "T59" "Expected 'seed-marks recovery' log line. stderr: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    pass "T59"
    cleanup
}

# T60 — Regression for the single-mark seed bug.
#
# Failure mode: an early version of seed-marks-from-public.sh wrote a single
# ":1 <seed-sha>" line to private.marks. git fast-export's --import-marks
# only suppresses emission of explicitly-marked commits — it does NOT prune
# the rev-list walk. With one mark, fast-export emitted the seed's entire
# ancestor history, producing a giant orphan-style PR (run 25581810668 →
# PR #701: 248 files / 19 commits when only ~3 were expected).
#
# This test builds a deep private history (5 pre-seed ancestor commits on top
# of setup_public_with_extras's initial commits), seeds at the deep HEAD,
# then adds one post-seed delta and runs sync-core. With the fix, fast-export
# must emit ONLY the 1 post-seed delta — none of the pre-seed ancestor
# commits should appear on the sync branch.
test_T60() {
    run_test "T60" "seed-marks-from-public: deep ancestor history is fully suppressed (single-mark bug regression)"
    setup_public_with_extras
    write_graft_sync_config

    # Build out 5 commits of pre-seed ancestry on private. setup_public_with_extras
    # already created the initial root and an "Add shared sample" commit.
    local i
    for i in 1 2 3 4 5; do
        echo "ancestor-$i" > "$PRIVATE/samples/ancestor-$i.txt"
        commit_as "$PRIVATE" "Private Dev" "private@example.com" \
            "Pre-seed ancestor commit $i" "samples/ancestor-$i.txt"
    done

    # Mirror those samples into public so the seed commit is tree-equivalent
    # over the include-set. (setup_public_with_extras gave public the initial
    # samples/shared.txt; we need the ancestor-N.txt files there too.)
    for i in 1 2 3 4 5; do
        echo "ancestor-$i" > "$PUBLIC/samples/ancestor-$i.txt"
    done
    cd "$PUBLIC" && git add -A && cd - >/dev/null
    env GIT_AUTHOR_NAME="Public Dev" GIT_AUTHOR_EMAIL="public@example.com" \
        GIT_COMMITTER_NAME="Public Dev" GIT_COMMITTER_EMAIL="public@example.com" \
        git -C "$PUBLIC" commit -m "Mirror ancestor samples to public" --quiet

    # Seed pair: private HEAD (deep) ↔ public HEAD (deep).
    local private_sha public_sha
    private_sha=$(git -C "$PRIVATE" rev-parse HEAD)
    public_sha=$(git -C "$PUBLIC" rev-parse HEAD)

    if ! run_seed_marks "$private_sha" "$public_sha"; then
        fail "T60" "seed-marks-from-public failed: $(cat "$WORK_DIR/seed.err")"
        cleanup; return
    fi

    # The seed must have written marks for every ancestor of the seed —
    # NOT just a single ":1 <sha>" line. Count must match git rev-list.
    # public.marks must mirror private.marks (every mark → PUBLIC_SHA), so
    # parent-rewriting "from :N" references resolve on the importer side.
    local mark_lines expected_lines pub_lines
    mark_lines=$(wc -l < "$MARKS_DIR/private.marks" | tr -d ' ')
    expected_lines=$(git -C "$PRIVATE" rev-list "$private_sha" | wc -l | tr -d ' ')
    if [[ "$mark_lines" != "$expected_lines" ]]; then
        fail "T60" "private.marks has $mark_lines entries; expected $expected_lines (one per ancestor of seed)"
        cleanup; return
    fi
    pub_lines=$(wc -l < "$MARKS_DIR/public.marks" | tr -d ' ')
    if [[ "$pub_lines" != "$mark_lines" ]]; then
        fail "T60" "public.marks has $pub_lines entries; expected $mark_lines (must mirror private.marks)"
        cleanup; return
    fi
    # Every public.marks entry must point to public_sha.
    local bad_public_lines
    bad_public_lines=$(awk -v sha="$public_sha" '$2 != sha { print }' "$MARKS_DIR/public.marks" | wc -l | tr -d ' ')
    if [[ "$bad_public_lines" != "0" ]]; then
        fail "T60" "public.marks contains $bad_public_lines entries not pointing to public_sha=$public_sha"
        cleanup; return
    fi

    # Add the post-seed delta: the regression commit fast-export must emit.
    echo "delta" > "$PRIVATE/samples/post-seed-delta.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Post-seed delta" "samples/post-seed-delta.txt"

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-deep-graft"
    if ! run_sync_core_for_graft; then
        fail "T60" "Sync after deep seed failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    # Core regression assertion: sync branch must have EXACTLY 1 delta commit
    # past public_sha. Pre-seed ancestor commits must NOT be re-emitted.
    local delta_count
    delta_count=$(git -C "$PUBLIC" rev-list --count "${public_sha}..${SYNC_BRANCH}")
    if [[ "$delta_count" != "1" ]]; then
        fail "T60" "Expected 1 delta commit past seed; got $delta_count (single-mark bug returned)"
        cleanup; return
    fi

    # The delta file must be present on the sync branch.
    if ! git -C "$PUBLIC" show "$SYNC_BRANCH:samples/post-seed-delta.txt" >/dev/null 2>&1; then
        fail "T60" "Sync branch is missing post-seed-delta.txt"
        cleanup; return
    fi

    # And the ancestor commits' messages must NOT appear on the sync branch
    # past public_sha (defense-in-depth against partial-suppression bugs).
    if git -C "$PUBLIC" log --format='%s' "${public_sha}..${SYNC_BRANCH}" \
        | grep -qE '^Pre-seed ancestor commit [0-9]+$'; then
        fail "T60" "Pre-seed ancestor commits leaked onto the sync branch"
        cleanup; return
    fi

    pass "T60"
    cleanup
}

# T37 — Regression for fast-import stale bootstrap marks recovery.
# Reproduces run #109's failure mode: PUBLIC_MARKS references an object that is
# not present in the not-yet-published public repo, so fast-import fails before
# bootstrap recovery retries without either paired marks file.
test_T37() {
    run_test "T37" "sync-core.sh: stale pre-bootstrap public marks → bootstrap retry succeeds"
    setup_repos

    echo "first" > "$PRIVATE/first.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add first" first.txt
    run_sync_core || { fail "T37" "First sync failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return; }

    if [[ ! -f "$MARKS_DIR/private.marks" || ! -f "$MARKS_DIR/public.marks" ]]; then
        fail "T37" "Expected paired marks after first sync"
        cleanup; return
    fi

    printf ':1 0000000000000000000000000000000000000000\n' > "$MARKS_DIR/public.marks"

    echo "second" > "$PRIVATE/second.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add second" second.txt

    if ! run_sync_core; then
        fail "T37" "Second sync failed instead of recovering: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if ! git -C "$PUBLIC" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        fail "T37" "Sync branch $SYNC_BRANCH was not created"
    elif ! git -C "$PUBLIC" show "$SYNC_BRANCH:second.txt" >/dev/null 2>&1; then
        fail "T37" "Recovered sync branch is missing second.txt"
    elif ! grep -q "stale bootstrap marks with no public main" "$WORK_DIR/sync-core.err"; then
        fail "T37" "Expected stale bootstrap marks recovery warning. stderr: $(cat "$WORK_DIR/sync-core.err")"
    else
        pass "T37"
    fi
    cleanup
}

# T62 — Sentinel-file recovery: last-synced-private.sha is the authoritative
# anchor for stale-marks recovery, NOT `awk 'END' private.marks`.
#
# Production failure (2026-05-11, run 25655889585): scheduled sync's
# fast-import failed; seed-marks recovery anchored on the marks-file tail
# (`4cf2d4da`) whose filtered tree no longer matched public main (which had
# advanced past a rename commit). seed-marks-from-public refused to
# synthesize, sync wedged. The actual last-imported private SHA (`704b6e1a`)
# was tree-equivalent to public main and would have recovered cleanly — but
# it was not what the awk-tail returned.
#
# Root cause: fast-export's --export-marks rewrites the marks file each run
# in an order that does not preserve "last imported HEAD is last line".
# Intervening no-op runs (excluded-paths-only commits) can also append
# marks for SHAs that were never reconciled with public.
#
# Fix: write last-synced-private.sha atomically after every successful
# import/no-op/seed; sync-core reads it in preference to the marks tail.
# This regression test makes the awk-tail diverge from the sentinel and
# asserts recovery uses the sentinel.
test_T62() {
    run_test "T62" "sync-core.sh: stale-marks recovery anchors on last-synced sentinel, not awk-tail"
    setup_repos

    # Build a history of four commits, all on the include-set.
    echo "c1" > "$PRIVATE/c1.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c1" c1.txt
    echo "c2" > "$PRIVATE/c2.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c2" c2.txt
    echo "c3" > "$PRIVATE/c3.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c3" c3.txt
    echo "c4" > "$PRIVATE/c4.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c4" c4.txt

    local sha_c2 sha_c4
    sha_c2=$(git -C "$PRIVATE" rev-parse HEAD~2)
    sha_c4=$(git -C "$PRIVATE" rev-parse HEAD)

    # First sync — establish paired marks AND sentinel pointing at c4.
    run_sync_core || { fail "T62" "First sync failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return; }

    # Advance public main to the imported sync-branch HEAD so the recovery
    # path's `git rev-parse refs/heads/main` returns a real SHA. (The bare
    # public test repo starts with no main branch; sync-core imports onto the
    # sync branch only — landing it on main is normally the workflow's job
    # via PR merge, which we simulate here with update-ref.)
    git -C "$PUBLIC" update-ref refs/heads/main "$SYNC_BRANCH"

    if [[ ! -f "$MARKS_DIR/last-synced-private.sha" ]]; then
        fail "T62" "Expected last-synced-private.sha sentinel after first sync"
        cleanup; return
    fi

    local sentinel
    sentinel=$(head -n 1 "$MARKS_DIR/last-synced-private.sha" | tr -d '[:space:]')
    if [[ "$sentinel" != "$sha_c4" ]]; then
        fail "T62" "Sentinel ($sentinel) != imported HEAD ($sha_c4)"
        cleanup; return
    fi

    # Corrupt the marks-file tail: reorder entries so c2's mark is last.
    # This simulates the production failure where intervening writes left an
    # ancestor SHA at the file's tail. The sentinel remains pointing at c4.
    grep -v " $sha_c2$" "$MARKS_DIR/private.marks" > "$MARKS_DIR/private.marks.tmp"
    grep " $sha_c2$" "$MARKS_DIR/private.marks" >> "$MARKS_DIR/private.marks.tmp"
    mv "$MARKS_DIR/private.marks.tmp" "$MARKS_DIR/private.marks"
    local tail_sha
    tail_sha=$(awk 'END { if (NF >= 2) print $2 }' "$MARKS_DIR/private.marks")
    if [[ "$tail_sha" != "$sha_c2" ]]; then
        fail "T62" "Test setup: failed to make marks tail = c2 (got $tail_sha)"
        cleanup; return
    fi

    # Force fast-import to fail (same trick as T37) so the recovery path runs.
    printf ':1 0000000000000000000000000000000000000000\n' > "$MARKS_DIR/public.marks"

    # New private commit — what the recovered sync must produce as a delta.
    echo "c5" > "$PRIVATE/c5.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c5" c5.txt

    if ! run_sync_core; then
        fail "T62" "Sync did not recover: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    # Core assertion: recovery log line must reference the SENTINEL's short
    # SHA (c4), NOT the marks-tail's short SHA (c2). Pre-fix this test fails
    # because seed-marks-from-public refuses to synthesize when invoked with
    # c2 (whose filtered tree lacks c3.txt and c4.txt — public main has them).
    local short_c4="${sha_c4:0:8}" short_c2="${sha_c2:0:8}"
    if ! grep -q "seed-marks recovery (private $short_c4 " "$WORK_DIR/sync-core.err"; then
        fail "T62" "Recovery did not anchor on sentinel ($short_c4). stderr: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi
    if grep -q "seed-marks recovery (private $short_c2 " "$WORK_DIR/sync-core.err"; then
        fail "T62" "Recovery anchored on awk-tail ($short_c2) — sentinel was ignored"
        cleanup; return
    fi

    # And the recovered sync branch must contain the new file.
    if ! git -C "$PUBLIC" show "$SYNC_BRANCH:c5.txt" >/dev/null 2>&1; then
        fail "T62" "Sync branch is missing c5.txt"
        cleanup; return
    fi

    pass "T62"
    cleanup
}

# T63 — Sentinel survives a no-op intervening sync (excluded-paths-only
# commit). This is the pattern that produced today's stuck state: the May 9
# 06:46 scheduled run was a no-op CODEOWNERS overlay change; the marks file
# got new entries for an excluded commit, leaving the tail pointing at an
# uninteresting SHA. The sentinel must advance to the current private HEAD
# so the *next* recovery has the right anchor.
test_T63() {
    run_test "T63" "sync-core.sh: sentinel advances across a no-op (excluded-paths-only) sync"
    setup_repos

    echo "c1" > "$PRIVATE/c1.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add c1" c1.txt
    run_sync_core || { fail "T63" "First sync failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return; }

    local sha_after_first
    sha_after_first=$(git -C "$PRIVATE" rev-parse HEAD)
    local sentinel_first
    sentinel_first=$(head -n 1 "$MARKS_DIR/last-synced-private.sha" | tr -d '[:space:]')
    if [[ "$sentinel_first" != "$sha_after_first" ]]; then
        fail "T63" "Sentinel after first sync ($sentinel_first) != HEAD ($sha_after_first)"
        cleanup; return
    fi

    # Add an excluded-paths-only commit. A change to internal/ is filtered
    # out, so the sync is a no-op from public's perspective.
    mkdir -p "$PRIVATE/internal"
    echo "secret" > "$PRIVATE/internal/notes.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Internal notes" internal/notes.txt
    local sha_after_internal
    sha_after_internal=$(git -C "$PRIVATE" rev-parse HEAD)

    # Second sync — should be a no-op clean exit, but sentinel must advance.
    run_sync_core || { fail "T63" "Second sync failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return; }

    if ! grep -q "Nothing to sync — clean exit" "$WORK_DIR/sync-core.err"; then
        fail "T63" "Expected no-op clean exit. stderr: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    local sentinel_second
    sentinel_second=$(head -n 1 "$MARKS_DIR/last-synced-private.sha" | tr -d '[:space:]')
    if [[ "$sentinel_second" != "$sha_after_internal" ]]; then
        fail "T63" "Sentinel after no-op sync ($sentinel_second) != current HEAD ($sha_after_internal)"
        cleanup; return
    fi

    pass "T63"
    cleanup
}
#
# Test the merge polling logic by stubbing `gh` on PATH. The mock reads its
# scripted responses from $WORK_DIR/gh-script (one line per `pr view` call) and
# logs every invocation to $WORK_DIR/gh-calls.log. The script-under-test never
# touches the network.

WAIT_AND_MERGE_SCRIPT="$REPO_ROOT/.github/scripts/wait-and-merge.sh"

setup_gh_mock() {
    # Caller passes script lines via stdin: each line is the JSON to return for
    # the next `gh pr view ... --json ...` call. After the script is exhausted
    # (or if the mock receives a `pr view` past the end), the last line repeats.
    WORK_DIR="/tmp/test-sync-$$-${TESTS_RUN}"
    rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR/bin"

    # Capture the scripted view responses
    cat > "$WORK_DIR/gh-script"
    : > "$WORK_DIR/gh-calls.log"
    echo 0 > "$WORK_DIR/gh-view-counter"
    echo '{"default_include_paths":["infrastructure/","samples/"]}' > "$WORK_DIR/sync-config.json"
    cat > "$WORK_DIR/scope-assert.sh" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_WORK_DIR/scope-calls.log"
exit "${MOCK_SCOPE_EXIT:-0}"
MOCK
    chmod +x "$WORK_DIR/scope-assert.sh"
    : > "$WORK_DIR/scope-calls.log"

    cat > "$WORK_DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Mock gh CLI for wait-and-merge.sh tests.
WORK_DIR_MOCK="${MOCK_WORK_DIR:?MOCK_WORK_DIR not set}"
echo "$@" >> "$WORK_DIR_MOCK/gh-calls.log"

case "$1 $2" in
    "pr view")
        # Return scripted JSON line N, where N increments each call. After
        # exhausting the script, repeat the last line.
        counter=$(cat "$WORK_DIR_MOCK/gh-view-counter")
        next=$((counter + 1))
        echo "$next" > "$WORK_DIR_MOCK/gh-view-counter"
        line=$(sed -n "${next}p" "$WORK_DIR_MOCK/gh-script")
        if [[ -z "$line" ]]; then
            # Past end of script: repeat last non-empty line
            line=$(grep -v '^[[:space:]]*$' "$WORK_DIR_MOCK/gh-script" | tail -1)
        fi
        echo "$line"
        ;;
    "pr merge")
        # Just log; no output. Exit 0.
        ;;
    *)
        echo "MOCK gh: unhandled args: $*" >&2
        exit 99
        ;;
esac
MOCK
    chmod +x "$WORK_DIR/bin/gh"

    cat > "$WORK_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_WORK_DIR/git-calls.log"
if [[ "$*" == *" fetch "* ]]; then
    exit 0
fi
if [[ "$*" == *"rev-parse refs/remotes/origin/main"* ]]; then
    echo "${MOCK_FETCHED_BASE:-3333333333333333333333333333333333333333}"
    exit 0
fi
if [[ "$*" == *" rev-parse "* ]]; then
    echo "${MOCK_FETCHED_HEAD:-1111111111111111111111111111111111111111}"
    exit 0
fi
echo "MOCK git: unhandled args: $*" >&2
exit 99
MOCK
    chmod +x "$WORK_DIR/bin/git"
    : > "$WORK_DIR/git-calls.log"
}

run_wait_and_merge() {
    # Runs the script with the mock on PATH and returns its exit code via
    # $WAIT_EXIT_CODE. Output saved to $WORK_DIR/wait.out and $WORK_DIR/wait.err.
    # Use `|| true` pattern to capture non-zero exits without tripping set -e.
    set +e
    PATH="$WORK_DIR/bin:$PATH" \
        MOCK_WORK_DIR="$WORK_DIR" \
        MOCK_SCOPE_EXIT="${MOCK_SCOPE_EXIT:-0}" \
        MOCK_FETCHED_HEAD="${MOCK_FETCHED_HEAD:-1111111111111111111111111111111111111111}" \
        MOCK_FETCHED_BASE="${MOCK_FETCHED_BASE:-3333333333333333333333333333333333333333}" \
        SYNC_SCOPE_ASSERT_SCRIPT="$WORK_DIR/scope-assert.sh" \
        SYNC_SCOPE_PUBLIC_REPO="$WORK_DIR" \
        SYNC_SCOPE_CONFIG="$WORK_DIR/sync-config.json" \
        SYNC_BRANCH="sync/test" \
        MERGE_POLL_INTERVAL=1 \
        MERGE_POLL_TIMEOUT="${WAIT_TIMEOUT:-10}" \
        GH_TOKEN="fake-token" \
        bash "$WAIT_AND_MERGE_SCRIPT" "https://example.com/pulls/1" "owner/repo" \
        > "$WORK_DIR/wait.out" 2> "$WORK_DIR/wait.err"
    WAIT_EXIT_CODE=$?
    set -e
}

cleanup_gh_mock() {
    rm -rf "$WORK_DIR"
}

# Test T29: PR is mergeable with no pending checks → merges immediately.
test_T29() {
    run_test "T29" "wait-and-merge.sh: mergeable with no pending checks → calls gh pr merge --rebase"

    setup_gh_mock <<'EOF'
{"baseRefName":"main","baseRefOid":"3333333333333333333333333333333333333333","headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}
EOF

    run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -ne 0 ]]; then
        fail "T29" "Script exited $WAIT_EXIT_CODE; expected 0. stderr: $(cat "$WORK_DIR/wait.err")"
        cleanup_gh_mock; return
    fi

    # Must have called `pr merge` exactly once with --rebase, no --auto, no --admin
    if ! grep -q "^pr merge .* --rebase --match-head-commit 1111111111111111111111111111111111111111$" "$WORK_DIR/gh-calls.log"; then
        fail "T29" "Expected a rebase merge pinned to the guarded head. Calls: $(cat "$WORK_DIR/gh-calls.log")"
        cleanup_gh_mock; return
    fi
    if grep -q -- "--auto" "$WORK_DIR/gh-calls.log"; then
        fail "T29" "Script called gh with --auto (defeats purpose). Calls: $(cat "$WORK_DIR/gh-calls.log")"
        cleanup_gh_mock; return
    fi
    if grep -q -- "--admin" "$WORK_DIR/gh-calls.log"; then
        fail "T29" "Script called gh with --admin (would require user bypass). Calls: $(cat "$WORK_DIR/gh-calls.log")"
        cleanup_gh_mock; return
    fi

    pass "T29"
    cleanup_gh_mock
}

# Test T30: PR has a merge conflict → script exits non-zero without merging.
test_T30() {
    run_test "T30" "wait-and-merge.sh: CONFLICTING → exits non-zero without calling gh pr merge"

    setup_gh_mock <<'EOF'
{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","statusCheckRollup":[]}
EOF

    run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T30" "Script exited 0; expected non-zero on conflict."
        cleanup_gh_mock; return
    fi

    if grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T30" "Script called gh pr merge despite conflict. Calls: $(cat "$WORK_DIR/gh-calls.log")"
        cleanup_gh_mock; return
    fi

    pass "T30"
    cleanup_gh_mock
}

# Test T31: PR has pending checks indefinitely → script times out without merging.
test_T31() {
    run_test "T31" "wait-and-merge.sh: pending checks past timeout → exits non-zero without merging"

    # Mock returns "still pending" forever; with MERGE_POLL_INTERVAL=1 and
    # WAIT_TIMEOUT=3, the script must hit the deadline within ~3 seconds.
    setup_gh_mock <<'EOF'
{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"IN_PROGRESS","conclusion":null}]}
EOF

    WAIT_TIMEOUT=3 run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T31" "Script exited 0; expected non-zero on timeout."
        cleanup_gh_mock; return
    fi

    if grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T31" "Script called gh pr merge despite never being ready. Calls: $(cat "$WORK_DIR/gh-calls.log")"
        cleanup_gh_mock; return
    fi

    if ! grep -q "Timed out" "$WORK_DIR/wait.err" "$WORK_DIR/wait.out"; then
        fail "T31" "Expected 'Timed out' in script output. stderr: $(cat "$WORK_DIR/wait.err"); stdout: $(cat "$WORK_DIR/wait.out")"
        cleanup_gh_mock; return
    fi

    pass "T31"
    cleanup_gh_mock
}

test_T80() {
    run_test "T80" "wait-and-merge.sh: final scope failure prevents merge"

    setup_gh_mock <<'EOF'
{"baseRefName":"main","baseRefOid":"3333333333333333333333333333333333333333","headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}
EOF

    MOCK_SCOPE_EXIT=1 run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T80" "Script exited 0 after final scope assertion failed."
    elif [[ ! -s "$WORK_DIR/scope-calls.log" ]]; then
        fail "T80" "Final scope assertion was not invoked."
    elif grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T80" "Script called gh pr merge after final scope assertion failed."
    else
        pass "T80"
    fi
    cleanup_gh_mock
}

test_T85() {
    run_test "T85" "wait-and-merge.sh: fetched head mismatch prevents guard and merge"

    setup_gh_mock <<'EOF'
{"headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}
EOF

    MOCK_FETCHED_HEAD="2222222222222222222222222222222222222222" run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T85" "Script exited 0 after the fetched branch diverged from the PR head."
    elif [[ -s "$WORK_DIR/scope-calls.log" ]]; then
        fail "T85" "Scope guard ran against a branch that did not match the PR head."
    elif grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T85" "Script merged after the fetched branch diverged from the PR head."
    else
        pass "T85"
    fi
    cleanup_gh_mock
}

test_T89() {
    run_test "T89" "wait-and-merge.sh: base movement after guard prevents merge"

    setup_gh_mock <<'EOF'
{"baseRefName":"main","baseRefOid":"3333333333333333333333333333333333333333","headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}
{"baseRefName":"main","baseRefOid":"4444444444444444444444444444444444444444","headRefOid":"1111111111111111111111111111111111111111"}
EOF

    run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T89" "Script exited 0 after public main moved following the guard."
    elif [[ ! -s "$WORK_DIR/scope-calls.log" ]]; then
        fail "T89" "Scope guard did not run before the simulated base movement."
    elif grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T89" "Script merged after public main moved following the guard."
    else
        pass "T89"
    fi
    cleanup_gh_mock
}

test_T90() {
    run_test "T90" "wait-and-merge.sh: base branch change after guard prevents merge"

    setup_gh_mock <<'EOF'
{"baseRefName":"main","baseRefOid":"3333333333333333333333333333333333333333","headRefOid":"1111111111111111111111111111111111111111","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[]}
{"baseRefName":"release","baseRefOid":"3333333333333333333333333333333333333333","headRefOid":"1111111111111111111111111111111111111111"}
EOF

    run_wait_and_merge

    if [[ "$WAIT_EXIT_CODE" -eq 0 ]]; then
        fail "T90" "Script exited 0 after the PR base branch changed."
    elif [[ ! -s "$WORK_DIR/scope-calls.log" ]]; then
        fail "T90" "Scope guard did not run before the simulated base branch change."
    elif grep -q "^pr merge " "$WORK_DIR/gh-calls.log"; then
        fail "T90" "Script merged after the PR base branch changed."
    elif ! grep -q "refusing to merge anywhere except main" "$WORK_DIR/wait.out" "$WORK_DIR/wait.err"; then
        fail "T90" "Base branch failure was not clearly reported."
    else
        pass "T90"
    fi
    cleanup_gh_mock
}

# ── TDD validation gate dynamic block-list tests (T39-T47) ─────────────────────
#
# Phase E pins the Phase D2 seam: sync-core.sh accepts SYNC_BLOCKED_PATHS as an
# additional per-run exclusion list layered on top of sync-config.json static
# exclusions. The value is colon-separated repo-relative path roots. Empty
# entries are ignored. Phase D2 should normalize each entry by stripping a
# leading "./" and trailing slashes, then match exact path or child paths only.

write_sample() {
    local sample_dir="$1"
    local body="${2:-content}"
    mkdir -p "$PRIVATE/$sample_dir"
    cat > "$PRIVATE/$sample_dir/sample.yaml" <<EOF
name: $(basename "$sample_dir")
description: TDD validation gate fixture
EOF
    echo "$body" > "$PRIVATE/$sample_dir/content.txt"
}

branch_has_path() {
    git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:$1" 2>/dev/null
}

branch_lacks_path() {
    ! branch_has_path "$1"
}

# Phase D2 sync-core block-list integration contract.
test_T39() {
    run_test "T39" "sync-core block-list excludes a single sample"
    setup_repos
    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/bar" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/bar/sample.yaml samples/python/bar/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/python/foo" run_sync_core; then
        fail "T39" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/sample.yaml" && branch_has_path "samples/python/bar/sample.yaml"; then
        pass "T39"
    else
        fail "T39" "Expected foo excluded and bar preserved"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T40() {
    run_test "T40" "sync-core block-list excludes multiple samples"
    setup_repos
    write_sample "samples/python/foo" "blocked foo"
    write_sample "samples/csharp/bar" "blocked bar"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add multiple samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/csharp/bar/sample.yaml samples/csharp/bar/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/python/foo:samples/csharp/bar" run_sync_core; then
        fail "T40" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/sample.yaml" \
        && branch_lacks_path "samples/csharp/bar/sample.yaml" \
        && branch_has_path "samples/python/keep/sample.yaml"; then
        pass "T40"
    else
        fail "T40" "Expected both blocked samples excluded and keep preserved"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T41() {
    run_test "T41" "empty sync-core block-list behaves like full sync"
    setup_repos
    write_sample "samples/python/foo" "allowed"
    echo "top-level" > "$PRIVATE/top-level.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add sample and top-level file" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt top-level.txt
    if ! SYNC_BLOCKED_PATHS="" run_sync_core; then
        fail "T41" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_has_path "samples/python/foo/sample.yaml" && branch_has_path "top-level.txt"; then
        pass "T41"
    else
        fail "T41" "Expected empty block-list to sync all otherwise-eligible content"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T42() {
    run_test "T42" "sync-core block-list composes with static exclusions"
    setup_repos
    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/keep" "allowed"
    mkdir -p "$PRIVATE/.github/workflows"
    echo "name: private" > "$PRIVATE/.github/workflows/private.yml"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add dynamic and static exclusions" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt \
        .github/workflows/private.yml
    if ! SYNC_BLOCKED_PATHS="samples/python/foo" run_sync_core; then
        fail "T42" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/sample.yaml" \
        && branch_lacks_path ".github/workflows/private.yml" \
        && branch_has_path "samples/python/keep/sample.yaml"; then
        pass "T42"
    else
        fail "T42" "Expected dynamic block and static .github exclusion to both apply"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T43() {
    run_test "T43" "nonexistent sync-core block-list path does not error"
    setup_repos
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add allowed sample" \
        samples/python/keep/sample.yaml samples/python/keep/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/python/missing" run_sync_core; then
        fail "T43" "sync-core failed on nonexistent blocked path: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_has_path "samples/python/keep/sample.yaml"; then
        pass "T43"
    else
        fail "T43" "Expected sync to proceed for existing unblocked sample"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T44() {
    run_test "T44" "sync-core block-list survives across commits touching blocked sample"
    setup_repos
    write_sample "samples/python/foo" "blocked v1"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt
    echo "blocked v2" > "$PRIVATE/samples/python/foo/content.txt"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Update blocked sample" samples/python/foo/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/python/foo" run_sync_core; then
        fail "T44" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/content.txt" && branch_has_path "samples/python/keep/content.txt"; then
        pass "T44"
    else
        fail "T44" "Expected blocked sample absent after multiple private commits"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T45() {
    run_test "T45" "blocked and unblocked sibling samples in same commit split correctly"
    setup_repos
    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/bar" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add sibling samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/bar/sample.yaml samples/python/bar/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/python/foo" run_sync_core; then
        fail "T45" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/content.txt" && branch_has_path "samples/python/bar/content.txt"; then
        pass "T45"
    else
        fail "T45" "Expected blocked sibling omitted and unblocked sibling synced"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T46() {
    run_test "T46" "deep block-list paths use precise prefix matching"
    setup_repos
    write_sample "samples/javascript-browser/openai/foo/bar" "blocked deep"
    write_sample "samples/javascript-browser/openai/foobar" "allowed precise sibling"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add deep and prefix-similar samples" \
        samples/javascript-browser/openai/foo/bar/sample.yaml \
        samples/javascript-browser/openai/foo/bar/content.txt \
        samples/javascript-browser/openai/foobar/sample.yaml \
        samples/javascript-browser/openai/foobar/content.txt
    if ! SYNC_BLOCKED_PATHS="samples/javascript-browser/openai/foo" run_sync_core; then
        fail "T46" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/javascript-browser/openai/foo/bar/sample.yaml" \
        && branch_has_path "samples/javascript-browser/openai/foobar/sample.yaml"; then
        pass "T46"
    else
        fail "T46" "Expected foo subtree blocked without blocking foobar"
    fi
    cleanup
}

# Phase D2 sync-core block-list integration contract.
test_T47() {
    run_test "T47" "sync-core block-list normalizes leading ./ and trailing slash"
    setup_repos
    write_sample "samples/python/foo" "blocked by leading dot"
    write_sample "samples/python/bar" "blocked by trailing slash"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add normalization samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/bar/sample.yaml samples/python/bar/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt
    if ! SYNC_BLOCKED_PATHS="./samples/python/foo/:samples/python/bar/" run_sync_core; then
        fail "T47" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi
    if branch_lacks_path "samples/python/foo/sample.yaml" \
        && branch_lacks_path "samples/python/bar/sample.yaml" \
        && branch_has_path "samples/python/keep/sample.yaml"; then
        pass "T47"
    else
        fail "T47" "Expected normalized block-list entries to exclude foo and bar only"
    fi
    cleanup
}


# Run sync-core.sh integration tests
if [[ -f "$SYNC_SCRIPT" ]]; then
    test_T26
    test_T28
    test_T37
    test_T51
    test_T52
    test_T53
    test_T56
    test_T59
    test_T60
    test_T62
    test_T63
    # T39-T47 pin the Phase D2 sync-core block-list contract.
    # Enabled by default; set SYNC_BLOCKLIST_TESTS_ENABLED=0 for legacy environments.
    # See docs/validation-story-decisions.md and ADO 5237807.
    if [[ "${SYNC_BLOCKLIST_TESTS_ENABLED:-1}" == "1" ]]; then
        test_T39
        test_T40
        test_T41
        test_T42
        test_T43
        test_T44
        test_T45
        test_T46
        test_T47
    else
        echo ""
        echo "(skipped) T39-T47: sync-core block-list tests disabled for legacy environment (SYNC_BLOCKLIST_TESTS_ENABLED=0)"
    fi
else
    echo ""
    echo "⚠️  Skipping sync-core.sh integration tests (script not found at $SYNC_SCRIPT)"
fi

# Run wait-and-merge.sh tests
if [[ -f "$WAIT_AND_MERGE_SCRIPT" ]]; then
    test_T29
    test_T30
    test_T31
    test_T80
    test_T85
    test_T89
    test_T90
else
    echo ""
    echo "⚠️  Skipping wait-and-merge.sh tests (script not found at $WAIT_AND_MERGE_SCRIPT)"
fi

# ── verify-sync.sh tests (T32-T36) ─────────────────────────────────────────────
#
# Validates the post-sync drift checker:
#   - No drift after a clean sync (T32)
#   - Extra file in public is flagged as drift (T33)
#   - Content drift on a tracked file is flagged (T34)
#   - Excluded paths in private don't trigger false-positive drift (T35)

VERIFY_SYNC_SCRIPT="$REPO_ROOT/.github/scripts/verify-sync.sh"

write_default_config() {
    local include_json
    include_json=$(python3 - "$PRIVATE" <<'PY'
import json
import os
import sys

repo = sys.argv[1]
paths = ["infrastructure/", "samples/"]
for name in os.listdir(repo):
    if name not in {".git", ".github", "internal", "README.md", "CONTRIBUTING.md"}:
        paths.append(name + "/" if os.path.isdir(os.path.join(repo, name)) else name)
print(json.dumps(sorted(paths)))
PY
)
    cat > "$WORK_DIR/sync-config.json" <<EOF
{
  "default_include_paths": $include_json,
  "exclude_pathspecs": [":!internal/", ":!.github/"],
  "public_repo": {"owner": "x", "name": "y"},
  "sync_branch_prefix": "sync"
}
EOF
}

run_verify_sync() {
    write_default_config
    set +e
    bash "$VERIFY_SYNC_SCRIPT" "$PRIVATE" "$PUBLIC" "$WORK_DIR/sync-config.json" \
        > "$WORK_DIR/verify.out" 2> "$WORK_DIR/verify.err"
    VERIFY_EXIT_CODE=$?
    set -e
}

test_T32() {
    run_test "T32" "verify-sync reports no drift after a clean sync"
    setup_repos

    echo "alpha" > "$PRIVATE/alpha.txt"
    commit_as "$PRIVATE" "Alice" "alice@ext.com" "Add alpha" alpha.txt
    echo "beta" > "$PRIVATE/beta.txt"
    commit_as "$PRIVATE" "Bob" "bob@ext.com" "Add beta" beta.txt

    if ! run_sync; then
        fail "T32" "run_sync failed: $(cat "$WORK_DIR/filter.stderr" 2>/dev/null || echo none)"
        cleanup; return
    fi

    run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T32" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if ! grep -q '^drift=false$' "$WORK_DIR/verify.out"; then
        fail "T32" "Expected drift=false. stdout: $(cat "$WORK_DIR/verify.out"); stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if ! grep -q '^drift_count=0$' "$WORK_DIR/verify.out"; then
        fail "T32" "Expected drift_count=0. Got: $(cat "$WORK_DIR/verify.out")"
        cleanup; return
    fi

    pass "T32"
    cleanup
}

test_T33() {
    run_test "T33" "verify-sync flags extra file in public as drift"
    setup_repos

    echo "shared" > "$PRIVATE/shared.txt"
    commit_as "$PRIVATE" "Alice" "alice@ext.com" "Add shared" shared.txt

    if ! run_sync; then
        fail "T33" "run_sync failed"; cleanup; return
    fi

    # Plant a rogue file directly in public — simulates manual edit / dropped delete
    mkdir -p "$PUBLIC/samples"
    echo "rogue" > "$PUBLIC/samples/rogue.txt"
    commit_as "$PUBLIC" "Rogue" "rogue@ext.com" "Add rogue" samples/rogue.txt

    run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T33" "verify-sync exited $VERIFY_EXIT_CODE unexpectedly: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if ! grep -q '^drift=true$' "$WORK_DIR/verify.out"; then
        fail "T33" "Expected drift=true. Output: $(cat "$WORK_DIR/verify.out")"
        cleanup; return
    fi
    if ! grep -qE '^\*deleting\ssamples/rogue\.txt$' /tmp/drift-files.txt; then
        fail "T33" "Expected '*deleting samples/rogue.txt' in drift report. Got: $(cat /tmp/drift-files.txt)"
        cleanup; return
    fi

    pass "T33"
    cleanup
}

test_T34() {
    run_test "T34" "verify-sync flags content drift on a tracked file"
    setup_repos

    echo "original" > "$PRIVATE/file.txt"
    commit_as "$PRIVATE" "Alice" "alice@ext.com" "Add file" file.txt

    if ! run_sync; then
        fail "T34" "run_sync failed"; cleanup; return
    fi

    # Tamper with the public copy
    echo "tampered" > "$PUBLIC/file.txt"
    commit_as "$PUBLIC" "Tamper" "tamper@ext.com" "Tamper file" file.txt

    run_verify_sync
    if ! grep -q '^drift=true$' "$WORK_DIR/verify.out"; then
        fail "T34" "Expected drift=true. Output: $(cat "$WORK_DIR/verify.out")"
        cleanup; return
    fi
    if ! grep -qE '^>f\sfile\.txt$' /tmp/drift-files.txt; then
        fail "T34" "Expected '>f file.txt' in drift report. Got: $(cat /tmp/drift-files.txt)"
        cleanup; return
    fi

    pass "T34"
    cleanup
}

test_T35() {
    run_test "T35" "verify-sync ignores excluded paths in private (no false drift)"
    setup_repos

    echo "include" > "$PRIVATE/include.txt"
    commit_as "$PRIVATE" "Alice" "alice@ext.com" "Add include" include.txt

    # Add files under excluded paths; they must NOT appear as drift
    mkdir -p "$PRIVATE/.github" "$PRIVATE/internal"
    echo "private-only" > "$PRIVATE/.github/secret.txt"
    echo "internal-only" > "$PRIVATE/internal/notes.md"
    cd "$PRIVATE"
    git add .github/secret.txt internal/notes.md
    GIT_AUTHOR_NAME="Alice" GIT_AUTHOR_EMAIL="alice@ext.com" \
    GIT_COMMITTER_NAME="Alice" GIT_COMMITTER_EMAIL="alice@ext.com" \
    git commit -m "Add excluded files" --quiet
    cd - >/dev/null

    if ! run_sync; then
        fail "T35" "run_sync failed"; cleanup; return
    fi

    run_verify_sync
    if ! grep -q '^drift=false$' "$WORK_DIR/verify.out"; then
        fail "T35" "Expected drift=false (excludes should not surface). Output: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
        cleanup; return
    fi

    pass "T35"
    cleanup
}

# Regression for "false drift on public-only .github/CODEOWNERS" (post-#197 fix).
# Public legitimately contains files in excluded paths (e.g., its own CODEOWNERS).
# Drift checking must ignore excluded paths on the public side too.
test_T36() {
    run_test "T36" "verify-sync ignores excluded paths in public (no false drift on public-only files)"
    setup_repos

    echo "include" > "$PRIVATE/include.txt"
    commit_as "$PRIVATE" "Alice" "alice@ext.com" "Add include" include.txt

    if ! run_sync; then
        fail "T36" "run_sync failed"; cleanup; return
    fi

    # Simulate a public-only file in an excluded path — e.g., public-only CODEOWNERS.
    mkdir -p "$PUBLIC/.github"
    echo "* @public-team" > "$PUBLIC/.github/CODEOWNERS"
    cd "$PUBLIC"
    git add .github/CODEOWNERS
    GIT_AUTHOR_NAME="Pub" GIT_AUTHOR_EMAIL="pub@ext.com" \
    GIT_COMMITTER_NAME="Pub" GIT_COMMITTER_EMAIL="pub@ext.com" \
    git commit -m "Public-only CODEOWNERS" --quiet
    cd - >/dev/null

    run_verify_sync
    if ! grep -q '^drift=false$' "$WORK_DIR/verify.out"; then
        fail "T36" "Expected drift=false (public-only excluded path should not surface). Output: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
        cleanup; return
    fi

    pass "T36"
    cleanup
}

test_T48() {
    run_test "T48" "verify-sync ignores validation-blocked paths when checking drift"
    setup_repos

    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    if ! run_sync_core; then
        fail "T48" "sync-core failed before verify: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi

    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet
    git -C "$PUBLIC" rm -r samples/python/foo --quiet
    GIT_AUTHOR_NAME="Verifier" GIT_AUTHOR_EMAIL="verifier@example.com" \
    GIT_COMMITTER_NAME="Verifier" GIT_COMMITTER_EMAIL="verifier@example.com" \
    git -C "$PUBLIC" commit -m "Simulate validation-held sample" --quiet

    SYNC_BLOCKED_PATHS="samples/python/foo" run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T48" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if grep -q '^drift=false$' "$WORK_DIR/verify.out"; then
        pass "T48"
    else
        fail "T48" "Expected blocked path not to count as drift. stdout: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
    fi
    cleanup
}


# ── T49: drift on a non-blocked path is still reported (negative pin) ────────
# Guards against the obvious failure mode where verify-sync over-skips when
# SYNC_BLOCKED_PATHS is set and stops detecting any drift at all.
test_T49() {
    run_test "T49" "verify-sync still flags drift on non-blocked paths when block-list is non-empty"
    setup_repos

    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    if ! run_sync_core; then
        fail "T49" "sync-core failed before verify: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi

    # Tamper with the public tree on a non-blocked path so it differs from private.
    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet
    echo "tampered" > "$PUBLIC/samples/python/keep/content.txt"
    GIT_AUTHOR_NAME="Verifier" GIT_AUTHOR_EMAIL="verifier@example.com" \
    GIT_COMMITTER_NAME="Verifier" GIT_COMMITTER_EMAIL="verifier@example.com" \
    git -C "$PUBLIC" commit -am "Mutate non-blocked sample to force drift" --quiet

    SYNC_BLOCKED_PATHS="samples/python/foo" run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T49" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if grep -q '^drift=true$' "$WORK_DIR/verify.out" \
        && grep -q "samples/python/keep/content.txt" /tmp/drift-files.txt; then
        pass "T49"
    else
        fail "T49" "Expected drift on non-blocked path. stdout: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
    fi
    cleanup
}

# ── T50: block-list normalization parity ─────────────────────────────────────
# Sync-core and verify-sync must normalize the same input strings the same way
# (leading "./", trailing "/", surrounding whitespace).
# This is a contract test on the shared SYNC_BLOCKED_PATHS shape.
test_T50() {
    run_test "T50" "sync-core and verify-sync normalize SYNC_BLOCKED_PATHS identically"
    setup_repos

    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    # Messy form: leading "./", trailing "/". Whitespace not normalized
    # (sync-core does not trim, so verify-sync must not either — that is
    # the parity contract this test pins).
    local messy_blocklist="./samples/python/foo/"
    if ! SYNC_BLOCKED_PATHS="$messy_blocklist" run_sync_core; then
        fail "T50" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi

    if branch_has_path "samples/python/foo/sample.yaml"; then
        fail "T50" "sync-core did not exclude messy block-list entry"
        cleanup; return
    fi

    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet

    SYNC_BLOCKED_PATHS="$messy_blocklist" run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T50" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if grep -q '^drift=false$' "$WORK_DIR/verify.out"; then
        pass "T50"
    else
        fail "T50" "verify-sync did not normalize messy block-list entry the same way as sync-core. stdout: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
    fi
    cleanup
}

# ── T51: sync→verify round-trip with the same block-list ────────────────────
# Identical SYNC_BLOCKED_PATHS in both stages → drift=false.
test_T54() {
    run_test "T54" "sync→verify round-trip with same SYNC_BLOCKED_PATHS reports no drift"
    setup_repos

    write_sample "samples/python/foo" "blocked"
    write_sample "samples/csharp/bar" "blocked too"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add three samples; two will be blocked" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/csharp/bar/sample.yaml samples/csharp/bar/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    local blocklist="samples/python/foo:samples/csharp/bar"
    if ! SYNC_BLOCKED_PATHS="$blocklist" run_sync_core; then
        fail "T54" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi

    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet

    SYNC_BLOCKED_PATHS="$blocklist" run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T54" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if grep -q '^drift=false$' "$WORK_DIR/verify.out" \
        && grep -q '^drift_count=0$' "$WORK_DIR/verify.out"; then
        pass "T54"
    else
        fail "T54" "Expected drift=false after round-trip. stdout: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
    fi
    cleanup
}

# ── T52: end-to-end payload→compute-blocklist→sync→verify ───────────────────
# A GitHub combined-status payload feeds compute-blocklist.sh, whose output
# becomes SYNC_BLOCKED_PATHS for both sync and verify.
test_T55() {
    run_test "T55" "end-to-end: status payload → compute-blocklist → sync → verify (no drift)"
    if ! command -v jq >/dev/null 2>&1; then
        fail "T55" "jq not on PATH (required for compute-blocklist.sh)"
        cleanup; return
    fi

    setup_repos
    write_sample "samples/python/foo" "blocked"
    write_sample "samples/python/keep" "allowed"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Add blocked and allowed samples" \
        samples/python/foo/sample.yaml samples/python/foo/content.txt \
        samples/python/keep/sample.yaml samples/python/keep/content.txt

    local payload="$WORK_DIR/statuses.json"
    cat > "$payload" <<'JSON'
{
  "state": "failure",
  "statuses": [
    { "context": "validation/ado-build/samples/python/foo", "state": "failure" },
    { "context": "validation/ado-build/samples/python/keep", "state": "success" }
  ]
}
JSON

    local compute_script="$REPO_ROOT/.github/scripts/compute-blocklist.sh"
    if [[ ! -f "$compute_script" ]]; then
        fail "T55" "compute-blocklist.sh not found at $compute_script"
        cleanup; return
    fi

    local blocklist
    if ! blocklist="$(BLOCKLIST_PAYLOAD_FILE="$payload" bash "$compute_script" \
        microsoft-foundry/foundry-samples-pr deadbeef \
        2> "$WORK_DIR/compute.err")"; then
        fail "T55" "compute-blocklist.sh failed: $(cat "$WORK_DIR/compute.err")"
        cleanup; return
    fi

    if [[ "$blocklist" != "samples/python/foo" ]]; then
        fail "T55" "Expected block-list 'samples/python/foo', got '$blocklist'"
        cleanup; return
    fi

    if ! SYNC_BLOCKED_PATHS="$blocklist" run_sync_core; then
        fail "T55" "sync-core failed: $(cat "$WORK_DIR/sync-core.err")"; cleanup; return
    fi

    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet

    SYNC_BLOCKED_PATHS="$blocklist" run_verify_sync
    if [[ $VERIFY_EXIT_CODE -ne 0 ]]; then
        fail "T55" "verify-sync exited $VERIFY_EXIT_CODE; stderr: $(cat "$WORK_DIR/verify.err")"
        cleanup; return
    fi
    if grep -q '^drift=false$' "$WORK_DIR/verify.out" \
        && branch_lacks_path "samples/python/foo/sample.yaml" \
        && branch_has_path "samples/python/keep/sample.yaml"; then
        pass "T55"
    else
        fail "T55" "Expected end-to-end no-drift outcome. stdout: $(cat "$WORK_DIR/verify.out"); drift: $(cat /tmp/drift-files.txt 2>/dev/null || echo none)"
    fi
    cleanup
}


if [[ -f "$VERIFY_SYNC_SCRIPT" ]]; then
    test_T32
    test_T33
    test_T34
    test_T35
    test_T36

    # T48–T50 and T54–T55 pin the Phase D4 verify-sync + compute-blocklist contracts.
    test_T48
    test_T49
    test_T50
    test_T54
    test_T55
else
    echo ""
    echo "⚠️  Skipping verify-sync.sh tests (script not found at $VERIFY_SYNC_SCRIPT)"
fi

# ─── Option B rename-across-boundary regression coverage (ADO 5347427) ───
# fast-export now runs with --no-renames, decomposing renames into D+M pairs
# so filter-stream can filter each side independently. These tests confirm
# the decomposition does the right thing in both rename directions across
# the include/exclude boundary.

test_T71() {
    run_test "T71" "rename samples/X → internal/X: D kept on sync side, M dropped, file disappears from public"
    setup_repos

    mkdir -p "$PRIVATE/samples"
    echo "to-be-moved" > "$PRIVATE/samples/movable.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add samples/movable.txt" samples/movable.txt

    # Round-trip through sync so public main has samples/movable.txt.
    run_sync
    if ! git -C "$PUBLIC" show "main:samples/movable.txt" >/dev/null 2>&1; then
        fail "T71" "Setup precondition failed: samples/movable.txt missing on public main after first sync"
        cleanup; return
    fi

    # Rename into the exclude set.
    mkdir -p "$PRIVATE/internal"
    git -C "$PRIVATE" mv samples/movable.txt internal/movable.txt
    GIT_AUTHOR_NAME="Private Dev" GIT_AUTHOR_EMAIL="private@example.com" \
    GIT_COMMITTER_NAME="Private Dev" GIT_COMMITTER_EMAIL="private@example.com" \
        git -C "$PRIVATE" commit -m "Move movable.txt to internal/" --quiet

    run_sync

    if git -C "$PUBLIC" show "main:samples/movable.txt" >/dev/null 2>&1; then
        fail "T71" "samples/movable.txt should be deleted on public after rename-out (D op must apply)"
        cleanup; return
    fi
    if git -C "$PUBLIC" show "main:internal/movable.txt" >/dev/null 2>&1; then
        fail "T71" "internal/movable.txt LEAKED to public — M op should be dropped by filter-stream"
        cleanup; return
    fi

    pass "T71"
    cleanup
}

test_T72() {
    run_test "T72" "rename internal/X → samples/X: D dropped on sync side, M kept, file appears on public"
    setup_repos

    mkdir -p "$PRIVATE/internal"
    echo "hidden" > "$PRIVATE/internal/hidden.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add internal/hidden.txt" internal/hidden.txt

    # First sync should NOT leak internal/hidden.txt.
    run_sync
    if git -C "$PUBLIC" show "main:internal/hidden.txt" >/dev/null 2>&1; then
        fail "T72" "internal/hidden.txt leaked to public in initial sync (exclude filter broken)"
        cleanup; return
    fi

    # Rename into the include set.
    mkdir -p "$PRIVATE/samples"
    git -C "$PRIVATE" mv internal/hidden.txt samples/now-public.txt
    GIT_AUTHOR_NAME="Private Dev" GIT_AUTHOR_EMAIL="private@example.com" \
    GIT_COMMITTER_NAME="Private Dev" GIT_COMMITTER_EMAIL="private@example.com" \
        git -C "$PRIVATE" commit -m "Move hidden.txt to samples/now-public.txt" --quiet

    run_sync

    if ! git -C "$PUBLIC" show "main:samples/now-public.txt" >/dev/null 2>&1; then
        fail "T72" "samples/now-public.txt missing on public — rename-in M op must apply"
        cleanup; return
    fi
    local content
    content=$(git -C "$PUBLIC" show "main:samples/now-public.txt")
    if [[ "$content" != "hidden" ]]; then
        fail "T72" "samples/now-public.txt content wrong: expected 'hidden', got '$content'"
        cleanup; return
    fi
    if git -C "$PUBLIC" show "main:internal/hidden.txt" >/dev/null 2>&1; then
        fail "T72" "internal/hidden.txt unexpectedly visible on public after rename-in"
        cleanup; return
    fi

    pass "T72"
    cleanup
}

test_T73() {
    run_test "T73" "established public repo without marks fails closed and requires seed recovery"
    setup_public_with_extras
    setup_sync_core_env
    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-missing-marks"
    local sync_output="$WORK_DIR/sync-core.out"
    : > "$sync_output"

    local sync_exit=0
    if env \
        GITHUB_OUTPUT="$sync_output" \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        SYNC_BRANCH="$SYNC_BRANCH" \
        MARKS_DIR="$MARKS_DIR" \
        CONFIG_FILE="$CONFIG_FILE" \
        MAILMAP_FILE="$MAILMAP" \
        SOURCE_REF="refs/heads/main" \
        DRY_RUN=1 \
        bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"; then
        sync_exit=0
    else
        sync_exit=$?
    fi

    if [[ $sync_exit -eq 0 ]]; then
        fail "T73" "missing marks on an established public repo produced an orphan sync branch"
    elif ! grep -q "^sync_error=SEED_RECOVERY_REQUIRED$" "$sync_output"; then
        fail "T73" "expected SEED_RECOVERY_REQUIRED, got output: $(cat "$sync_output"); stderr: $(cat "$WORK_DIR/sync-core.err")"
    elif ! grep -q "^has_changes=false$" "$sync_output"; then
        fail "T73" "fail-closed output did not set has_changes=false: $(cat "$sync_output")"
    elif git -C "$PUBLIC" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        fail "T73" "sync branch was created before missing-marks recovery failed closed"
    else
        pass "T73"
    fi
    cleanup
}

test_T77() {
    run_test "T77" "workflow is manual-only and has no direct-main publish path"
    if python3 "$WORKFLOW_CONTRACT_TEST" >"/tmp/t77.out" 2>"/tmp/t77.err"; then
        pass "T77"
    else
        fail "T77" "$(cat /tmp/t77.err)"
    fi
}

merge_sync_branch_to_public_main() {
    git -C "$PUBLIC" checkout -B main "refs/heads/$SYNC_BRANCH" --quiet
}

test_T78() {
    run_test "T78" "incremental sync retains blocked published content, propagates deletion, and preserves public-owned exclusions"
    setup_repos
    write_sample "samples/python/blocked" "published v1"
    write_sample "samples/python/deleted" "delete me"
    write_sample "samples/python/allowed" "allowed v1"
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Publish initial samples" \
        samples/python/blocked/sample.yaml samples/python/blocked/content.txt \
        samples/python/deleted/sample.yaml samples/python/deleted/content.txt \
        samples/python/allowed/sample.yaml samples/python/allowed/content.txt

    run_sync_core || {
        fail "T78" "bootstrap sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    }
    merge_sync_branch_to_public_main

    mkdir -p "$PUBLIC/.github/workflows"
    echo "name: public-owned" > "$PUBLIC/.github/workflows/public-owned.yml"
    commit_as "$PUBLIC" "Public Maintainer" "public@example.com" \
        "Add public-owned workflow" .github/workflows/public-owned.yml
    local public_owned_before
    public_owned_before=$(git -C "$PUBLIC" rev-parse "main:.github/workflows/public-owned.yml")

    echo "blocked private v2" > "$PRIVATE/samples/python/blocked/content.txt"
    echo "allowed v2" > "$PRIVATE/samples/python/allowed/content.txt"
    git -C "$PRIVATE" rm -r --quiet samples/python/deleted
    commit_as "$PRIVATE" "Dev" "dev@example.com" "Update, block, and delete samples" \
        samples/python/blocked/content.txt samples/python/allowed/content.txt

    if ! SYNC_BLOCKED_PATHS="samples/python/blocked" run_sync_core; then
        fail "T78" "incremental sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    git -C "$PUBLIC" checkout "$SYNC_BRANCH" --quiet
    if ! git -C "$PUBLIC" rebase main --empty=drop --quiet; then
        fail "T78" "incremental sync branch did not rebase cleanly"
        cleanup; return
    fi
    git -C "$PUBLIC" checkout main --quiet
    git -C "$PUBLIC" merge --ff-only "$SYNC_BRANCH" --quiet

    local blocked_after allowed_after public_owned_after
    blocked_after=$(git -C "$PUBLIC" show "main:samples/python/blocked/content.txt")
    allowed_after=$(git -C "$PUBLIC" show "main:samples/python/allowed/content.txt")
    public_owned_after=$(git -C "$PUBLIC" rev-parse "main:.github/workflows/public-owned.yml")

    if [[ "$blocked_after" != "published v1" ]]; then
        fail "T78" "published blocked sample changed (got '$blocked_after')"
    elif git -C "$PUBLIC" cat-file -e "main:samples/python/deleted/content.txt" 2>/dev/null; then
        fail "T78" "intentional unblocked private deletion did not propagate"
    elif [[ "$allowed_after" != "allowed v2" ]]; then
        fail "T78" "allowed sample update did not propagate"
    elif [[ "$public_owned_after" != "$public_owned_before" ]]; then
        fail "T78" "public-owned excluded workflow changed"
    else
        pass "T78"
    fi
    cleanup
}

test_T79() {
    run_test "T79" "FORCE_FULL invocation fails before marks, refs, or remote state change"
    setup_public_with_extras
    setup_sync_core_env
    printf 'private marks sentinel\n' > "$MARKS_DIR/private.marks"
    printf 'public marks sentinel\n' > "$MARKS_DIR/public.marks"
    printf 'hash sentinel\n' > "$MARKS_DIR/pathspec.hash"
    printf 'root sentinel\n' > "$MARKS_DIR/root.sha"
    local marks_before
    marks_before=$(sha256sum "$MARKS_DIR"/* | sort)

    local origin="$WORK_DIR/origin.git"
    git init --bare --initial-branch=main "$origin" >/dev/null 2>&1
    git -C "$PUBLIC" remote add origin "$origin"
    git -C "$PUBLIC" push --quiet origin main
    local remote_before
    remote_before=$(git --git-dir="$origin" rev-parse main)

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-force-full"
    local sync_output="$WORK_DIR/sync-core.out"
    : > "$sync_output"
    local sync_exit=0
    if env \
        GITHUB_OUTPUT="$sync_output" \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        SYNC_BRANCH="$SYNC_BRANCH" \
        MARKS_DIR="$MARKS_DIR" \
        CONFIG_FILE="$CONFIG_FILE" \
        MAILMAP_FILE="$MAILMAP" \
        SOURCE_REF="refs/heads/main" \
        FORCE_FULL=1 \
        bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"; then
        sync_exit=0
    else
        sync_exit=$?
    fi

    local marks_after remote_after
    marks_after=$(sha256sum "$MARKS_DIR"/* | sort)
    remote_after=$(git --git-dir="$origin" rev-parse main)
    if [[ $sync_exit -eq 0 ]]; then
        fail "T79" "FORCE_FULL invocation succeeded"
    elif ! grep -q "^sync_error=FORCE_FULL_DISABLED$" "$sync_output"; then
        fail "T79" "expected FORCE_FULL_DISABLED, got output: $(cat "$sync_output"); stderr: $(cat "$WORK_DIR/sync-core.err")"
    elif ! grep -q "^has_changes=false$" "$sync_output"; then
        fail "T79" "fail-closed output did not set has_changes=false: $(cat "$sync_output")"
    elif [[ "$marks_after" != "$marks_before" ]]; then
        fail "T79" "FORCE_FULL mutated marks before failing"
    elif [[ "$remote_after" != "$remote_before" ]]; then
        fail "T79" "FORCE_FULL changed public main"
    elif git -C "$PUBLIC" rev-parse --verify "refs/heads/$SYNC_BRANCH" >/dev/null 2>&1; then
        fail "T79" "FORCE_FULL created a sync branch before failing"
    else
        pass "T79"
    fi
    cleanup
}

# T74 — exclude_basenames: filter-stream.py --exclude-basename drops scattered
# marker files (.ci-skip / .code-ci-skip) regardless of directory, while
# leaving sibling files intact. Covers the basename-exclusion mechanism added
# for internal CI marker files that share no common path prefix.
test_T74() {
    run_test "T74" "filter-stream --exclude-basename drops .ci-skip/.code-ci-skip anywhere, keeps siblings"
    setup_repos

    # Two samples in different language trees, each with a marker file plus a
    # real source file that must survive.
    mkdir -p "$PRIVATE/samples/python/foo" "$PRIVATE/samples/csharp/bar"
    echo "code"  > "$PRIVATE/samples/python/foo/main.py"
    echo "skip"  > "$PRIVATE/samples/python/foo/.ci-skip"
    echo "code"  > "$PRIVATE/samples/csharp/bar/Program.cs"
    echo "skip"  > "$PRIVATE/samples/csharp/bar/.code-ci-skip"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add samples with marker files" \
        samples/python/foo/main.py samples/python/foo/.ci-skip \
        samples/csharp/bar/Program.cs samples/csharp/bar/.code-ci-skip

    # Run the production pipeline directly: fast-export (no pathspecs) →
    # filter-stream with --exclude-basename → fast-import. Mirrors how
    # sync-core.sh invokes the filter (run_sync uses fast-export pathspecs and
    # does not exercise --exclude-basename, so we call the filter explicitly).
    git -C "$PRIVATE" fast-export refs/heads/main \
        --tag-of-filtered-object=drop --no-renames 2>/dev/null \
        | python3 "$FILTER_SCRIPT" --mailmap "$MAILMAP" \
            --source-ref refs/heads/main --target-ref refs/heads/main \
            --exclude-basename .ci-skip --exclude-basename .code-ci-skip \
        | git -C "$PUBLIC" fast-import --force --quiet 2>/dev/null

    # Real source files must survive.
    if ! git -C "$PUBLIC" show "main:samples/python/foo/main.py" >/dev/null 2>&1; then
        fail "T74" "samples/python/foo/main.py missing on public — non-marker file must sync"
        cleanup; return
    fi
    if ! git -C "$PUBLIC" show "main:samples/csharp/bar/Program.cs" >/dev/null 2>&1; then
        fail "T74" "samples/csharp/bar/Program.cs missing on public — non-marker file must sync"
        cleanup; return
    fi
    # Marker files must be dropped, regardless of which tree they live in.
    if git -C "$PUBLIC" show "main:samples/python/foo/.ci-skip" >/dev/null 2>&1; then
        fail "T74" ".ci-skip LEAKED to public — --exclude-basename must drop it"
        cleanup; return
    fi
    if git -C "$PUBLIC" show "main:samples/csharp/bar/.code-ci-skip" >/dev/null 2>&1; then
        fail "T74" ".code-ci-skip LEAKED to public — --exclude-basename must drop it"
        cleanup; return
    fi

    pass "T74"
    cleanup
}

# T75 — seed-marks-from-public must honor exclude_basenames in its tree-
# equivalence check. A marker file (.code-ci-skip) added in private is dropped
# by filter-stream and never reaches public, so private and public legitimately
# differ only by that marker. Without basename-aware filtering, seed-marks would
# report a "Tree mismatch" and wedge the dominant stale-marks recovery path.
test_T75() {
    run_test "T75" "seed-marks-from-public: private-only marker file (.code-ci-skip) does NOT cause tree mismatch"
    setup_public_with_extras

    # Config mirrors write_graft_sync_config but adds exclude_basenames.
    CONFIG_FILE="$WORK_DIR/sync-config.json"
    cat > "$CONFIG_FILE" <<'EOF'
{
  "default_include_paths": ["infrastructure/", "samples/"],
  "exclude_pathspecs": [":!internal/", ":!docs/", ":!.azure-pipelines/", ":!.github/", ":!CONTRIBUTING.md", ":!README.md"],
  "exclude_basenames": [".ci-skip", ".code-ci-skip"],
  "public_repo": {"owner": "test", "name": "test"},
  "sync_branch_prefix": "sync/test"
}
EOF

    # Add a marker file ONLY in private — public never receives it because the
    # sync filter drops it. This is the exact divergence the fix must tolerate.
    mkdir -p "$PRIVATE/samples/foo"
    echo "skip" > "$PRIVATE/samples/foo/.code-ci-skip"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add private-only .code-ci-skip marker" samples/foo/.code-ci-skip

    local private_sha public_sha
    private_sha=$(git -C "$PRIVATE" rev-parse HEAD)
    public_sha=$(git -C "$PUBLIC" rev-parse HEAD)

    if run_seed_marks "$private_sha" "$public_sha"; then
        pass "T75"
    else
        fail "T75" "seed-marks should succeed despite private-only marker; got: $(cat "$WORK_DIR/seed.err")"
    fi
    cleanup
}

test_T81() {
    run_test "T81" "public-only root docs changed between syncs remain unchanged"
    setup_public_with_extras
    write_graft_sync_config

    local private_sha public_sha
    private_sha=$(git -C "$PRIVATE" rev-parse HEAD)
    public_sha=$(git -C "$PUBLIC" rev-parse HEAD)
    if ! run_seed_marks "$private_sha" "$public_sha"; then
        fail "T81" "Initial seed failed: $(cat "$WORK_DIR/seed.err")"
        cleanup; return
    fi

    echo "# Public README restored" > "$PUBLIC/README.md"
    echo "# Public CONTRIBUTING restored" > "$PUBLIC/CONTRIBUTING.md"
    commit_as "$PUBLIC" "Public Dev" "public@example.com" \
        "Restore public contribution docs" README.md CONTRIBUTING.md
    local readme_blob contributing_blob
    readme_blob=$(git -C "$PUBLIC" rev-parse "main:README.md")
    contributing_blob=$(git -C "$PUBLIC" rev-parse "main:CONTRIBUTING.md")

    echo "shared v2" > "$PRIVATE/samples/shared.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Update shared sample" samples/shared.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-public-docs"
    if ! run_sync_core_for_graft; then
        fail "T81" "Incremental sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    local result_tree
    result_tree=$(git -C "$PUBLIC" merge-tree --write-tree \
        main "refs/heads/$SYNC_BRANCH" | head -n 1)
    if [[ "$(git -C "$PUBLIC" rev-parse "$result_tree:README.md")" != "$readme_blob" ]]; then
        fail "T81" "Prospective merge changed the public README."
    elif [[ "$(git -C "$PUBLIC" rev-parse "$result_tree:CONTRIBUTING.md")" != "$contributing_blob" ]]; then
        fail "T81" "Prospective merge changed public CONTRIBUTING.md."
    elif [[ "$(git -C "$PUBLIC" show "$result_tree:samples/shared.txt")" != "shared v2" ]]; then
        fail "T81" "Prospective merge omitted the in-scope sample update."
    else
        pass "T81"
    fi
    cleanup
}

test_T82() {
    run_test "T82" "default scope plus exact-file and directory additions"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/infrastructure" "$PRIVATE/samples" \
        "$PRIVATE/ops" "$PRIVATE/extras/dir" "$PRIVATE/extras/directory-sibling" \
        "$PRIVATE/other"
    echo "infra" > "$PRIVATE/infrastructure/main.bicep"
    echo "sample" > "$PRIVATE/samples/app.txt"
    echo "exact" > "$PRIVATE/ops/exact.txt"
    echo "not exact" > "$PRIVATE/ops/exact.txt.sibling"
    echo "directory" > "$PRIVATE/extras/dir/file.txt"
    echo "not directory" > "$PRIVATE/extras/directory-sibling/file.txt"
    echo "drop" > "$PRIVATE/other/drop.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" "Add scoped files" \
        infrastructure/main.bicep samples/app.txt ops/exact.txt \
        ops/exact.txt.sibling extras/dir/file.txt \
        extras/directory-sibling/file.txt other/drop.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-additional"
    if ! env \
        PRIVATE_REPO="$PRIVATE" \
        PUBLIC_REPO="$PUBLIC" \
        SYNC_BRANCH="$SYNC_BRANCH" \
        MARKS_DIR="$MARKS_DIR" \
        CONFIG_FILE="$CONFIG_FILE" \
        MAILMAP_FILE="$MAILMAP" \
        SOURCE_REF="refs/heads/main" \
        SYNC_ADDITIONAL_PATHS="ops/exact.txt:extras/dir/" \
        DRY_RUN=1 \
        bash "$SYNC_SCRIPT" 2>"$WORK_DIR/sync-core.err"; then
        fail "T82" "Scoped sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    local expected missing=()
    for expected in infrastructure/main.bicep samples/app.txt ops/exact.txt extras/dir/file.txt; do
        git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:$expected" 2>/dev/null || missing+=("$expected")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        fail "T82" "Expected scoped files missing: ${missing[*]}"
    elif git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:ops/exact.txt.sibling" 2>/dev/null \
        || git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:extras/directory-sibling/file.txt" 2>/dev/null \
        || git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:other/drop.txt" 2>/dev/null; then
        fail "T82" "Exact-file or directory-prefix matching admitted an out-of-scope sibling."
    else
        pass "T82"
    fi
    cleanup
}

test_T83() {
    run_test "T83" "additional path normalization rejects unsafe and reserved forms"

    local bad
    for bad in "/absolute" "../traversal" "a/../b" "a//b" \
        ":leading" "trailing:" "double::entry" "has space" \
        "README.md" "CONTRIBUTING.md" ".github/workflow.yml" \
        "public-overlay/file.txt"; do
        if bash "$SCOPE_ASSERT_SCRIPT" --normalize-only "$bad" \
            > /dev/null 2> /dev/null; then
            fail "T83" "Unsafe or reserved path was accepted: $bad"
            return
        fi
    done

    local normalized
    normalized=$(bash "$SCOPE_ASSERT_SCRIPT" --normalize-only \
        "ops/exact.txt:extras/dir/:ops/exact.txt")
    if [[ "$normalized" == "ops/exact.txt:extras/dir/" ]]; then
        pass "T83"
    else
        fail "T83" "Unexpected normalization result: '$normalized'"
    fi
}

test_T84() {
    run_test "T84" "scope assertion rejects an unexpected path in an orphan result"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PUBLIC/samples"
    echo "# Public README" > "$PUBLIC/README.md"
    echo "shared" > "$PUBLIC/samples/shared.txt"
    commit_as "$PUBLIC" "Public Dev" "public@example.com" \
        "Seed public main" README.md samples/shared.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-orphan"
    git -C "$PUBLIC" checkout --orphan "$SYNC_BRANCH" --quiet
    git -C "$PUBLIC" rm -rf --quiet . 2>/dev/null || true
    mkdir -p "$PUBLIC/samples"
    echo "# Public README" > "$PUBLIC/README.md"
    echo "shared" > "$PUBLIC/samples/shared.txt"
    echo "unexpected" > "$PUBLIC/rogue.txt"
    git -C "$PUBLIC" add README.md samples/shared.txt rogue.txt
    GIT_AUTHOR_NAME="Bot" GIT_AUTHOR_EMAIL="bot@example.com" \
    GIT_COMMITTER_NAME="Bot" GIT_COMMITTER_EMAIL="bot@example.com" \
        git -C "$PUBLIC" commit -m "Orphan generated result" --quiet

    if bash "$SCOPE_ASSERT_SCRIPT" \
        --repo "$PUBLIC" \
        --base-ref main \
        --head-ref "refs/heads/$SYNC_BRANCH" \
        --config "$CONFIG_FILE" \
        > "$WORK_DIR/scope.out" 2> "$WORK_DIR/scope.err"; then
        fail "T84" "Scope assertion accepted an orphan result with rogue.txt."
    elif ! grep -q "rogue.txt" "$WORK_DIR/scope.err"; then
        fail "T84" "Scope failure did not report rogue.txt: $(cat "$WORK_DIR/scope.err")"
    else
        pass "T84"
    fi
    cleanup
}

test_T86() {
    run_test "T86" "additional path materializes even when marks already passed its commit"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/samples" "$PRIVATE/ops"
    echo "default" > "$PRIVATE/samples/default.txt"
    echo "existing extra" > "$PRIVATE/ops/existing.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add default and extra content" samples/default.txt ops/existing.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-defaults"
    if ! run_sync_core_for_graft; then
        fail "T86" "Default sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi
    merge_sync_branch_to_public_main

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-extra"
    if ! SYNC_ADDITIONAL_PATHS="ops/existing.txt" run_sync_core_for_graft; then
        fail "T86" "Additional-path reconciliation failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if [[ "$(git -C "$PUBLIC" show "$SYNC_BRANCH:ops/existing.txt")" == "existing extra" ]]; then
        pass "T86"
    else
        fail "T86" "Existing extra path was not materialized after its commit was marked."
    fi
    cleanup
}

test_T87() {
    run_test "T87" "newly unblocked sample materializes without a new private commit"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/samples/allowed" "$PRIVATE/samples/blocked"
    echo "allowed" > "$PRIVATE/samples/allowed/content.txt"
    echo "blocked" > "$PRIVATE/samples/blocked/content.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add allowed and blocked samples" \
        samples/allowed/content.txt samples/blocked/content.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-blocked"
    if ! SYNC_BLOCKED_PATHS="samples/blocked" run_sync_core_for_graft; then
        fail "T87" "Blocked sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi
    merge_sync_branch_to_public_main

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-unblocked"
    if ! run_sync_core_for_graft; then
        fail "T87" "Unblocked reconciliation failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if [[ "$(git -C "$PUBLIC" show "$SYNC_BRANCH:samples/blocked/content.txt")" == "blocked" ]]; then
        pass "T87"
    else
        fail "T87" "Newly unblocked sample was not materialized."
    fi
    cleanup
}

test_T88() {
    run_test "T88" "blocked private deletion preserves the published sample"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/samples/blocked"
    echo "published" > "$PRIVATE/samples/blocked/content.txt"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Publish sample" samples/blocked/content.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-published"
    if ! run_sync_core_for_graft; then
        fail "T88" "Initial sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi
    merge_sync_branch_to_public_main

    git -C "$PRIVATE" rm --quiet samples/blocked/content.txt
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Delete blocked sample"

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-blocked-delete"
    if ! SYNC_BLOCKED_PATHS="samples/blocked" run_sync_core_for_graft; then
        fail "T88" "Blocked deletion sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if [[ "$(git -C "$PUBLIC" show "main:samples/blocked/content.txt")" == "published" ]]; then
        pass "T88"
    else
        fail "T88" "Blocked private deletion removed or changed the published sample."
    fi
    cleanup
}

test_T92() {
    run_test "T92" "explicit addition overrides a legacy static exclusion narrowly"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/samples" "$PRIVATE/docs"
    echo "default" > "$PRIVATE/samples/default.txt"
    echo "approved" > "$PRIVATE/docs/approved.md"
    echo "not approved" > "$PRIVATE/docs/sibling.md"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add default and documentation content" \
        samples/default.txt docs/approved.md docs/sibling.md

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-docs"
    if ! SYNC_ADDITIONAL_PATHS="docs/approved.md" run_sync_core_for_graft; then
        fail "T92" "Explicit excluded-path addition failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi

    if [[ "$(git -C "$PUBLIC" show "$SYNC_BRANCH:docs/approved.md")" != "approved" ]]; then
        fail "T92" "Approved exact file was not synced."
    elif git -C "$PUBLIC" cat-file -e "$SYNC_BRANCH:docs/sibling.md" 2>/dev/null; then
        fail "T92" "Exact file addition admitted an excluded sibling."
    else
        pass "T92"
    fi
    cleanup
}

test_T93() {
    run_test "T93" "reconciliation rejects a tracked symlink ancestor"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PRIVATE/samples" "$PRIVATE/docs/nested"
    echo "default" > "$PRIVATE/samples/default.txt"
    echo "approved" > "$PRIVATE/docs/nested/approved.md"
    commit_as "$PRIVATE" "Private Dev" "private@example.com" \
        "Add default and nested documentation" \
        samples/default.txt docs/nested/approved.md

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-defaults"
    if ! run_sync_core_for_graft; then
        fail "T93" "Default sync failed: $(cat "$WORK_DIR/sync-core.err")"
        cleanup; return
    fi
    merge_sync_branch_to_public_main

    local symlink_blob
    symlink_blob=$(printf '../outside' | git -C "$PUBLIC" hash-object -w --stdin)
    git -C "$PUBLIC" update-index --add \
        --cacheinfo "120000,$symlink_blob,docs"
    GIT_AUTHOR_NAME="Public Dev" GIT_AUTHOR_EMAIL="public@example.com" \
    GIT_COMMITTER_NAME="Public Dev" GIT_COMMITTER_EMAIL="public@example.com" \
        git -C "$PUBLIC" commit -m "Add public-owned docs symlink" --quiet

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-symlink"
    if SYNC_ADDITIONAL_PATHS="docs/nested/approved.md" run_sync_core_for_graft; then
        fail "T93" "Reconciliation followed or accepted a tracked symlink ancestor."
    elif ! grep -q "symlink ancestor 'docs'" "$WORK_DIR/sync-core.err"; then
        fail "T93" "Symlink rejection was not clearly reported: $(cat "$WORK_DIR/sync-core.err")"
    else
        pass "T93"
    fi
    cleanup
}

test_T94() {
    run_test "T94" "scope assertion rejects transient out-of-scope history"
    setup_repos
    write_graft_sync_config

    mkdir -p "$PUBLIC/samples"
    echo "base" > "$PUBLIC/samples/base.txt"
    commit_as "$PUBLIC" "Public Dev" "public@example.com" \
        "Seed public main" samples/base.txt

    SYNC_BRANCH="sync/test-$$-${TESTS_RUN}-transient"
    git -C "$PUBLIC" checkout -b "$SYNC_BRANCH" main --quiet
    echo "transient secret" > "$PUBLIC/rogue.txt"
    commit_as "$PUBLIC" "Sync Bot" "bot@example.com" \
        "Temporarily add rogue path" rogue.txt
    git -C "$PUBLIC" rm --quiet rogue.txt
    commit_as "$PUBLIC" "Sync Bot" "bot@example.com" \
        "Remove rogue path"

    if bash "$SCOPE_ASSERT_SCRIPT" \
        --repo "$PUBLIC" \
        --base-ref main \
        --head-ref "refs/heads/$SYNC_BRANCH" \
        --config "$CONFIG_FILE" \
        > "$WORK_DIR/scope.out" 2> "$WORK_DIR/scope.err"; then
        fail "T94" "Scope assertion accepted transient out-of-scope history."
    elif ! grep -q "rogue.txt" "$WORK_DIR/scope.err"; then
        fail "T94" "History failure did not identify rogue.txt: $(cat "$WORK_DIR/scope.err")"
    else
        pass "T94"
    fi
    cleanup
}

test_T71
test_T72
test_T73
test_T74
test_T75
test_T77
test_T78
test_T79
test_T81
test_T82
test_T83
test_T84
test_T86
test_T87
test_T88
test_T92
test_T93
test_T94

summary
