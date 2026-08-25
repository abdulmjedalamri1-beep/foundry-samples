# Repo Sync Automation

This document describes the automated sync pipeline that publishes content from `foundry-samples-pr` (private) to `foundry-samples` (public).

It owns the **sync workflow mechanics**: export/import, path exclusions, author rewriting, App-authenticated PR creation, wait-and-merge, drift verification, and the sync-time validation gate. The validation rules themselves live in [Validation Contract](validation-contract.md). The contract for pipelines that post validation statuses lives in [Validation Results Contract](validation-results-contract.md).

## Overview

```text
foundry-samples-pr (private)  ─── manual sync ────►  foundry-samples (public)
       ▲                                                   │
       │  Authors push here                                │  Customers read here
       │  Validation statuses live here                    │  Issues filed here
       │  Internal content lives here                      │
       └──── review PRs for non-sync-App public commits ◄──┘
```

- **Primary direction**: Private → Public. Private `main` remains the authoritative integration point.
- **Mirror-back exception**: Non-sync-App commits that land directly on public `main` open review PRs back to private; they are never auto-merged.
- **Trigger**: Manual `workflow_dispatch` only for private→public sync; push to public `main` + manual dispatch for public→private mirror-back.
- **Mechanism**: private→public uses `git fast-export` / `git fast-import` with path filtering and author rewriting; public→private replays individual public commits as private PR branches.
- **Validation gate**: Before push, the sync gate filters out samples whose validation has not passed at the private `main` SHA being synced.
- **Automation**: GitHub Actions workflow in `.github/workflows/sync-to-public.yml` for private→public, plus public-overlay workflow `.github/workflows/mirror-back.yml` for public→private PR creation.

High-level flow:

```text
private main
  └─ read validation/* statuses on private HEAD
      └─ build per-run blocked-sample exclusions
          └─ fast-export with static + dynamic exclusions
              └─ filter stream / rewrite authors
                  └─ fast-import into public sync branch
                      └─ push branch / open PR / direct rebase merge as App
```

## How It Works

### 1. Evaluate sync gate

At the start of a sync run, the workflow evaluates validation statuses on the private commit being synced, normally `main` HEAD:

```bash
gh api repos/microsoft-foundry/foundry-samples-pr/commits/<sha>/status
```

Statuses whose context matches `validation/*` are interpreted according to [Validation Results Contract](validation-results-contract.md). The gate produces a per-run list of sample roots to hold back from public sync.

This list is **additional** to the static path exclusions in `.github/sync-config.json`. Static exclusions protect internal repo content. Dynamic gate exclusions hold back otherwise-syncable samples until validation is green.

### 2. Export and filter

The sync uses `git fast-export` to stream commits from the private repo, piped through a Python filter (`filter-stream.py`) that:

- Removes excluded paths from both sources:
  - static exclusions from `.github/sync-config.json`
  - dynamic per-run exclusions from the sync gate
- Rewrites author identities using `.github/sync-mailmap` (maps internal aliases to public-facing names)
- Preserves commit history structure where possible (merge commits, ordering)

### 3. Import into public repo

The filtered stream is imported into the public repo via `git fast-import`, creating a sync branch with the rewritten history.

### 4. Incremental sync via marks

The pipeline uses `git fast-export` / `fast-import` marks files to track what's already been synced. These are cached between runs, making subsequent syncs incremental — only new commits are processed.

The first publication to an empty public repository performs a bootstrap export. Once public `main` exists, missing, invalid, or incompatible marks fail closed before any remote mutation. Recovery must use `seed_from_public_sha` (and, when needed, `seed_from_private_sha`) to establish a verified incremental anchor.

Dynamic gate exclusions are per-run state, not durable repo policy. When a blocked sample later becomes unblocked, the next incremental sync includes the now-eligible changes without replacing the public tree.

### 5. Push and PR

The sync branch is pushed to the public repo and a PR is created automatically:

- Stale sync PRs are closed first
- The new PR includes commit count, authors, and a rollback SHA
- The PR body lists the contributing authors verbatim from rewritten commits

### 6. Wait-and-merge (direct merge as the App)

After the PR is opened, `wait-and-merge.sh` polls the PR's check status and required-review state. Once all required checks pass and reviews are satisfied, the workflow performs a **direct rebase merge** as the GitHub App — it does **not** use `gh pr merge --auto`.

This matters because of how GitHub's branch ruleset bypass interacts with the merge queue. See [Public Repo Branch Protection & App Bypass](#public-repo-branch-protection--app-bypass) below for the full rationale; the short version is that `--auto` schedules the merge for GitHub's system process, which does not inherit the App's bypass-actor permission, so the merge gets blocked by required-reviews even though the App could merge directly.

## The Gate at Sync Time

The sync gate is a **per-sample block-list**. Default = sync. A sample is blocked only when a validation status says it is not safe to publish.

| Input | Behavior |
|-------|----------|
| `validation/<pipeline-id>/<sample-path>` = `success` | Does not block that sample. |
| `validation/<pipeline-id>/<sample-path>` = `failure` | Blocks that sample. |
| `validation/<pipeline-id>/<sample-path>` = `error` | Blocks that sample. |
| `validation/<pipeline-id>/<sample-path>` = `pending` | Blocks that sample; do not publish while validation is in progress. |
| No `validation/*` status for a sample | Grandfathered / untracked; does not block in v1. |

Rules:

1. The workflow queries the combined commit status for the private SHA being synced.
2. Only contexts matching `validation/*` participate in sync gating.
3. The sample path is parsed from the context convention defined in [Validation Results Contract](validation-results-contract.md).
4. If any validation context for a sample is `failure`, `error`, or `pending`, that sample root is added to the block-list.
5. The block-list is converted into per-run additional path exclusions.
6. The additional exclusions are layered on top of `.github/sync-config.json`.
7. Samples with no reporting pipeline are grandfathered: untracked = ungated.

Example:

```text
validation/ado-build/samples/python/quickstart-chat = success
validation/hosted-agents-e2e/samples/python/hosted-agents/echo-agent = pending
validation/ado-build/samples/python/hosted-agents/echo-agent = success
```

Result: `samples/python/quickstart-chat` can sync. `samples/python/hosted-agents/echo-agent` is held back because one reporting pipeline is still pending.

## Implementation Surface (v1)

The minimum implementation surface is intentionally small and additive.

