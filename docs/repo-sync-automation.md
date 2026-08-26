# Repo Sync Automation

This document describes the operator-run bridge from `foundry-samples-pr` (private) to `foundry-samples` (public).

The public repository is the normal route for work intended for publication. The private repository is internal-first, and merging private work does not publish it. An authorized operator may dispatch this retained bridge for approved private content; the bridge always proposes that content through a normal public pull request.

This document owns the **bridge mechanics**: positive path scope, export/import, author rewriting, generated-diff guards, App-authenticated PR creation, wait-and-merge, drift verification, and the sync-time validation gate. The validation rules themselves live in [Validation Contract](validation-contract.md). The contract for pipelines that post validation statuses lives in [Validation Results Contract](validation-results-contract.md).

## Overview

```text
foundry-samples-pr (private)  ── operator-run bridge ──►  foundry-samples (public)
       │                                                   │
       │  Internal-first work                              │  Normal publication PRs
       │  Validation statuses                              │  Public metadata ownership
       └──────────────── approved content only ────────────┘
```

- **Normal publication route**: Open a pull request directly in public `foundry-samples`.
- **Private repository role**: Internal-first work and private-only validation. A private merge is not a publication event.
- **Bridge direction**: When explicitly dispatched, the bridge evaluates private `main` and proposes eligible content to public.
- **Default scope**: `infrastructure/**` and `samples/**`.
- **Operator escape hatch**: `additional_paths` may add approved, non-reserved paths for one dispatch.
- **Trigger**: Manual `workflow_dispatch` only.
- **Mechanism**: `git fast-export` / `git fast-import` with positive path filtering and author rewriting, followed by a public PR.
- **Validation gate**: Before push, the sync gate filters out samples whose validation has not passed at the private `main` SHA being synced.
- **Automation**: GitHub Actions workflow in `.github/workflows/sync-to-public.yml`.

High-level flow:

```text
operator-selected private main
  └─ read validation/* statuses on private HEAD
      └─ build per-run blocked-sample exclusions
          └─ build allowed scope: infrastructure/** + samples/** + additional_paths
              └─ fast-export only allowed, unblocked paths
                  └─ filter stream / rewrite authors
                  └─ fast-import into public sync branch
                      └─ generated-diff guard
                          └─ push dry-run or sync branch
                              └─ normal run: open public PR / wait for checks
                                  └─ refresh and run generated-diff guard again
                                      └─ rebase merge as ruleset-bound App
```

## How It Works

### 1. Evaluate sync gate

At the start of a sync run, the workflow evaluates validation statuses on the private commit being synced, normally `main` HEAD:

```bash
gh api repos/microsoft-foundry/foundry-samples-pr/commits/<sha>/status
```

Statuses whose context matches `validation/*` are interpreted according to [Validation Results Contract](validation-results-contract.md). The gate produces a per-run list of sample roots to hold back from public sync.

This block-list can only remove sample roots from the positive publication scope. It cannot add paths, authorize reserved metadata, or affect `infrastructure/**`.

### 2. Resolve publication scope

The bridge constructs a positive allowlist for each run:

1. Include `infrastructure/**`.
2. Include `samples/**`.
3. Add any valid entries from the one-run `additional_paths` input.
4. Remove sample paths blocked by validation or unmapped-author checks.

Reserved paths are never eligible, including through `additional_paths`: `README.md`, `CONTRIBUTING.md`, `.github/**`, and `public-overlay/**`. Public metadata and automation under those paths are maintained through normal pull requests in `microsoft-foundry/foundry-samples`.

For other paths, an explicit addition overrides legacy static exclusions such as `docs/**` or `internal/**`, but only for the exact file or trailing-slash directory supplied. Dynamic validation and unmapped-author block-lists still take precedence.

### 3. Export and filter

The sync uses `git fast-export` to stream commits from the private repo, piped through a Python filter (`filter-stream.py`) that:

- Keeps only paths in the resolved publication scope
- Removes dynamic per-run sample exclusions from the sync gate
- Rewrites author identities using `.github/sync-mailmap` (maps internal aliases to public-facing names)
- Preserves commit history structure where possible (merge commits, ordering)

### 4. Import into public repo

The filtered stream is imported into the public repo via `git fast-import`, creating a sync branch with the rewritten history.

