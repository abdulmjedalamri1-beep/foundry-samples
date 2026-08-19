# Sync Incident Response

Authoritative playbook for diagnosing and recovering from `sync-to-public` pipeline failures.
Read this file completely before taking any action when a sync run fails.

## 1. Get the failure log

```bash
# View the run summary — identify which job/step failed
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr

# Download the full log (pipe to a file — it can be 50–100KB)
gh run view <run-id> --repo microsoft-foundry/foundry-samples-pr --log > /tmp/sync-run.log
```

The failing step is almost always **"Run sync pipeline"** which calls `sync-core.sh`.
Check `public-overlay/.github/scripts/mirror-back.sh` failures separately via the
`mirror-back` workflow (`microsoft-foundry/foundry-samples` Actions tab).

---

## 2. Identify the failure type

Run these greps against the log in order:

```bash
# Type A — marks drift / object not found
grep -E "object not found|seed-marks recovery|Tree mismatch|fatal:" /tmp/sync-run.log

# Type B — protected-paths guard
grep "Protected-paths guard" /tmp/sync-run.log

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
| `Protected-paths guard FAILED` | Protected-paths | §4 |
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
| Public has a blob private doesn't (`+` lines only) | Mirror-back dropped a commit | Bring change to private via PR, then seed or `force_full` |
| Private has a blob public doesn't (`-` lines only), or phantom blob exists in neither repo | Bad manual seed (corrupt marks) | `force_full` — do NOT seed again |
| Both directions | Mixed/complex drift | `force_full` |

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

> **Default to `force_full`.** It is always safe when private is authoritative. Use
> `seed_from_public_sha` only when you have a specific reason to preserve public
> commit history (e.g. a legitimate change landed on public that isn't in private yet).

| Scenario | Recovery action |
|----------|----------------|
| Private is correct, public regressed | `workflow_dispatch` → `force_full: true` ← **preferred** |
| Public has a legitimate change not yet in private | Bring to private via PR → merge → `seed_from_public_sha=<public-HEAD>` |
| Trees differ only due to historical block-list | `seed_from_public_sha=<public-HEAD>` + `seed_blocked_paths=<list>` — **read warning below** |

**`force_full` details:** Discards the marks cache entirely and does a full re-export
from private. Overwrites public with private's view. Safe when private is authoritative
and public regressed. Triggered via:
```bash
gh workflow run sync-to-public.yml \
  --repo microsoft-foundry/foundry-samples-pr \
  --field force_full=true
```

**`seed_from_public_sha` details:** Re-synthesizes marks from a known-good public SHA
by requiring the trees to be equivalent (or equivalent modulo `seed_blocked_paths`).
Use when you first fix the drift in private, then want to re-anchor without losing history.

> ⚠️ **`seed_blocked_paths` warning:** Only supply this when the tree mismatch is in
> paths that were **historically excluded from sync** (e.g. a sample that was block-listed
> during a prior period and never appeared on public). Do **not** use it to silence a
> mismatch caused by real content divergence — that will corrupt the marks cache and
> cause phantom-blob failures on subsequent syncs. If you're unsure whether the mismatch
> is historical or real, use `force_full` instead. The seed script logs a warning
> whenever `seed_blocked_paths` is in use; check the run log to confirm the bypassed
> paths are what you expect.
>
> If `seed_from_public_sha` fails with "Tree mismatch" and you did **not** expect any
> historically-blocked paths, **stop and use `force_full`** — do not add `seed_blocked_paths`
> to make the seed pass.

---

## 4. Protected-paths guard failure

The guard refused to push because the sync branch would delete or modify a
public-only workflow file (`redirect-pull-requests.yml`, `mirror-back.yml`, or `run-setup.yml`).

Recovery:
1. If the workflow is missing from public main, restore it via a direct human PR on public first.
2. Then re-anchor marks: `workflow_dispatch` → `seed_from_public_sha=<new-public-HEAD>`.

Full procedure in `docs/sync-cutover-runbook.md` and the
[Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md).

---

## 5. Mirror-back false-positive

Mirror-back (`public-overlay/.github/scripts/mirror-back.sh`) skips commits whose
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

The `fix-unmapped-emails` workflow is manual-only during the public-first cutover. It
opens or updates a mailmap fix PR only when an operator dispatches it.

### What happened

A commit in private `main` carries a `@microsoft.com` author or committer email that
isn't in `.github/sync-mailmap`. The sync is fail-closed: it refuses to leak internal
email addresses to the public repo.

### Recovery

> ⚠️ **Do NOT use `seed_from_public_sha` or `force_full` for this failure type.**
> Those are marks-recovery operations. Using them here is unnecessary and can introduce
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

## 7. Ghost import — blob false-positive

### What happened

All commits between the marks-cache seed point and private HEAD touched only excluded
paths (`.github/`, `docs/`, etc.). The filter correctly dropped every commit block,
but blob objects always pass through `filter-stream.py`. One of those blobs contained
text that matched the `stream_has_commits` heuristic (previously `grep "^commit "`,
now a two-line awk pattern). `git fast-import` processed a blob-only stream, exited 0
without creating any ref, and the pipeline set `has_imports=1` falsely. When
`apply_public_overlay` tried to check out the sync branch, it crashed:

```
ERROR: imports reported but refs/heads/sync/private-to-public-... is missing (public-overlay)
```

### Diagnosis

1. Check what commits exist between the last-synced private SHA and current HEAD:
   ```bash
   git log --oneline <last_synced_sha>..HEAD
   ```
2. Verify they all touch excluded paths:
   ```bash
   git diff --name-only <last_synced_sha>..HEAD
   ```
   Cross-reference with `.github/sync-config.json` → `exclude_pathspecs`.
3. Check the filtered stream for blob content that could false-positive:
   ```bash
   grep -n "^commit refs/" /tmp/filtered-stream  # should be zero for this failure type
   ```

### Recovery

After PR #665 merged, this failure type should not recur:
- `stream_has_commits` uses a two-line awk pattern (`commit refs/...` + `mark :`) that
  is extremely unlikely to appear in blob data.
- `run_fast_import` verifies the target ref was created; returns exit code 2 if not,
  which correctly sets `has_imports=0`.

If it somehow recurs:
- **Do NOT use `force_full` or `seed_from_public_sha`** — the marks are fine.
- The next run with real (non-excluded) commits will succeed normally.
- If urgent: manually trigger a re-run; if the same excluded-only commits are HEAD,
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
| `public-overlay/.github/scripts/mirror-back.sh` | Runs on public repo; detects human commits and opens mirror PRs in private |
| `.github/tests/test-mirror-back.sh` | Unit test harness for mirror-back; bash, stubbed `gh`, runs via WSL |
| `.github/tests/test-sync.sh` | Sync test suite; T76 covers blob false-positive regression |
| `.github/sync-config.json` | Public repo target, exclude list, protected paths |
| `docs/repo-sync-automation.md` | Authoritative design doc — marks cache, mirror-back, recovery inputs, troubleshooting |
| `docs/sync-cutover-runbook.md` | One-time surgery procedure (not for routine incidents) |

---

## 9. Running the mirror-back tests

```bash
# From the repo root (WSL required on Windows)
bash .github/tests/test-mirror-back.sh
```

Tests: MB1 clean replay, MB2 no-identity filter, MB3 bot-skip, **MB4 human-author+bot-committer (regression for #620)**, MB5 idempotency, MB6 dry-run, MB7 zero-before, MB8 helpers, MB9 conflict.