| Component | Responsibility |
|-----------|----------------|
| Status reader | `.github/scripts/parse-validation-statuses.sh` parses a GitHub combined commit-status payload and emits colon-separated repo-relative paths whose latest validation status is `failure`/`error`/`pending`. |
| Block-list computer | `.github/scripts/compute-blocklist.sh` is the shared entry point used by both sync-to-public.yml and verify-sync.yml. It fetches the statuses for `<repo>@<sha>` (with retry/backoff and fail-closed semantics per §8 Q5), pipes them through the parser, and prints the SYNC_BLOCKED_PATHS value. Per-pipeline reporter counts are written to stderr for the run summary. |
| Dynamic exclusions | `sync-core.sh` consumes `SYNC_BLOCKED_PATHS` (colon-separated repo-relative path roots; empty entries tolerated; leading `./` and trailing `/` normalized; missing paths ignored) and layers it on top of the static `exclude_pathspecs` from `.github/sync-config.json`. |
| Drift verification | `verify-sync.yml` independently invokes `compute-blocklist.sh` for the same SHA and passes the result to `verify-sync.sh` via `SYNC_BLOCKED_PATHS`. Block-list paths are skipped on **both** the expected (private) and actual (public) sides, matching the bidirectional behavior of the static exclude list. |
| Bypass / kill-switch | `sync-to-public.yml` exposes three `workflow_dispatch` inputs: `bypass_samples` (colon-separated paths to force-include), `bypass_reason` (required when bypass is used), and `bypass_gate` (full bypass). Bypass usage is loud: a banner appears in `$GITHUB_STEP_SUMMARY`, the resulting PR body has a footer block, and (if `vars.BYPASS_LOG_ISSUE_NUMBER` is set) the workflow auto-comments on a permanent "Validation gate bypass log" tracking issue. Bypass is per-run; nothing is persisted. |
| Run summary | Every sync run emits a job summary with private SHA, bypass mode, tracked-sample count, blocked-sample count, the blocked path list, and the raw stderr from `compute-blocklist.sh` (per-pipeline reporter counts for grandfather visibility). |

## Exclusions

Static paths excluded from sync are defined in `.github/sync-config.json`:

```json
{
  "exclude_pathspecs": [
    ":!internal/",
    ":!docs/",
    ":!.azure-pipelines/",
    ":!.github/",
    ":!CONTRIBUTING.md",
    ":!README.md",
    ":!public-overlay/"
  ]
}
```

`.github/sync-config.json` is the authoritative source; the example above is illustrative. If the two ever disagree, the JSON file wins.

| Excluded path | Reason |
|---------------|--------|
| `internal/` | Internal tooling, scripts, and docs not for public consumption |
| `docs/` | Internal governance, validation, and sync documentation |
| `.azure-pipelines/` | ADO pipeline config (CI infra is private) |
| `.github/` | Workflows, sync scripts, and config (sync infra is private) |
| `CONTRIBUTING.md` | Private-repo contributing guide (public repo has its own) |
| `README.md` | Private-repo README (public repo has its own) |
| `public-overlay/` | Private-only staging area for content that overlays the public repo via a separate process |

Dynamic validation exclusions are generated at sync time. They must not be added to `.github/sync-config.json` unless the path should be permanently internal.

### Basename exclusions

`exclude_pathspecs` matches by path *prefix*, so it cannot exclude a scattered marker file that appears in many sample directories. For those, `.github/sync-config.json` has an optional `exclude_basenames` key matched against each file's final path component, anywhere in the tree:

```json
{
  "exclude_basenames": [
    ".ci-skip",
    ".code-ci-skip"
  ]
}
```

| Excluded basename | Reason |
|-------------------|--------|
| `.ci-skip` | Per-sample CI marker that excludes a sample from the hosted-agents cloud E2E matrix; internal CI control, not for public consumption |
| `.code-ci-skip` | Per-sample CI marker that drops only the code-deploy arm of the cloud E2E matrix; internal CI control |

Semantics and rationale:

- **Where it runs.** `sync-core.sh` reads `exclude_basenames` (`build_filter_exclude_basenames`) and passes each as `filter-stream.py --exclude-basename`, alongside the prefix-based `--exclude-path` args. Like prefix exclusions, this filters file-op deltas (M/D/R/C) in delta mode, so the next `fast-import` inherits any prior content for those paths from the marks-anchored parent.
- **Not folded into `pathspec.hash`.** Unlike `exclude_pathspecs`, changing `exclude_basenames` does **not** invalidate the marks cache. This is deliberate: changing the durable static include-set requires a reviewed seed re-anchor, while basename exclusions are safe to apply as incremental delta filters. Basename excludes therefore take effect on the next incremental sync without disrupting the marks anchor — matching how the dynamic block-list is handled.
- **No retroactive removal.** Because excluded-path content is inherited from the parent, adding a basename only stops *future* syncing of matching files. Marker files already present on public remain public-owned and must be changed through a reviewed public PR when cleanup is required. New marker files added in private after this list is in effect are never synced.
- **Drift checks.** `verify-sync.sh` applies the same basenames bidirectionally, so neither private nor public marker files register as drift.


### What IS synced

Everything not in the static exclusion list and not blocked by validation, primarily:

- `samples/` — sample code that is either passing validation or untracked / grandfathered
- `CODEOWNERS` — ownership mappings, handled specially despite `.github/` exclusion
- `public-overlay/` — files at `public-overlay/<path>` are restored to public `<path>` after import (see [Public-overlay mechanism](#public-overlay-mechanism)). **Note:** GitHub Actions workflow files (`.github/workflows/*.yml`) are *not* delivered via overlay; they live directly on public main, and the [Protected-paths guard](#protected-paths-guard) prevents sync runs from deleting or modifying them.
- Any other top-level public content, such as `LICENSE`

## Public-overlay mechanism

Some files only exist on the public side: the public-facing `README.md` and
`CONTRIBUTING.md`, public-only `.github/workflows/`, and similar repository
metadata. They are excluded from the sync stream by `.github/sync-config.json`
so private edits don't clobber them, but that exclusion alone is fragile —
`git fast-import` does not merge with prior public state, so any path missing
from the import stream is wiped on a fresh-marks rebuild.

The **public-overlay** directory in the private repo is the durable record of
those files. After import, sync-core walks `public-overlay/`, copies each file
to the corresponding public path (i.e. `public-overlay/README.md` →
`README.md`), and either amends the imported commit or creates a standalone
bot commit (matching the `apply_codeowners` pattern). Because the overlay is
checked back into the private repo on every change, it survives mark resets
and remains the authoritative source for public-only content.

Mechanics:

- The directory `public-overlay/` itself is excluded from the sync stream
  (`":!public-overlay/"` in `exclude_pathspecs`) so it never appears in the
  public repo as a directory.
- `sync_public_overlay()` reports a pre-import change when any file under
  `public-overlay/` differs from the public branch (or is missing on public).
  That check is only a no-op short-circuit when there are no imports; after a
  successful import, the overlay is restored even if it matched public before
  the import.
- `apply_public_overlay()` runs **before** `apply_codeowners()` so a
  CODEOWNERS amend can still be the final state on the imported commit.
- Both functions use the same `foundry-samples-sync[bot]` identity for
  consistent authorship.
- File modes are preserved (`cp -p`) and special-character paths are handled
  via `find -print0`.

Tracked under Feature 5255019. Consolidating the CODEOWNERS handler into the
overlay mechanism (so CODEOWNERS lives at `public-overlay/.github/CODEOWNERS`)
is tracked separately as Task 5255035 and is intentionally deferred.

### What does NOT live in `public-overlay/`

**GitHub Actions workflow files** (`.github/workflows/*.yml`). Earlier
attempts to put public-facing workflows under `public-overlay/.github/workflows/`
led to repeated wipes (2026-06): the App's push of a sync
branch that included workflow content interacted badly with private-side
automation and orphan-recovery code paths in ways that produced sync
branches missing those files. The lesson is that workflow files do not
belong in the sync pipeline at all — neither as part of the filtered
private stream nor as overlay-restored content.

Instead, workflows are authored as direct commits on public main (human
PRs only). They are preserved across syncs by fast-import's marks-
anchored ancestry — each sync branch inherits the parent tree from the
previous sync's commit, which in turn inherited public's workflows.

The fragility of "marks-anchored ancestry inherits public workflows" is
exactly what the [Protected-paths guard](#protected-paths-guard) backstops.
When orphan-recovery code paths produce a sync branch without that
ancestry, the guard fires before push and blocks the wipe.

## Protected-paths guard

`sync-core.sh` runs a final invariant check after the sync branch is fully
built (post-overlay, post-CODEOWNERS) and before emitting `has_changes=true`.
For every path listed in `sync-config.json`'s `protected_paths` array, it
simulates the prospective rebase-merge of the sync branch into public main
(via `git merge-tree --write-tree`, requires git ≥ 2.38) and compares the
blob SHA on fresh `origin/main` against the blob SHA on the *resulting*
merged tree. Any deletion or content drift in the post-merge result
hard-fails the sync.

Why simulate the merge instead of inspecting the sync-branch tip directly:
under the original design `git fast-export --import-marks` combined with
pathspec filters forced `--full-tree` mode, so the sync branch's tree
never contained files outside the include-set (e.g., `.github/`) — even
when the eventual rebase-merge into public main would preserve those files
unchanged. A blob comparison against the sync-branch tip would therefore
hard-fail every incremental sync once a protected file existed on public
main, regardless of whether the merge would actually disturb it.

Under the post-ADO 5347427 fix the exclude filter runs in
`filter-stream.py` against fast-export's delta-mode output instead, so
the sync branch's tree *does* inherit excluded paths from its
marks-anchored parent. The merge-tree simulation is still the right
ground truth, however: the sync-branch parent's tree (and therefore the
inherited blob) can lag current `origin/main` whenever a human PR has
landed since the marks were last anchored, or when seed-marks-recovery
re-anchors the marks at a public commit that public main has since
advanced past. `merge-tree --write-tree` lets us inspect the
post-rebase-merge tree itself, which is what GitHub will produce when
the sync PR auto-merges. See ADO 5347121 / 5347427 for the full
write-ups.

### What's protected (as of 2026-08)

```json
"protected_paths": [
  ".github/workflows/mirror-back.yml",
  ".github/workflows/run-setup.yml"
]
```

These are the public-only workflow files that have been wiped in past
orphan-recovery incidents. Add a path here when:

1. The file exists only on public main (not in private's include-set or
   `public-overlay/`).
2. Losing it would silently break a user-visible behavior (e.g., PR
   mirror-back or repo bootstrap).

For an intentional retirement, remove the path from the private config and
merge that change before deleting the public-only file. Reversing this order
would make the next private-to-public sync fail the guard.

### What the guard does NOT enforce

- **Files in `public-overlay/`.** These are restored on every sync by
  `apply_public_overlay`, so loss-by-orphan is recovered automatically.
- **First-restore states.** If a protected path is absent from current
  public main, the guard logs and skips it. This lets us add a new
  `protected_paths` entry before the file exists on public, and tolerates
  intentional removals during operator-driven recovery.

### Failure semantics

On guard failure, sync-core emits `has_changes=false` and exits 1. The
sync workflow's push step is gated on `has_changes == 'true'`, so a
guard-failed run produces no push, no PR, no wipe. The guard's error log
includes a prescriptive recovery procedure (see [Operator recovery from a
guard failure](#operator-recovery-from-a-guard-failure)).

### False-positive risk

The guard inspects the prospective post-rebase-merge tree, not the
sync-branch tip directly, so it correctly distinguishes "the eventual
rebase-merge would actually delete or modify this protected path" from
"the tree representations differ but the rebase-merge would preserve the
file unchanged" (the topology produced by `fast-export --import-marks` +
pathspec filtering on every incremental sync). The intended trigger is
"orphan-style sync branch whose prospective merge tree would wipe a
protected file." Secondary triggers — a human PR modifying a protected
workflow on public main after this run's marks anchored, or a seed-marks
recovery whose post-merge tree drops the file — are real wipes, not false
positives. Recovery for either is the seed-marks dispatch documented
below.

### Operator recovery from a guard failure

When the guard fires, the run logs print this procedure. Reproduced here
for completeness:

1. **If the protected file is missing from public main itself,** restore
   it via a direct human PR. (Even the App, which has `workflows: write`,
   should not be the actor restoring a wiped workflow — the human PR is
   the audit trail.)

2. **Re-anchor the sync marks to current public HEAD.** Trigger
   `sync-to-public.yml` via `workflow_dispatch` with input
   `seed_from_public_sha=<current-public-main-HEAD-SHA>`. The
   `seed-marks-from-public.sh` step validates tree-equivalence over the
   include-set (which excludes `.github/`, so workflow content does not
   participate in the check) and re-pairs the marks. The next manually
   dispatched sync resumes with re-anchored marks; the protected workflow blob now
   matches public main, and the guard passes.

3. **Do not bypass by directly editing `protected_paths`.** Removing a
   path from the array to "make the guard pass" is exactly the failure
   mode this guard exists to catch.

See [Graft Synthesis Recovery](#graft-synthesis-recovery) for the deeper
mechanics of `seed-marks-from-public.sh`.

## Public→private mirror-back

The public repo contains a public-overlay workflow at `.github/workflows/mirror-back.yml`.
Its source of truth is private `public-overlay/.github/workflows/mirror-back.yml`,
and its helper lives at `public-overlay/.github/scripts/mirror-back.sh`. The next
normal private→public sync copies both files to public through the overlay
mechanism; do not open bootstrap PRs directly on public for these files.

Mirror-back runs on `push` to public `main` and inspects the pushed commits in
oldest-first order. Commits where the **author** identity is a sync App identity
(`foundry-samples-repo-sync[bot]` or `foundry-samples-sync[bot]`) are skipped so the
normal private→public sync cannot loop back into private. Every other public
commit gets a private branch named `mirror/public-{short-sha}-{slug}` and a PR
titled `Mirror: {public PR title or commit subject} (foundry-samples@{short-sha})`.

> **Author, not committer.** `wait-and-merge.sh` merges sync PRs via
> `gh pr merge --rebase` as the App, which makes the App the git **committer**
> for those commits. Human PRs opened and merged directly on public can therefore
> arrive with a human author and a sync-bot committer. Mirror-back uses only the
> **author** identity to decide whether to skip — the sync pipeline always sets
> `GIT_AUTHOR_NAME` to the bot identity, so real sync commits are always
> bot-authored. Checking committer would silently drop legitimate human-authored
> changes. (ADO 5398977, fixed PR #620.)

Mirror PRs are intentionally **not** auto-merged. They use the `public-mirror`
label, include a hidden `public-mirror-sha:{sha}` marker in the body, and link to
the public commit plus the originating public PR when GitHub can discover it.
Idempotency checks all open and closed private PRs by branch name and body marker;
closing a mirror PR without merging is therefore an explicit decision to suppress
future automatic replays for that public SHA.

If a public commit cannot be replayed cleanly, mirror-back pushes a best-effort
branch, opens the private PR as draft, assigns the public committer when their
GitHub login can be derived from a noreply email, and creates a `triage` issue in
`microsoft-foundry/foundry-samples-pr` linking the failed replay. The workflow
also supports `workflow_dispatch` dry-run mode, which prints the proposed PR body
without pushing branches or opening PRs.

## Author Rewriting

The sync rewrites commit author information using `.github/sync-mailmap`. This maps internal Microsoft aliases to public-facing identities, ensuring:

- Commits appear under the author's public GitHub identity
- Internal email addresses are not exposed in public git history
- Attribution is preserved accurately

Validation statuses are not part of author rewriting. They remain attached to private-repo SHAs and are consumed before export.

### Mailmap enforcement

Two systems work together to keep unmapped internal emails off the public repo:

**System A — pre-merge gate (`mailmap-precheck.yml`):** Runs on every PR targeting `main`. Scans author, committer, and trailer emails in the PR's commits against `.github/sync-mailmap`. If an unmapped `@microsoft.com` email is found, the check (`Check author/committer/trailer emails`) fails and the PR is blocked. The contributor must add their own mailmap entry before the PR can merge. This is a required status check enforced by the `main` branch ruleset.

**System B — manual remediation (`fix-unmapped-emails.yml`):** Runs only when manually dispatched. It scans commits reachable from `HEAD` (default branch only — not open PR branches) for unmapped emails, then opens or updates an `auto/fix-unmapped-emails-*` PR with the missing entries. This handles any email that escaped the pre-merge gate (e.g., during the window before the gate was enforced) without reacting automatically to a reviewed sync failure.

The two systems are complementary: System A prevents the problem at PR time; System B can build the fix during a manually reviewed incident. If Sync-to-Public fails with `Unmapped internal email`, see §6 of [sync-incident-response.md](../skills/sync-incident-response.md) for recovery steps.

## Authentication

The sync uses a **GitHub App** (`foundry-samples-repo-sync`) for repository-to-repository automation:

- Private→public sync mints a short-lived token scoped to the public repository.
- Public→private mirror-back mints a short-lived token scoped to the private repository and uses it for private checkout, branch push, PR creation, and conflict tracking issues.
- No Personal Access Tokens (PATs) are used for sync automation — this eliminates token rotation burden.
- App installation and repository permissions are managed via GitHub org settings. Mirror-back requires the App installation on `microsoft-foundry/foundry-samples-pr` to allow `contents: write`, `pull-requests: write`, and `issues: write`.
- Because mirror-back executes in the public repo, `SYNC_APP_ID` and `SYNC_APP_PRIVATE_KEY` must also be configured as secrets on `microsoft-foundry/foundry-samples` before the deployed workflow can run.

The status-reading step queries statuses in the private repo. It should use credentials available to the workflow with read access to `microsoft-foundry/foundry-samples-pr`. The status-posting credentials for validation pipelines are defined in [Validation Results Contract](validation-results-contract.md).

## Workflow Inputs

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `dry_run` | boolean | `false` | Builds sync branch and pushes, but does NOT create a PR or update marks cache |
| `seed_from_public_sha` | string | `''` | Recovery-only input: public `main` SHA to graft from when synthesizing paired marks |
| `seed_from_private_sha` | string | `''` | Recovery-only input: private `main` SHA to graft from. Defaults to private `HEAD` when empty. Use when `seed_from_public_sha` corresponds to a private SHA older than current `HEAD` (e.g., commits landed on private after public last synced). |
| `seed_blocked_paths` | string | `''` | Recovery-only input: override `SYNC_BLOCKED_PATHS` for the seed-marks tree-equivalence check. Colon-separated repo-relative sample paths. Use when `seed_from_public_sha` was produced by a sync that excluded paths via a historical block-list that differs from the current one; otherwise seed-marks will fail tree-equivalence on the historically-blocked paths (private has them, public doesn't). Only takes effect when `seed_from_public_sha` is set. See [Historical block-list mismatch](#historical-block-list-mismatch). |

## Graft Synthesis Recovery

`seed-marks-from-public.sh` is the marks-recovery primitive. It runs in two modes:

**Operator-driven (workflow_dispatch).** Use when the marks cache is gone or untrusted but private and public main carry equivalent content. Operator supplies `seed_from_public_sha` (and optionally `seed_from_private_sha`) and the workflow seeds paired marks before the normal pipeline.

**Automatic stale-marks recovery.** When `sync-core.sh` runs `fast-import` and the import fails because `PUBLIC_MARKS` references an object no longer reachable in the public repo, sync-core invokes `seed-marks-from-public.sh` automatically against the pair (last-synced private SHA from the `last-synced-private.sha` sentinel file ↔ current public `main` HEAD), then retries fast-import. This is the dominant recovery path in production: it absorbs the SHA-rewrites caused by `gh pr merge --rebase` on public sync PRs, where the imported sync-branch commit is rewritten on merge and the original is later pruned by `gc` after "Close stale sync PRs" runs. Trees still match, so seed-marks succeeds and the next sync is a clean single-commit delta. If the seed's tree-equivalence check fails (real divergence), sync-core hard-fails — it does not silently fall back to a full re-export, because that would produce an orphan branch and a noisy, conflict-prone PR.

> **Why a sentinel and not the tail of `private.marks`?** An earlier implementation derived the recovery anchor by reading the last line of `private.marks` with `awk`, on the assumption that fast-export writes marks in source-commit order. It doesn't — `git fast-export --export-marks` is free to reorder entries, so the tail line could point at an ancestor of the real last-synced commit. When that ancestor was then fed to `seed-marks-from-public` as the recovery base, the tree-equivalence check would either fail (producing a false "real divergence" hard-fail) or, worse, succeed against the wrong tree and silently rewind progress. The explicit `last-synced-private.sha` sentinel removes that class of bug by recording the true last-synced private SHA at every successful sync exit. See May 2026 wedge investigation (ADO 5270567).

The recovery primitive performs a symmetric tree-equivalence check before writing anything:

```bash
git -C private ls-tree -r --full-tree <private-sha> -- <include-pathspecs> | sort
git -C public  ls-tree -r --full-tree <public-sha>  -- <include-pathspecs> | sort
```

The include set is the normal sync include-set: everything not excluded by `.github/sync-config.json` (both `exclude_pathspecs` and `exclude_basenames`) plus any dynamic validation exclusions for the run. The check is symmetric by design. A private-only path and a public-only path in the include-set both fail, because grafting is incremental and cannot safely repair public-only divergent content. `.github/CODEOWNERS` is also checked explicitly when the private repo has one, because sync-core copies it directly even though `.github/` is otherwise excluded. The CODEOWNERS check is asymmetric on one axis only: if private has CODEOWNERS and public is missing it, the seed proceeds with a warning, because `sync_codeowners` amends the file back into the imported commit on every run. Differing CODEOWNERS blobs still hard-fail (real divergence is not silently overwritten).

On success, the seed step writes `private.marks`, `public.marks`, `pathspec.hash`, `root.sha`, and `last-synced-private.sha` into the marks directory, then `sync-core.sh` validates those files and runs incrementally. Expected output is a log line like `Seeded paired marks for private <sha> ↔ public <sha>`. If there are no new public-path commits after the graft point, the sync step should report `has_changes=false`; the coordinated cache-save change persists the seeded marks anyway.

On tree mismatch, the script prints the diff for the diverging tree entries, exits non-zero, and leaves the marks directory unchanged. Do not bypass this failure. Reconcile the reviewed private-owned content through a PR, choose public/private SHAs whose include-set trees match, and rerun the seed recovery with `dry_run=true` before a real run.

### Historical block-list mismatch

The seed-marks tree-equivalence check filters both sides through `exclude_pathspecs ∪ exclude_basenames ∪ SYNC_BLOCKED_PATHS`. `SYNC_BLOCKED_PATHS` defaults to the **current** run's computed validation block-list, *not* the block-list that was active when the seed public SHA was produced. When those two differ, recovery fails with "Tree mismatch" on exactly the historically-blocked paths (private has them, public doesn't, current filter no longer hides them).

Symptom: the tree-mismatch diff shows hundreds of `-` lines (private-only) all within a recognizable set of sample directories that share validation lineage (e.g., all `foundry-local` samples), and those directories were known to be failing validation at the time of the seed SHA's sync.

Fix: dispatch with `seed_blocked_paths=<the historical list>`. The historical list is recoverable from the run that produced the seed public SHA — grep its logs for the `SYNC_BLOCKED_PATHS:` env line dumped at the start of the "Run sync pipeline" step.

Permanent fix (planned): persist the effective block-list alongside marks (`MARKS_DIR/blocked-paths.txt`) and have automatic stale-marks recovery read it. Tracked separately; until shipped, `seed_blocked_paths` is the manual escape hatch.

Recovery walkthrough:

1. Operator runs `workflow_dispatch` with `seed_from_public_sha=<public-main-HEAD>`. Optionally pass `seed_from_private_sha=<private-sha>` if the private SHA equivalent to `<public-main-HEAD>` is older than current private `HEAD` (i.e., commits have landed on private since public last synced).
2. Cache miss (no matching key yet).
3. Seed step writes synthesized marks + state files into `marks-dir`.
4. `check_marks_validity` sees marks + matching state → marks valid → incremental.
5. `git fast-export --import-marks=private.marks <private-HEAD>` emits zero commits because `private-HEAD` is already in marks.
6. Pipeline exits with `has_changes=false`. Save step fires anyway (cache-key rotation PR gate change) → cache persisted under new key with seeded marks.
7. Next manually dispatched run: cache restore matches via `restore-keys` prefix → marks + state files load → next real private commit produces clean incremental delta against public main.
8. "Close stale sync PRs" runs on the first real-delta sync after that and closes the stale public sync PR automatically. Alternatively, close it manually any time after step 7.

## Sync Marks Cache Lifecycle

The workflow persists fast-export / fast-import marks in the GitHub Actions cache under keys scoped to both repository lineage and private `HEAD`:

- Exact key: `sync-marks-${ROOT_SHA}-${PRIVATE_SHA}`.
- Restore prefix: `sync-marks-${ROOT_SHA}-`.

`ROOT_SHA` is the private repository root commit, which keeps marks caches tied to the same history family. `PRIVATE_SHA` is `git rev-parse HEAD` in the private checkout for the current run, so each successful private `HEAD` can save a new immutable cache entry instead of colliding with a previous run's key.

On restore, Actions first tries the exact key for the current private `HEAD`, then falls back to the newest cache matching the root-scoped prefix. This gives incremental sync runs the latest available marks while still allowing `actions/cache/save@v4` to persist updated marks under the current private `HEAD` key.

The save step is skipped for dry runs. For non-dry runs, it saves marks when either:

1. The sync produced public changes (`steps.sync.outputs.has_changes == 'true'`).
2. A recovery seed run supplied `seed_from_public_sha`, even if that run produced no new commits, so synthesized marks can persist for the next manual sync.

`pathspec.hash` (stored alongside the marks) is computed over the **static** `exclude_pathspecs` from `sync-config.json` only. The per-run validation block-list (`SYNC_BLOCKED_PATHS`) and the static `exclude_basenames` list are intentionally **not** folded into the hash — their effect is applied at filter time via the `--exclude-path` / `--exclude-basename` args, but they should not invalidate durable marks across runs. Folding either into the hash would require seed recovery every time a sample's validation status flipped or a marker name changed, even though both are safe to apply as incremental delta filters.

### `last-synced-private.sha` sentinel

The marks directory also carries `last-synced-private.sha`: a single-line file containing the private `HEAD` SHA at the moment sync-core last completed successfully. It is the authoritative anchor for the automatic stale-marks recovery path described above — sync-core reads it (not the tail of `private.marks`) to decide which private SHA to graft from when `fast-import` fails on stale public objects.

Sentinel lifecycle:

- **Written** at every successful sync-core exit (no-op clean exit, dry-run exit, and full sync-complete exit) via atomic `tmp+mv`.
- **Written** by `seed-marks-from-public.sh` after its tree-equivalence check, so a freshly-seeded cache is immediately self-describing.
- **Removed** by `check_marks_validity` whenever it discards the paired marks for any reason (stale state, pathspec mismatch, root-SHA mismatch). This prevents a stale sentinel from outliving its marks.
- **Persisted** automatically via the existing `marks-dir` cache path — no separate cache configuration.

If the sentinel is absent while public `main` exists, sync fails closed with `SEED_RECOVERY_REQUIRED`. Supply reviewed seed SHAs and use `dry_run=true` first; the workflow does not discard the anchor and rebuild the public tree.

## Drift Verification

A separate workflow, `.github/workflows/verify-sync.yml`, runs only when manually dispatched to confirm that the public repo's `main` matches what private `main` *should* have produced.

The check is intentionally narrow:

- It compares `git ls-tree -r HEAD` of private `main` after exclusions against `git ls-tree -r HEAD` of public `main`.
- Expected private state applies both static exclusions and the current validation block-list.
- Drift = path missing in public, blob hash differs, or path present in public that should not be there.
- Output goes to the workflow run summary; persistent drift fails the run.

What drift verification does **not** check:

- **Author identity / mailmap correctness** — that's verified upstream during sync (`filter-stream.py` + `sync-mailmap`) and isn't re-derivable from a tree snapshot.
- **Commit message contents or history shape** — only the file tree at `HEAD` is compared.
- **Historical validation status** — v1 checks the current private `main` statuses. If a sample is currently gate-blocked, missing/stale public content for that sample is intentional, not drift.

The script is `.github/scripts/verify-sync.sh`.

## Operational Behavior

| Scenario | Behavior |
|----------|----------|
| Manual sync | Runs only through `workflow_dispatch`. The gate consumes the statuses current on private `main` HEAD at dispatch time. |
| Sample blocked at one sync | The sample is omitted from that sync. It recovers automatically at the next sync after its validation statuses go green. |
| Re-run validation flips status | Latest write wins for the same `(commit, context)`. A later `success` can unblock the sample for the next sync. |
| No reporting pipeline | Grandfathered in v1; the sample syncs unless another validation context reports a block for it. |
| Need to ship despite red validation | No break-glass override in v1. Fix validation or the sample. Break-glass is deferred to v2. |

Each run should emit a sync-time UX summary listing:

- blocked sample path
- blocking context(s)
- blocking state(s)
- `target_url` when provided by the reporter

For v1, workflow logs and `$GITHUB_STEP_SUMMARY` are sufficient. Phase G owns richer reporting / dashboard work.

## Public Repo Branch Protection

The public repo has a branch ruleset on `main` that requires reviewed PRs and a green required-checks set. The sync workflow pushes only a sync branch, opens a public PR, waits for those requirements, and performs the rebase merge within the same run. It has no supported direct push to public `main`.

`wait-and-merge.sh` deliberately does not use `gh pr merge --auto`. It polls until the PR is mergeable and required checks and reviews are satisfied, then calls `gh pr merge --rebase` while authenticated as the App. Marks are saved only after that merge succeeds.

### Required repository-admin action

Remove the sync App from the public `main` ruleset bypass list:

1. Open `microsoft-foundry/foundry-samples` → **Settings** → **Rules** → **Rulesets**.
2. Edit the active ruleset targeting `main` (historically ruleset ID `6131793`).
3. Under **Bypass list**, remove `foundry-samples-repo-sync` (GitHub App ID `2846614`).
4. Save the ruleset without removing the App installation or its branch/PR permissions.

This is a repository-admin configuration change and is not performed by the workflow or repository code.

## Design Decisions & Gotchas

A short list of things that are easy to get wrong, captured for future-you:

- **Refspec literal names matter.** `git push <remote> sync-tmp:refs/heads/sync-branch` works; `git push <remote> sync-tmp:sync-branch` does not consistently resolve to the intended ref on a fresh remote. Always use the fully-qualified `refs/heads/...` form on the right-hand side.
- **`fast-export --refspec` rewrites literal emitted ref names, not arbitrary source arguments.** `sync-core.sh` pins the export source to `refs/heads/sync-export-source` before exporting so the stream deterministically emits `commit refs/heads/main`. Do not simplify this back to `--refspec=HEAD:refs/heads/main`; detached CI checkouts silently write imports to the wrong ref and can produce a public branch with no imported authorship. See the gotchas block at the top of `.github/scripts/sync-core.sh` and regression T28 in `.github/tests/test-sync.sh`.
- **`.github/`-only changes produce no public commits.** `filter-stream.py` drops empty commits, and the path exclusions remove all `.github/` content. So a sync run triggered by a private-only `.github/` change will report success but skip the Push, Create-PR, and Save-Marks steps. This is correct behaviour, but it does mean the sync pipeline can't be smoke-tested by editing only its own infrastructure — you need a real public-path change to exercise the merge path.
- **CodeQL `actions` analysis is intentionally disabled on the public repo.** The public repo runs CodeQL via GitHub-managed default setup. The `actions` language is unchecked because the repo has no workflow YAML to analyse (the only workflow file under `.github/` is `CODEOWNERS`); leaving it on produces noisy false-positive alerts. Public CodeQL config is managed in the repo's Code Security settings, not a workflow file.
- **Bot-authored commits are filtered, not preserved.** Anything authored by `github-actions[bot]` or the sync App itself is dropped from the rewritten stream — only real human authors are surfaced in public history.
- **Human public PRs merged via App rebase-merge have sync-bot as committer.** The `wait-and-merge.sh` script merges sync PRs by calling `gh pr merge --rebase` as the App; GitHub records the App as the git committer. If a human opens a PR directly on public and it is merged the same way, the resulting commit has a human author but a sync-bot committer. `mirror-back.sh` skips only commits whose **author** is the sync bot (not committer) to avoid silently dropping these human changes. See mirror-back section for details.
- **Statuses live on private SHAs.** Do not try to propagate validation statuses to the public repo after author rewriting. Public commits have different SHAs; this is correct. The gate is a private-repo concern.
- **`pending` blocks sync.** This is intentional. If a reporter posts `pending`, the sample should not ship mid-validation.
- **Latest write wins on `(commit, context)`.** A re-run can flip a sample from blocked to unblocked at the next sync by posting `success` to the same SHA and context.
- **Renames create a hole.** A renamed sample path is a new status context from the gate's perspective. During transition, report under both old and new paths when practical.
- **Multi-pipeline samples require all green.** If any validation context for a sample is `failure`, `error`, or `pending`, the sample is blocked. L4 canary failures block even when L3 build validation passes.

## Troubleshooting

### Run a sync

1. Dispatch `sync-to-public.yml` manually.
2. For recovery, provide reviewed seed SHAs and set `dry_run=true` first.
3. Check GitHub Actions logs for token generation failures (App private key rotation, installation issues).

### Sync ran but pushed nothing / opened no PR

This is normal if the only commits since the last sync touched excluded paths (e.g., `.github/`, `internal/`, `docs/`, `.azure-pipelines/`) or if all otherwise-new public-path changes are currently gate-blocked. `filter-stream.py` drops the resulting empty commits, so the Push and Create-PR steps skip with a "no new commits" log line.

To verify, check:

1. The run summary for blocked samples.
2. The sync-core log for export/filter/import commit counts.
3. Whether the changed paths are static-excluded in `.github/sync-config.json`.

### Sample did not appear in public repo

1. Verify the path isn't statically excluded (`.github/sync-config.json`).
2. Verify the commit was on `main` before the sync ran.
3. Check the sync run summary for validation-blocked samples.
4. Query the private commit status for the synced SHA and inspect `validation/*` contexts.
5. If statuses are now green, dispatch the sync manually.

### Sync PR opened but never merged

1. Check `wait-and-merge.sh` log output for the polling loop's exit reason.
2. Confirm required checks on the public repo all completed green.
3. Confirm required reviews have been submitted; the App must not bypass the `main` ruleset.

### Author attribution is wrong

1. Check `.github/sync-mailmap` for the correct mapping.
2. Entries follow git mailmap format: `Public Name <public@email> Internal Name <internal@email>`.

### Sync run exited 1 with "Protected-paths guard FAILED"

The guard caught an attempt to push a sync branch that would delete or modify a public-only workflow file. See [Protected-paths guard → Operator recovery](#operator-recovery-from-a-guard-failure) for the full procedure. Short version: if the workflow is missing on public main, restore it via a direct human PR first; then `workflow_dispatch` the sync workflow with `seed_from_public_sha=<current-public-main-HEAD>` to re-anchor the marks.

### Sync failed with "fast-import failed with marks" / "seed-marks recovery failed"

The automatic marks-recovery path ran but found a real tree mismatch between private and public. The sync hard-failed and left marks unchanged.

**Diagnose by grepping the failed run log for:**

```bash
# Identify the failure type and the diverging file(s)
grep -E "object not found|seed-marks|Tree mismatch|private\.tree|public\.tree|@@" <log>
```

The diff lines show exactly which file(s) differ and which blobs. A single-file diff almost always means a direct human commit landed on public after the last sync (check recent commits on `microsoft-foundry/foundry-samples`).

**Check whether mirror-back missed the commit:**

```bash
grep "Skipping sync-App commit" <mirror-back-run-log>
```

If it shows the offending public SHA, mirror-back dropped a commit it should not have.

**Recovery options:**

| Scenario | Recovery |
|----------|----------|
| Private-owned content differs | Reconcile it through a reviewed private or public PR until the include-set trees are equivalent, then dispatch with `seed_from_public_sha=<public-HEAD>` and the matching `seed_from_private_sha`; use `dry_run=true` first. |
| Public has a legitimate change not yet in private | Bring it to private via PR first, merge, then seed from the reviewed equivalent SHAs with `dry_run=true` first. |
| Trees differ only due to historical block-list changes | Dispatch with `seed_from_public_sha=<public-HEAD>` + `seed_from_private_sha=<matching-private-SHA>` + `seed_blocked_paths=<historical-list>` and `dry_run=true`. See [Historical block-list mismatch](#historical-block-list-mismatch). |

For the full step-by-step, see the [Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md).

For the full end-to-end recovery playbook (orphan-wipe, marks-cache reseed, blocked-validation backlogs, post-recovery verification), see the [Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) in `foundry-devx-eng-docs`. That runbook was authored after the 2026-06-09 → 2026-06-10 sync saga (PRs [microsoft-foundry/foundry-samples-pr#493](https://github.com/microsoft-foundry/foundry-samples-pr/pull/493), [#499](https://github.com/microsoft-foundry/foundry-samples-pr/pull/499), [#513](https://github.com/microsoft-foundry/foundry-samples-pr/pull/513), [#518](https://github.com/microsoft-foundry/foundry-samples-pr/pull/518)) and is the canonical step-by-step for incident response.

### Need to revert a sync

1. Find the rollback SHA from the sync PR description.
2. Revert the affected public commits through a reviewed public PR; do not push directly to `main`.
3. Reconcile the corresponding private-owned content, then seed from reviewed equivalent public/private SHAs with `dry_run=true` before the real recovery run.

Rollback affects public content. It does not rewrite private validation statuses; fix or re-run validation separately if the rollback is related to gate behavior.

## Changelog

| Date | Change |
|------|--------|
| 2026-08-25 | **Removed destructive routine sync modes (ADO 5551175).** Private→public sync is manual-only and incremental after first bootstrap. Removed force-full/direct-main publication and orphan full-export recovery; established-public marks failures now require verified seed recovery. The public sync App must be removed from the `main` ruleset bypass list by a repository admin. |
| 2026-08-05 | **Retired protection for the legacy public PR redirect workflow ([ADO 5499173](https://msdata.visualstudio.com/Vienna/_workitems/edit/5499173)).** Removed `.github/workflows/redirect-pull-requests.yml` from `protected_paths` after public-first validation made public PRs the required merge gate. The public workflow remains in place until this config change merges; deleting it first would fail the next private-to-public sync. |
| 2026-06-29 | **mirror-back: skip on author identity only, not committer (ADO 5398977, PR #620).** `should_skip_commit` previously checked all four git identity fields (author name, author email, committer name, committer email) against the sync-bot identities. Human PRs merged to public via "direct rebase merge as the App" have a human author but sync-bot committer; this caused them to be silently dropped, producing public drift that broke sync marks on the next run. Fix: check author only. The sync pipeline always sets `GIT_AUTHOR_NAME` to the bot identity, so real sync commits still skip correctly. Regression test `test_human_author_bot_committer_not_skipped` (MB4) added to `.github/tests/test-mirror-back.sh`. Troubleshooting section updated with marks-drift recovery recipe. |
| 2026-06-11 | **Cross-link added to sync-recovery runbook.** Troubleshooting section and Related Documents now link to [`foundry-devx-eng-docs/operations/sync-recovery-runbook.md`](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — the canonical end-to-end playbook authored after the 2026-06-09 → 2026-06-10 sync saga. No mechanism changes in this entry. |
| 2026-06-10 | **Exclude-path filtering moved into `filter-stream.py` (ADO 5347427).** `git fast-export` previously ran with pathspec args, which forced `--full-tree` mode: when marks anchored on a real public commit (e.g. post-seed-recovery anchoring at `PUBLIC_SHA`), each new sync-branch commit's tree represented a wholesale delete of excluded paths (`.github/`, etc.) relative to that parent. The protected-paths guard correctly fired on this "wipe" but the wipe was structurally unnecessary — public main's workflows should pass through unchanged. Fix: drop pathspec args from `fast-export` (export now runs in delta mode), add `--no-renames` so renames decompose into D+M pairs, and apply the include-set filter in `filter-stream.py` via a new repeatable `--exclude-path` CLI arg. Dropped commits are spliced out of the mark chain (`dropped_mark_to_parent` resolution on `from :N` / `merge :N`) so `fast-import` never hits "mark :N not declared". Sync-branch commits now inherit excluded-path content from their marks-anchored parent → merge-tree result preserves protected workflows → guard passes structurally rather than relying on coincidental tree topology. Test T70 flipped from wipe-detection to seed-recovery happy-path; T66 retains genuine orphan-wipe coverage; T71 / T72 added for rename-across-boundary in both directions. Requires a one-shot `workflow_dispatch` with `seed_from_public_sha` + `seed_from_private_sha` after deployment to re-anchor existing marks. |
| 2026-06-09 | **Protected-paths guard fixed (ADO 5347121).** Replaced the sync-branch-tip blob comparison in `guard_protected_paths()` with a `git merge-tree --write-tree` simulation against the prospective post-rebase-merge tree. Normal incremental syncs (`fast-export --import-marks` + pathspec topology) now pass cleanly while seed-marks-recovery wipes still hard-fail. Requires git ≥ 2.38; CI runners are 2.43+. Test T69 (added in PR #492 as a RED reproducer) flips green; T70 (seed-marks wipe regression coverage) stays green. Re-enabling the scheduled cron is tracked separately as ADO 5347122. |
| 2026-06-08 | **Scheduled sync paused.** Commented out cron in `sync-to-public.yml` and documented a newly-discovered architectural bug in the protected-paths guard from PR #463. `git fast-export --import-marks` + pathspec filters force `--full-tree` mode, so the sync branch tip's tree never contains `.github/` entries; the guard's blob comparison cannot pass once protected files exist on public main. Fix tracked as ADO 5347121; sync runs only via `workflow_dispatch` until the fix lands. |
| 2026-06-08 | Added `seed_blocked_paths` `workflow_dispatch` input to `sync-to-public.yml` so the seed-marks tree-equivalence check can be run against a historical block-list. Exposed by the post-PR-#463 recovery: morning's scheduled sync wrote marks at a public SHA produced under a large validation block-list; later auto-recovery refused tree-equivalence on those historically-blocked paths. See [Historical block-list mismatch](#historical-block-list-mismatch). |
| 2026-06-08 | Added protected-paths guard to `sync-core.sh` (PR #463). Public-only workflow files (`redirect-pull-requests.yml`, `mirror-back.yml`, `run-setup.yml`) are now listed in `sync-config.json`'s `protected_paths`; sync runs hard-fail if the sync branch would delete or modify them on public main. Backstops orphan-recovery wipes (the 2026-06 incidents that motivated this). See [Protected-paths guard](#protected-paths-guard). |
| 2026-05-04 | Implemented Phase D4 + D4b atomically in PR-B: `compute-blocklist.sh` (shared entry point), `sync-to-public.yml` calls it before sync and passes `SYNC_BLOCKED_PATHS` into `sync-core.sh`, `verify-sync.yml` independently calls it and passes the same env into `verify-sync.sh`. Added `bypass_samples` / `bypass_reason` / `bypass_gate` workflow_dispatch inputs with mandatory loud surfacing (run-summary banner, PR body footer, auto-comment on `vars.BYPASS_LOG_ISSUE_NUMBER`). |
| 2026-04-30 | Implemented Phase D2 in PR #215: `sync-core.sh` now honors `SYNC_BLOCKED_PATHS` as the dynamic per-run validation exclusion seam. |
| 2026-04-29 | Reopened sync-gating decision; sync now honors GitHub commit statuses per `docs/validation-results-contract.md`. See `docs/validation-story-decisions.md`. |

## Related Documents

- [Sync Recovery Runbook (foundry-devx-eng-docs)](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — Canonical end-to-end playbook for sync incidents (orphan-wipe, marks reseed, protected-paths guard failures, validation backlogs). Read this when a sync run fails in production.
- [Validation Story — Phase B Decisions](validation-story-decisions.md) — Locked decisions that supersede earlier validation/sync-gating text.
- [Validation Contract](validation-contract.md) — Validation behavior and gate contract.
- [Validation Results Contract](validation-results-contract.md) — How validation pipelines post per-sample GitHub commit statuses.
- [External Contributions](external-contributions.md) — How partner samples flow through sync.
- [Sync Cutover Runbook](sync-cutover-runbook.md) — The one-time authorship-preserving history rewrite of public `main`.
- [Sync Config](../.github/sync-config.json) — Static exclusion paths and public repo target.
- [Sync Core Script](../.github/scripts/sync-core.sh) — The sync implementation.
- [Wait-and-merge Script](../.github/scripts/wait-and-merge.sh) — Direct-merge polling logic.
- [Verify Sync Script](../.github/scripts/verify-sync.sh) — Drift checker.