The bridge then reconciles the current private and generated trees over the resolved allowed scope. It adds a bot-authored reconciliation commit only when marks already passed content that has since become eligible, such as a one-run `additional_paths` entry or a sample released from the validation block-list.

### 5. Incremental sync via marks

The pipeline uses `git fast-export` / `fast-import` marks files to track what's already been synced. These are cached between runs, making subsequent syncs incremental — only new commits are processed.

The first publication to an empty public repository performs a bootstrap export. Once public `main` exists, missing, invalid, or incompatible marks fail closed before any remote mutation. Recovery must use `seed_from_public_sha` (and, when needed, `seed_from_private_sha`) to establish a verified incremental anchor.

Dynamic gate exclusions are per-run state, not durable repo policy. When a blocked sample later becomes unblocked, the next incremental sync includes the now-eligible changes without replacing the public tree.

### 6. Guard, push, and PR

After generating the branch, the workflow checks every commit that would be replayed and computes the prospective merged tree against fresh public `main`. It fails before push unless every historical and final changed path is in the resolved positive scope and no changed path is reserved.

If the guard passes, the branch is pushed. A dry run stops there. A normal run creates a public PR:

- Stale sync PRs are closed first
- The new PR includes commit count, authors, and a rollback SHA
- The PR body lists the contributing authors verbatim from rewritten commits

### 7. Wait-and-merge (ruleset-bound App rebase merge)

After the PR is opened, `wait-and-merge.sh` polls its mergeability and check status. Immediately before merge, the workflow fetches public `main` and the PR head, verifies the fetched branch matches GitHub's current PR-head SHA, and repeats the generated-diff guard against the current base. The merge is pinned to that guarded head SHA, closing races in which either public `main` or the PR head changes after the branch was first checked.

Once the guard and public ruleset permit the merge, the workflow performs a **rebase merge** as the GitHub App. It does **not** use `gh pr merge --auto`, `--admin`, a ruleset bypass actor, or a direct push to public `main`. Marks are persisted only after the merge succeeds.

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
5. The block-list removes those sample roots from the run's positive publication scope.
6. Validation exclusions cannot add paths or override reserved paths.
7. Samples with no reporting pipeline are grandfathered: untracked = ungated.

Example:

```text
validation/ado-build/samples/python/quickstart-chat = success
validation/hosted-agents-e2e/samples/python/hosted-agents/echo-agent = pending
validation/ado-build/samples/python/hosted-agents/echo-agent = success
```

Result: `samples/python/quickstart-chat` can sync. `samples/python/hosted-agents/echo-agent` is held back because one reporting pipeline is still pending.

## Implementation Surface

| Component | Responsibility |
|-----------|----------------|
| Scope resolver | Builds the positive allowlist from `infrastructure/`, `samples/`, and valid `additional_paths` entries; rejects reserved paths. |
| Status reader | `.github/scripts/parse-validation-statuses.sh` parses a GitHub combined commit-status payload and emits colon-separated repo-relative paths whose latest validation status is `failure`/`error`/`pending`. |
| Block-list computer | `.github/scripts/compute-blocklist.sh` fetches statuses for `<repo>@<sha>`, pipes them through the parser, and emits the sample paths that must be removed from the allowed scope. |
| Stream filter | `sync-core.sh` exports only allowed paths, then applies validation and unmapped-author exclusions before import. |
| Generated-diff guard | Validates the actual generated change set before push and again against refreshed public `main` immediately before merge. |
| Drift verification | `verify-sync.yml` compares expected and actual trees across the durable default scope under current validation and internal-marker exclusions. |
| Validation overrides | `bypass_samples`, `bypass_reason`, and `bypass_gate` affect only the validation block-list. They do not expand path scope, permit reserved paths, or bypass public branch rules. |
| Run summary | Records private SHA, resolved scope, blocked paths, validation override use, generated branch, and guard outcome. |

## Publication scope

The bridge is allowlist-based. Content is eligible only when it matches the default scope or an explicit one-run addition.

### Default scope

| Path | Semantics |
|------|-----------|
| `infrastructure/` | The entire directory tree: `infrastructure/**`. |
| `samples/` | The entire directory tree: `samples/**`, subject to validation and unmapped-author exclusions. |

Everything else is out of scope by default. In particular, the bridge does not infer public eligibility from "not excluded."

