# Sync Incident Response

Authoritative playbook for diagnosing and recovering from failures in the operator-run private-to-public bridge.
Read this file completely before taking any action when a sync run fails.

## 1. Get the failure log

```bash
# View the run summary — identify which job/step failed
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr

# Download the full log (pipe to a file — it can be 50–100KB)
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr --log > /tmp/sync-run.log
```

The failing step is almost always **"Run sync pipeline"** which calls `sync-core.sh`.
Mirror-back is public-owned automation; check its failures separately via the
`mirror-back` workflow in the `microsoft-foundry/foundry-samples` Actions tab.

---

## 2. Identify the failure type

Run these greps against the log in order:

```bash
# Type A — marks drift / object not found
grep -E "object not found|seed-marks recovery|Tree mismatch|fatal:" /tmp/sync-run.log

# Type B — generated-diff scope guard
grep -E "Generated-diff|scope guard|out-of-scope|reserved path" /tmp/sync-run.log

# Type D — unmapped internal email
grep "Unmapped internal email" /tmp/sync-run.log

# Type E — ghost import (stream_has_commits false-positive)
grep "imports reported but.*is missing" /tmp/sync-run.log

# Type C — mirror-back workflow (check separately on PUBLIC repo)
# Go to https://github.com/microsoft-foundry/foundry-samples/actions/workflows/mirror-back.yml
# Look for "Skipping sync-App commit" in recent successful(!)-but-wrong runs
```

| Signal in log | Failure type | Jump to |
|---------------|-------------|---------|
| `object not found: <sha>` during fast-import | Marks drift | §3 |
| `seed-marks recovery failed — likely true drift` | Marks drift | §3 |
| Generated-diff guard reports an out-of-scope or reserved path | Scope guard | §4 |
| `mirror-back` run on public shows `Skipping sync-App commit <sha>` for a human commit | Mirror-back false-positive | §5 |
| `Unmapped internal email: <alias> <email@microsoft.com>` | Unmapped email | §6 |
| `imports reported but refs/heads/sync/... is missing` | Ghost import (blob false-positive) | §7 |

---

## 3. Marks drift — diagnosis and recovery

### What happened

The marks cache references a blob that doesn't exist in the runner's clone of the
public repo. Two known causes:

1. **Mirror-back silently dropped a public commit** — a human commit landed directly
   on public, mirror-back failed to open a mirror PR, and the next sync expected that
   blob to exist on public but it doesn't. Public is *ahead* of private on affected files.

2. **Bad manual seed recovery** — a prior `seed_from_public_sha` run bypassed the
   tree-equivalence check (via `seed_blocked_paths`) against a mismatched anchor. The
   seed "succeeded" but wrote marks referencing blobs that were never part of any real
   public tree. Those blobs become unreachable and get GC'd; the marks still point to
   them. Private is *ahead* of public on affected files. This was the root cause of the
   **2026-07-04 incident**.

### Diagnose the tree mismatch

The seed-marks recovery script prints a diff of what private and public think a
file should contain. Look for lines like:

```
@@  private.tree   public.tree
-   <sha1>   samples/path/to/file   (private blob)
+   <sha2>   samples/path/to/file   (public blob)
```

**Read the diff direction to identify the cause:**

| Diff shows | Likely cause | Recovery |
|-----------|-------------|----------|
| Public has a blob private doesn't (`+` lines only) | Mirror-back dropped a commit | Bring the change to private via PR, then seed equivalent reviewed SHAs |
| Private has a blob public doesn't (`-` lines only), or phantom blob exists in neither repo | Bad manual seed (corrupt marks) | Reconcile through reviewed PRs, then seed equivalent reviewed SHAs |
| Both directions | Mixed/complex drift | Reconcile each private-owned difference through reviewed PRs, then seed equivalent reviewed SHAs |

### Confirm mirror-back dropped the commit

*Only follow this path if the diff shows public ahead of private (cause 1 above).*