Internal marker basenames such as `.ci-skip` and `.code-ci-skip` remain filtered when they appear inside an otherwise allowed tree. Marker files already on public are public-owned and must be changed through a normal public PR.

### `additional_paths` syntax

`additional_paths` is a colon-separated `workflow_dispatch` string. Each entry is repo-relative:

```text
LICENSE:assets/public/:sdk/example.json
```

- An entry ending in `/` is a directory prefix. `assets/public/` authorizes that directory and all descendants.
- An entry without a trailing `/` is one exact file. `LICENSE` authorizes only the root `LICENSE` file; `sdk/example.json` authorizes only that file.
- Entries are not glob patterns. `*`, `**`, and similar wildcard syntax do not expand the scope.
- The input applies only to that dispatch. It does not change the default scope or persist policy.

Use `additional_paths` only for an approved non-reserved path that must be carried by the retained bridge. The preferred publication route remains a normal public PR.

### Reserved paths

These paths can never be authorized by `additional_paths`:

| Reserved path | Ownership |
|---------------|-----------|
| `README.md` | Maintained in public through normal public PRs. |
| `CONTRIBUTING.md` | Maintained in public through normal public PRs. |
| `.github/**` | Public workflows, CODEOWNERS, issue/PR metadata, and other repository automation are maintained in public through normal public PRs. |
| `public-overlay/**` | Retired mechanism. The directory is not a publication source or a valid bridge target. |

There is no special CODEOWNERS forwarding. Private `.github/CODEOWNERS` remains private; public `.github/CODEOWNERS` is edited and reviewed in the public repository.

## Generated-diff scope guard

The guard validates what the bridge actually generated, not what the operator intended to select.

For every added, modified, renamed, or deleted path in the generated diff, the guard requires:

1. The path matches `infrastructure/**`, `samples/**`, or a valid `additional_paths` entry.
2. The path does not match a reserved path.

The checks run twice:

1. **Before push.** The workflow compares the generated branch with fresh public `main`. Failure prevents the branch from being pushed and prevents PR creation.
2. **Immediately before merge.** After required checks complete, the workflow refreshes public `main` and recomputes the generated diff. Failure leaves the PR unmerged and prevents marks persistence.

The second check is required because public `main` can move while the sync PR is open. Re-validating against the current base prevents a previously safe branch from landing an out-of-scope or reserved-path change after base drift.

### Failure semantics

| Failure point | Result |
|---------------|--------|
| Invalid or reserved `additional_paths` entry | Run fails before branch generation or remote mutation. |
| Export, filtering, import, or author-rewrite failure | Run fails closed; no branch push, PR, merge, or marks update. |
| Pre-push generated-diff guard failure | No branch push, PR, merge, or marks update. |
| No eligible generated changes | Clean no-op; no branch push, PR, merge, or marks update. |
| Dry run with eligible changes | A `sync/dry-run-*` branch is pushed for inspection; no PR is created, nothing is merged, and marks are not updated. |
| Public checks or mergeability fail or time out | The branch and PR may remain for diagnosis; public `main` and marks are unchanged. |
| Pre-merge generated-diff guard failure | The PR remains unmerged; public `main` and marks are unchanged. |
| Merge failure | The PR remains unmerged; marks are not updated. |