1. Find the public commit SHA that introduced the diverging blob (check public repo history).
2. Find the corresponding `mirror-back` workflow run on the public repo.
3. In that run's log, grep for:
   ```
   Skipping sync-App commit <sha>
   ```
   If present, mirror-back falsely classified a human PR as a bot commit. This was the
   root cause in the **2026-06-29 incident** (ADO 5398977, fixed in PR #620).

### Recovery decision table

> The workflow has no full-tree replacement or direct-public-main recovery mode.
> Reconcile content through reviewed PRs, then use verified seed recovery. Always run
> recovery with `dry_run=true` first.

| Scenario | Recovery action |
|----------|----------------|
| Private-owned content differs | Reconcile through a reviewed PR, then seed matching public/private SHAs |
| Public has a legitimate change not yet in private | Bring to private via PR → merge → seed matching public/private SHAs |
| Trees differ only due to historical block-list | Seed matching SHAs with `seed_blocked_paths=<list>` — **read warning below** |

**`seed_from_public_sha` details:** Re-synthesizes marks from a known-good public SHA
by requiring the trees to be equivalent (or equivalent modulo `seed_blocked_paths`).
Supply `seed_from_private_sha` when the equivalent private commit is older than private
HEAD. Use `dry_run=true` first; proceed only after the tree-equivalence check passes.

> ⚠️ **`seed_blocked_paths` warning:** Only supply this when the tree mismatch is in
> paths that were **historically excluded from sync** (e.g. a sample that was block-listed
> during a prior period and never appeared on public). Do **not** use it to silence a
> mismatch caused by real content divergence — that will corrupt the marks cache and
> cause phantom-blob failures on subsequent syncs. The seed script logs a warning
> whenever `seed_blocked_paths` is in use; check the run log to confirm the bypassed
> paths are what you expect. If you are unsure whether the mismatch is historical or
> real, stop and reconcile it; do not expand `seed_blocked_paths`.
>
> If `seed_from_public_sha` fails with "Tree mismatch" and you did **not** expect any
> historically-blocked paths, **stop** — do not add `seed_blocked_paths` to make the
> seed pass. Reconcile the reviewed content until the normal equivalence check succeeds.

---

## 4. Generated-diff scope guard failure

The generated branch contains a path outside `infrastructure/**`, `samples/**`,
and the run's valid `additional_paths`, or it touches a reserved path:
`README.md`, `CONTRIBUTING.md`, `.github/**`, or `public-overlay/**`.

Recovery:

1. Read the guard output and identify whether it failed before push or immediately before merge.
2. For public metadata, open a normal public PR. Do not restore an overlay or add a reserved path to `additional_paths`.
3. For an approved non-reserved path, correct `additional_paths`: colon-separated entries, trailing `/` for a directory prefix, no trailing `/` for one exact file.
4. Start with `dry_run=true`. A successful dry run pushes `sync/dry-run-*` for inspection but creates no PR, performs no merge, and does not update marks.
5. If fresh public `main` introduced real divergence, reconcile through reviewed PRs before using verified seed recovery.

A pre-push failure creates no remote branch or PR. A pre-merge failure leaves the
existing PR unmerged and does not update marks. Full scope and failure semantics
are in [Repo Sync Automation](../../docs/repo-sync-automation.md#generated-diff-scope-guard).

---

## 5. Mirror-back false-positive

Mirror-back (`microsoft-foundry/foundry-samples:.github/scripts/mirror-back.sh`) skips commits whose
**author** matches a sync-bot identity. It does NOT skip based on committer alone.

Relevant identities (`PRIMARY_SYNC_BOT` / `LEGACY_SYNC_BOT` at top of script):
```
PRIMARY_SYNC_BOT = foundry-samples-repo-sync[bot]
LEGACY_SYNC_BOT  = foundry-samples-sync[bot]
```
(and their corresponding `@users.noreply.github.com` emails — check lines 9–10 of the script for current values)

**Known edge case:** When `wait-and-merge.sh` calls `gh pr merge --rebase` as the App,
GitHub records the App as the **committer** but preserves the human as the **author**.
Pre-fix (before PR #620), mirror-back checked all four identity fields and would skip
these commits. Post-fix, only author is checked, so human-authored commits always
produce a mirror branch regardless of committer.

If you suspect other human public PRs were silently dropped before the fix (merged
between ~2026-06-04 and 2026-06-29), audit public repo commits in that range:
```bash
gh api repos/microsoft-foundry/foundry-samples/commits \
  --paginate --jq '.[] | {sha: .sha, author: .author.login, committer: .committer.login, msg: .commit.message}' \
  | grep -v '"author":"foundry-samples-repo-sync\[bot\]"'
```
Any commit whose author is human but that has no corresponding private-side mirror
was likely silently dropped.

---

## 6. Unmapped internal email

### Signal

The "Run sync pipeline" step fails with:

```
Unmapped internal email: <alias> <email@microsoft.com>
```

The `fix-unmapped-emails` workflow is manual-only. It
opens or updates a mailmap fix PR only when an operator dispatches it.

### What happened

A commit in private `main` carries a `@microsoft.com` author or committer email that
isn't in `.github/sync-mailmap`. The sync is fail-closed: it refuses to leak internal
email addresses to the public repo.

### Recovery

> ⚠️ **Do NOT use `seed_from_public_sha` for this failure type.**
> That is a marks-recovery operation. Using it here is unnecessary and can introduce
> marks corruption (see §3 recovery decision table). The marks are fine — just the
> email is missing.

1. Check if `fix-unmapped-emails` already opened a PR:
   ```bash
   gh pr list --repo microsoft-foundry/foundry-samples-pr --search "fix-unmapped-emails" --state open
   ```
2. **If no PR exists:** manually dispatch `fix-unmapped-emails.yml` with the default
   `scan_range`, then check again for the generated PR.
3. **If a PR is open:** review and merge it. If the workflow cannot resolve the missing
   identity, add the entry to `.github/sync-mailmap` in a manually reviewed PR instead.
4. **Verify:** rerun the reviewed sync procedure manually, starting with `dry_run=true`.
   Neither a sync failure nor a push to `main` triggers an automatic retry.

### Prevention

The `mailmap-precheck` CI check (`Check author/committer/trailer emails`) is a required
status check on the `main` ruleset. New contributors must add their mailmap entry in
their own PR — the check blocks merges until they do. If this failure recurs, verify the
ruleset is still enforcing the check:
```bash
gh api repos/microsoft-foundry/foundry-samples-pr/rulesets/9151848 \
  --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks'
```

---

## 7. Historical ghost import — blob false-positive

### What happened

All commits between the marks-cache seed point and private HEAD touched only paths
outside the then-active publication scope. The filter correctly dropped every commit block,
but blob objects always pass through `filter-stream.py`. One of those blobs contained
text that matched the `stream_has_commits` heuristic (previously `grep "^commit "`,
now a two-line awk pattern). `git fast-import` processed a blob-only stream, exited 0
without creating any ref, and the pipeline set `has_imports=1` falsely. When
the now-retired `apply_public_overlay` step tried to check out the sync branch, it crashed:

```
ERROR: imports reported but refs/heads/sync/private-to-public-... is missing (public-overlay)
```

### Diagnosis

1. Check what commits exist between the last-synced private SHA and current HEAD:
   ```bash
   git log --oneline <last_synced_sha>..HEAD
   ```
2. Verify they all touch paths outside the positive scope:
   ```bash
   git diff --name-only <last_synced_sha>..HEAD
   ```
   Compare with `infrastructure/**`, `samples/**`, and that run's `additional_paths`.
3. Check the filtered stream for blob content that could false-positive:
   ```bash
   grep -n "^commit refs/" /tmp/filtered-stream  # should be zero for this failure type
   ```

### Recovery

After PR #665 merged, this historical failure type should not recur:
- `stream_has_commits` uses a two-line awk pattern (`commit refs/...` + `mark :`) that
  is extremely unlikely to appear in blob data.
- `run_fast_import` verifies the target ref was created; returns exit code 2 if not,
  which correctly sets `has_imports=0`.

If it somehow recurs:
- **Do NOT use `seed_from_public_sha`** — the marks are fine.
- The next run with real in-scope commits will succeed normally.
- If urgent: manually trigger a re-run; if the same out-of-scope-only commits are HEAD,
  the fixed code will exit cleanly with `has_changes=false`.

> ℹ️ **Historical note:** First observed 2026-07-07. The triggering blob was
> `docs/repo-sync-automation.md` which contained the text "commit gets a private
> branch named..." — matching the old `grep "^commit "` pattern.

---

## 8. Key files reference

| File | Purpose |
|------|---------|
| `.github/scripts/sync-core.sh` | Main sync driver; marks cache load/save, `git fast-import`, auto seed-marks recovery |
| `.github/scripts/seed-marks-from-public.sh` | Synthesizes fresh marks from a known-good public SHA; called by sync-core and manually via `seed_from_public_sha` input |
| `microsoft-foundry/foundry-samples:.github/scripts/mirror-back.sh` | Public-owned helper that detects human commits and opens mirror PRs in private |
| `.github/tests/test-sync.sh` | Sync test suite; T76 covers blob false-positive regression |
| `.github/sync-config.json` | Default positive scope, reserved paths, and public repo target |
| `docs/repo-sync-automation.md` | Authoritative design doc — scope, guards, marks cache, recovery inputs, and troubleshooting |
| `docs/sync-cutover-runbook.md` | Historical one-time surgery record (not for routine incidents) |