Do not work around a scope failure by broadening the defaults, adding a reserved path to `additional_paths`, or restoring an overlay. Publish metadata through a normal public PR. If the failure reflects real divergence, reconcile through reviewed PRs and follow [Graft Synthesis Recovery](#graft-synthesis-recovery).

## Historical overlay and protected-path behavior

`public-overlay/`, special CODEOWNERS copying, and the per-file `protected_paths` model are retired. They are retained in older commits and incident records only; none is an active source of truth or publication mechanism.

Historically, the bridge copied `public-overlay/<path>` to public `<path>` after import and copied private `.github/CODEOWNERS` separately. That design allowed stale private copies of public metadata to overwrite public-owned files. On 2026-08-26, public incident PR [microsoft-foundry/foundry-samples#940](https://github.com/microsoft-foundry/foundry-samples/pull/940) demonstrated the failure by reverting the public `README.md` and `CONTRIBUTING.md` to stale overlay copies.

The positive scope and generated-diff guards replace those mechanisms. Public metadata is now maintained only through normal public PRs.

## Public→private mirror-back

Mirror-back is public-owned automation and is not deployed or repaired by this bridge. Its workflow, helper, and configuration under public `.github/**` must be changed through normal public PRs. The private repository is not their source of truth.

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

The two systems are complementary: System A prevents the problem at PR time; System B can build the fix during a manually reviewed incident. If Sync-to-Public fails with `Unmapped internal email`, see §6 of [Sync Incident Response](../.github/skills/sync-incident-response.md) for recovery steps.

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
| `dry_run` | boolean | `false` | Builds and guards a `sync/dry-run-*` branch, then pushes it for inspection. Does not create a PR, merge, or update marks. |
| `additional_paths` | string | `''` | Colon-separated one-run scope additions. A trailing `/` means directory prefix; otherwise the entry is one exact file. Reserved paths are rejected. |
| `seed_from_public_sha` | string | `''` | Recovery-only input: public `main` SHA to graft from when synthesizing paired marks |
| `seed_from_private_sha` | string | `''` | Recovery-only input: private `main` SHA to graft from. Defaults to private `HEAD` when empty. Use when `seed_from_public_sha` corresponds to a private SHA older than current `HEAD` (e.g., commits landed on private after public last synced). |
| `seed_blocked_paths` | string | `''` | Recovery-only input: override `SYNC_BLOCKED_PATHS` for the seed-marks tree-equivalence check. Colon-separated repo-relative sample paths. Use when `seed_from_public_sha` was produced by a sync that excluded paths via a historical block-list that differs from the current one; otherwise seed-marks will fail tree-equivalence on the historically-blocked paths (private has them, public doesn't). Only takes effect when `seed_from_public_sha` is set. See [Historical block-list mismatch](#historical-block-list-mismatch). |
| `bypass_samples` | string | `''` | Validation override: colon-separated sample paths to force-include. Requires `bypass_reason`; cannot expand scope or authorize reserved paths. |
| `bypass_reason` | string | `''` | Required justification for `bypass_samples` or `bypass_gate`; surfaced in the run summary, PR body, and configured tracking issue. |
| `bypass_gate` | boolean | `false` | Validation override for a broken gate. Requires `bypass_reason`; cannot bypass scope guards or public branch rules. |

## Graft Synthesis Recovery

`seed-marks-from-public.sh` is the marks-recovery primitive. It runs in two modes:

**Operator-driven (`workflow_dispatch`).** Use when the marks cache is gone or untrusted but private and public `main` carry equivalent content across the authorized scope. Reconcile real content differences through reviewed PRs first. Then supply `seed_from_public_sha` (and optionally `seed_from_private_sha`) and run with `dry_run=true`; proceed with a real run only after tree equivalence and both scope guards pass.

**Automatic stale-marks recovery.** When `sync-core.sh` runs `fast-import` and the import fails because `PUBLIC_MARKS` references an object no longer reachable in the public repo, sync-core invokes `seed-marks-from-public.sh` automatically against the pair (last-synced private SHA from the `last-synced-private.sha` sentinel file ↔ current public `main` HEAD), then retries fast-import. This is the dominant recovery path in production: it absorbs the SHA-rewrites caused by `gh pr merge --rebase` on public sync PRs, where the imported sync-branch commit is rewritten on merge and the original is later pruned by `gc` after "Close stale sync PRs" runs. Trees still match, so seed-marks succeeds and the next sync is a clean single-commit delta. If the seed's tree-equivalence check fails (real divergence), sync-core hard-fails — it does not silently fall back to a full re-export, because that would produce an orphan branch and a noisy, conflict-prone PR.

> **Why a sentinel and not the tail of `private.marks`?** An earlier implementation derived the recovery anchor by reading the last line of `private.marks` with `awk`, on the assumption that fast-export writes marks in source-commit order. It doesn't — `git fast-export --export-marks` is free to reorder entries, so the tail line could point at an ancestor of the real last-synced commit. When that ancestor was then fed to `seed-marks-from-public` as the recovery base, the tree-equivalence check would either fail (producing a false "real divergence" hard-fail) or, worse, succeed against the wrong tree and silently rewind progress. The explicit `last-synced-private.sha` sentinel removes that class of bug by recording the true last-synced private SHA at every successful sync exit. See May 2026 wedge investigation (ADO 5270567).

The recovery primitive performs a symmetric tree-equivalence check before writing anything:

```bash
git -C private ls-tree -r --full-tree <private-sha> -- <include-pathspecs> | sort
git -C public  ls-tree -r --full-tree <public-sha>  -- <include-pathspecs> | sort
```

The include set is the resolved positive scope for the recovery run: `infrastructure/**`, `samples/**`, and the same `additional_paths` entries intended for the real run, minus validation, unmapped-author, and internal-marker exclusions. The check is symmetric by design. A private-only path and a public-only path in scope both fail, because grafting is incremental and cannot safely repair divergence. Reserved paths, including `.github/CODEOWNERS`, do not participate and are never copied by the bridge.

On success, the seed step writes `private.marks`, `public.marks`, `pathspec.hash`, `root.sha`, and `last-synced-private.sha` into the marks directory, then `sync-core.sh` validates those files and runs incrementally. Expected output is a log line like `Seeded paired marks for private <sha> ↔ public <sha>`. If there are no new public-path commits after the graft point, the sync step should report `has_changes=false`; the coordinated cache-save change persists the seeded marks anyway.

On tree mismatch, the script prints the diff for the diverging tree entries, exits non-zero, and leaves the marks directory unchanged. Do not bypass this failure. Reconcile the reviewed private-owned content through a PR, choose public/private SHAs whose include-set trees match, and rerun the seed recovery with `dry_run=true` before a real run.

### Historical block-list mismatch

The seed-marks tree-equivalence check compares the resolved positive scope after internal-marker and `SYNC_BLOCKED_PATHS` filtering. `SYNC_BLOCKED_PATHS` defaults to the **current** run's computed validation block-list, *not* the block-list that was active when the seed public SHA was produced. When those two differ, recovery fails with "Tree mismatch" on exactly the historically-blocked paths (private has them, public doesn't, current filter no longer hides them).

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

The marks state records the durable default scope. Per-run `additional_paths`, validation block-list entries, and internal marker basenames do not silently become permanent scope. If an implementation change alters the durable default scope, established public history must be re-anchored through reviewed, tree-equivalent seed recovery rather than an unanchored rebuild.

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

- It compares private and public trees only across the durable default scope: `infrastructure/**` and `samples/**`.
- Expected private state applies the current validation and internal-marker exclusions.
- Drift = path missing in public, blob hash differs, or path present in public that should not be there.
- Output goes to the workflow run summary; persistent drift fails the run.

What drift verification does **not** check:

- **Author identity / mailmap correctness** — that's verified upstream during sync (`filter-stream.py` + `sync-mailmap`) and isn't re-derivable from a tree snapshot.
- **One-run `additional_paths`** — those paths are validated by the sync run's pre-push and pre-merge guards but are not part of the durable drift scope.
- **Unmapped-author holds** — they depend on the sync's commit range and cannot be reconstructed from the current trees alone. A path held back only for an unmapped author may appear as drift and requires operator interpretation.
- **Commit message contents or history shape** — only the file tree at `HEAD` is compared.
- **Historical validation status** — v1 checks the current private `main` statuses. If a sample is currently gate-blocked, missing/stale public content for that sample is intentional, not drift.

The script is `.github/scripts/verify-sync.sh`.

## Operational Behavior

| Scenario | Behavior |
|----------|----------|
| Private merge | Does not publish. The bridge runs only when an authorized operator explicitly dispatches it. |
| Manual bridge run | Consumes the validation statuses current on private `main` HEAD and uses only the default scope plus valid `additional_paths`. |
| Dry run | Pushes a guarded `sync/dry-run-*` branch for inspection, with no PR, merge, or marks update. |
| Sample blocked at one sync | The sample is omitted from that sync. It recovers automatically at the next sync after its validation statuses go green. |
| Re-run validation flips status | Latest write wins for the same `(commit, context)`. A later `success` can unblock the sample for the next sync. |
| No reporting pipeline | Grandfathered in v1; the sample syncs unless another validation context reports a block for it. |
| Validation gate is wrong or a sample must be force-included | An operator may use the validation override inputs with a required reason. Scope and reserved-path rules still apply. |
| Public metadata needs a change | Open a normal public PR. Do not use `additional_paths` or private metadata copies. |

Each run should emit a sync-time UX summary listing:

- blocked sample path
- blocking context(s)
- blocking state(s)
- `target_url` when provided by the reporter

For v1, workflow logs and `$GITHUB_STEP_SUMMARY` are sufficient. Phase G owns richer reporting / dashboard work.

## Public Repo Branch Protection

The public repo has a branch ruleset on `main` that requires a pull request and configured required checks. The bridge pushes only a generated branch, opens a reviewable public PR, waits for the ruleset to permit the merge, repeats the generated-diff guard against fresh public `main`, and performs the rebase merge within the same run. It has no supported direct push to public `main`.

`wait-and-merge.sh` deliberately does not use `gh pr merge --auto`. It polls until the PR is mergeable with no pending checks, then calls `gh pr merge --rebase` while authenticated as the App. GitHub enforces the public ruleset; the App is not a bypass actor. Marks are saved only after the pre-merge scope guard and merge succeed.

Do not add the sync App to the ruleset bypass list. If public requirements change, update the workflow and this document together; never compensate by granting a bypass.

## Design Decisions & Gotchas

A short list of things that are easy to get wrong, captured for future-you:

- **Refspec literal names matter.** `git push <remote> sync-tmp:refs/heads/sync-branch` works; `git push <remote> sync-tmp:sync-branch` does not consistently resolve to the intended ref on a fresh remote. Always use the fully-qualified `refs/heads/...` form on the right-hand side.
- **`fast-export --refspec` rewrites literal emitted ref names, not arbitrary source arguments.** `sync-core.sh` pins the export source to `refs/heads/sync-export-source` before exporting so the stream deterministically emits `commit refs/heads/main`. Do not simplify this back to `--refspec=HEAD:refs/heads/main`; detached CI checkouts silently write imports to the wrong ref and can produce a public branch with no imported authorship. See the gotchas block at the top of `.github/scripts/sync-core.sh` and regression T28 in `.github/tests/test-sync.sh`.
- **Out-of-scope-only changes produce no public commits.** `filter-stream.py` drops empty commits. Changes outside `infrastructure/**`, `samples/**`, and valid `additional_paths` therefore produce a clean no-op.
- **Public metadata is public-owned.** The bridge never copies README, CONTRIBUTING, CODEOWNERS, workflows, issue templates, or other `.github/**` content. Maintain them through normal public PRs.
- **`additional_paths` is exact, not glob-based.** A trailing slash authorizes a directory prefix; no trailing slash authorizes one file.
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

This is normal if the only commits since the last sync touched paths outside the positive scope or if all otherwise-eligible sample changes are currently gate-blocked. `filter-stream.py` drops the resulting empty commits, so the Push and Create-PR steps skip with a "no new commits" log line.

To verify, check:

1. The run summary for blocked samples.
2. The sync-core log for export/filter/import commit counts.
3. Whether the changed paths are under `infrastructure/`, `samples/`, or the run's `additional_paths`.

### Sample did not appear in public repo

1. Verify the path is under `samples/`.
2. Verify the commit was on `main` before the sync ran.
3. Check the sync run summary for validation-blocked samples.
4. Query the private commit status for the synced SHA and inspect `validation/*` contexts.
5. If statuses are now green, dispatch the sync manually.

### Sync PR opened but never merged

1. Check `wait-and-merge.sh` log output for the polling loop's exit reason.
2. Confirm required checks on the public repo all completed green.
3. Inspect the pre-merge generated-diff guard result.
4. Confirm any reviews required by the current public ruleset have been submitted; the App must not bypass the ruleset.

### Author attribution is wrong

1. Check `.github/sync-mailmap` for the correct mapping.
2. Entries follow git mailmap format: `Public Name <public@email> Internal Name <internal@email>`.

### Generated-diff scope guard failed

The generated branch contains a path outside the resolved positive scope or a reserved path. The guard output identifies the offending path and whether the failure occurred before push or immediately before merge.

Do not broaden scope to hide the failure. For public metadata, open a normal public PR. For an approved non-reserved content path, correct the `additional_paths` syntax and start with a dry run. If fresh public `main` introduced real divergence, reconcile through reviewed PRs before seed recovery.

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

For the current step-by-step, use [Sync Incident Response](../.github/skills/sync-incident-response.md). The older [Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) records the 2026-06-09 → 2026-06-10 incident history, but its full-export, orphan-recovery, overlay, and per-file protected-path procedures are retired.

### Need to revert a sync

1. Find the rollback SHA from the sync PR description.
2. Revert the affected public commits through a reviewed public PR; do not push directly to `main`.
3. Reconcile the corresponding private-owned content, then seed from reviewed equivalent public/private SHAs with `dry_run=true` before the real recovery run.

Rollback affects public content. It does not rewrite private validation statuses; fix or re-run validation separately if the rollback is related to gate behavior.

## Changelog

Entries before 2026-08-26 describe historical implementations. They are retained for incident traceability and are not current operating guidance.

| Date | Change |
|------|--------|
| 2026-08-26 | **Retired `public-overlay/` and special CODEOWNERS forwarding after public incident PR [microsoft-foundry/foundry-samples#940](https://github.com/microsoft-foundry/foundry-samples/pull/940), tracked by [ADO 5555347](https://msdata.visualstudio.com/Vienna/_workitems/edit/5555347).** Replaced the negative-exclusion publication model with default positive scope `infrastructure/**` and `samples/**`, added one-run `additional_paths` for approved non-reserved paths, reserved public metadata for normal public PRs, and required generated-diff scope guards before push and immediately before merge. |
| 2026-08-25 | **Removed destructive routine sync modes (ADO 5551175).** Private→public sync is manual-only and incremental after first bootstrap. Removed force-full/direct-main publication and orphan full-export recovery; established-public marks failures now require verified seed recovery. The repository-admin follow-up removed the public sync App from the `main` ruleset bypass list. |
| 2026-08-05 | **Historical per-file protection change for the legacy public PR redirect workflow ([ADO 5499173](https://msdata.visualstudio.com/Vienna/_workitems/edit/5499173)).** Removed `.github/workflows/redirect-pull-requests.yml` from the then-active `protected_paths` model after public-first validation made public PRs the required merge gate. The entire per-file model was retired on 2026-08-26. |
| 2026-06-29 | **mirror-back: skip on author identity only, not committer (ADO 5398977, PR #620).** `should_skip_commit` previously checked all four git identity fields (author name, author email, committer name, committer email) against the sync-bot identities. Human PRs merged to public via "direct rebase merge as the App" have a human author but sync-bot committer; this caused them to be silently dropped, producing public drift that broke sync marks on the next run. Fix: check author only. The sync pipeline always sets `GIT_AUTHOR_NAME` to the bot identity, so real sync commits still skip correctly. Regression test `test_human_author_bot_committer_not_skipped` (MB4) added to `.github/tests/test-mirror-back.sh`. Troubleshooting section updated with marks-drift recovery recipe. |
| 2026-06-11 | **Cross-link added to sync-recovery runbook.** Troubleshooting section and Related Documents now link to [`foundry-devx-eng-docs/operations/sync-recovery-runbook.md`](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — the canonical end-to-end playbook authored after the 2026-06-09 → 2026-06-10 sync saga. No mechanism changes in this entry. |
| 2026-06-10 | **Exclude-path filtering moved into `filter-stream.py` (ADO 5347427).** `git fast-export` previously ran with pathspec args, which forced `--full-tree` mode: when marks anchored on a real public commit (e.g. post-seed-recovery anchoring at `PUBLIC_SHA`), each new sync-branch commit's tree represented a wholesale delete of excluded paths (`.github/`, etc.) relative to that parent. The protected-paths guard correctly fired on this "wipe" but the wipe was structurally unnecessary — public main's workflows should pass through unchanged. Fix: drop pathspec args from `fast-export` (export now runs in delta mode), add `--no-renames` so renames decompose into D+M pairs, and apply the include-set filter in `filter-stream.py` via a new repeatable `--exclude-path` CLI arg. Dropped commits are spliced out of the mark chain (`dropped_mark_to_parent` resolution on `from :N` / `merge :N`) so `fast-import` never hits "mark :N not declared". Sync-branch commits now inherit excluded-path content from their marks-anchored parent → merge-tree result preserves protected workflows → guard passes structurally rather than relying on coincidental tree topology. Test T70 flipped from wipe-detection to seed-recovery happy-path; T66 retains genuine orphan-wipe coverage; T71 / T72 added for rename-across-boundary in both directions. Requires a one-shot `workflow_dispatch` with `seed_from_public_sha` + `seed_from_private_sha` after deployment to re-anchor existing marks. |
| 2026-06-09 | **Protected-paths guard fixed (ADO 5347121).** Replaced the sync-branch-tip blob comparison in `guard_protected_paths()` with a `git merge-tree --write-tree` simulation against the prospective post-rebase-merge tree. Normal incremental syncs (`fast-export --import-marks` + pathspec topology) now pass cleanly while seed-marks-recovery wipes still hard-fail. Requires git ≥ 2.38; CI runners are 2.43+. Test T69 (added in PR #492 as a RED reproducer) flips green; T70 (seed-marks wipe regression coverage) stays green. Re-enabling the scheduled cron is tracked separately as ADO 5347122. |
| 2026-06-08 | **Scheduled sync paused.** Commented out cron in `sync-to-public.yml` and documented a newly-discovered architectural bug in the protected-paths guard from PR #463. `git fast-export --import-marks` + pathspec filters force `--full-tree` mode, so the sync branch tip's tree never contains `.github/` entries; the guard's blob comparison cannot pass once protected files exist on public main. Fix tracked as ADO 5347121; sync runs only via `workflow_dispatch` until the fix lands. |
| 2026-06-08 | Added `seed_blocked_paths` `workflow_dispatch` input to `sync-to-public.yml` so the seed-marks tree-equivalence check can be run against a historical block-list. Exposed by the post-PR-#463 recovery: morning's scheduled sync wrote marks at a public SHA produced under a large validation block-list; later auto-recovery refused tree-equivalence on those historically-blocked paths. See [Historical block-list mismatch](#historical-block-list-mismatch). |
| 2026-06-08 | Added the historical protected-paths guard to `sync-core.sh` (PR #463). Public-only workflow files were listed in `sync-config.json`'s `protected_paths` so sync runs would hard-fail before deleting or modifying them. This per-file mechanism was retired on 2026-08-26 in favor of positive scope plus generated-diff guards. |
| 2026-05-04 | Implemented Phase D4 + D4b atomically in PR-B: `compute-blocklist.sh` (shared entry point), `sync-to-public.yml` calls it before sync and passes `SYNC_BLOCKED_PATHS` into `sync-core.sh`, `verify-sync.yml` independently calls it and passes the same env into `verify-sync.sh`. Added `bypass_samples` / `bypass_reason` / `bypass_gate` workflow_dispatch inputs with mandatory loud surfacing (run-summary banner, PR body footer, auto-comment on `vars.BYPASS_LOG_ISSUE_NUMBER`). |
| 2026-04-30 | Implemented Phase D2 in PR #215: `sync-core.sh` now honors `SYNC_BLOCKED_PATHS` as the dynamic per-run validation exclusion seam. |
| 2026-04-29 | Reopened sync-gating decision; sync now honors GitHub commit statuses per `docs/validation-results-contract.md`. See `docs/validation-story-decisions.md`. |

## Related Documents

- [Sync Incident Response](../.github/skills/sync-incident-response.md) — Current fail-closed operational playbook.
- [Sync Recovery Runbook (foundry-devx-eng-docs)](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — Historical incident context; retired destructive, overlay, and per-file guard procedures are not current guidance.
- [Validation Story — Phase B Decisions](validation-story-decisions.md) — Locked decisions that supersede earlier validation/sync-gating text.
- [Validation Contract](validation-contract.md) — Validation behavior and gate contract.
- [Validation Results Contract](validation-results-contract.md) — How validation pipelines post per-sample GitHub commit statuses.
- [External Contributions](external-contributions.md) — How partner samples flow through sync.
- [Sync Cutover Runbook](sync-cutover-runbook.md) — The one-time authorship-preserving history rewrite of public `main`.
- [Sync Config](../.github/sync-config.json) — Bridge scope and public repo target.
- [Sync Core Script](../.github/scripts/sync-core.sh) — The sync implementation.
- [Wait-and-merge Script](../.github/scripts/wait-and-merge.sh) — Ruleset-bound rebase-merge polling logic.
- [Verify Sync Script](../.github/scripts/verify-sync.sh) — Drift checker.
