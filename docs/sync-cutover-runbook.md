# Sync Cutover Runbook

This document records the **one-time** authorship-preservation cutover performed on 2026-04-29 against the public `foundry-samples` repository. It is preserved as historical evidence, not as a reusable recovery template.

> If you are a regular contributor and have arrived here looking for "how does sync work day to day," you want [Repo Sync Automation](repo-sync-automation.md). This document is for one-off pipeline surgery.
>
> **Historical procedure only:** the current sync workflow does not expose full-tree export, direct-public-main push, or force-push recovery. Do not use the steps below for a routine incident. Reconcile through reviewed PRs and use verified seed recovery with `dry_run=true` as documented in [Repo Sync Automation](repo-sync-automation.md).
>
> **Current scope:** the retained bridge defaults to `infrastructure/**` and `samples/**`. An operator may add approved non-reserved paths with `additional_paths`, but `README.md`, `CONTRIBUTING.md`, `.github/**`, and `public-overlay/**` are always reserved for normal public PRs. The current bridge runs a generated-diff scope guard before push and again immediately before merge.

## What changed

Before the cutover, the sync pipeline used a different rewriting model that caused **every** synced commit on public to appear authored by a single human (the workflow's then-author). Public `git blame` was therefore useless for attribution.

After the cutover:

- The sync rewrites authorship using `.github/sync-mailmap`, mapping internal aliases to the contributor's public identity.
- Public `git blame` shows the real author of each line.
- Bot-authored commits (the sync App, `github-actions[bot]`) are filtered out of the rewritten stream.
- A `legacy/main-pre-authorship-cutover` branch and `pre-authorship-cutover-2026-04-29` tag preserve the old public history.

The cutover required a **force-push of public `main`** to a fully rewritten history; standard merges would have produced a Frankenstein log mixing old single-author commits with new rewritten ones.

## Pre-cutover preserved state

| Reference | What it points to |
|-----------|-------------------|
| Tag `pre-authorship-cutover-2026-04-29` (public repo) | Last commit of the *pre-cutover* public `main` |
| Branch `legacy/main-pre-authorship-cutover` (public repo) | Same commit, kept as a branch for easier checkout |
| Tag `pre-authorship-cutover-2026-04-29` (private repo) | Private-side snapshot at cutover time |

Recovering the old state, if ever needed, is a reset to either reference followed by a force-push (subject to the same ruleset disablement step described below).

## Post-cutover state

| Reference | Value (at cutover time) |
|-----------|-------------------------|
| Public `main` head | `f532c159ac80d60e5edc46693733801fee0c7469` |
| Sync App (historical bypass actor at cutover time) | `foundry-samples-repo-sync` (App ID `2846614`) |
| Bot user ID | `261063410` |
| Public `main` ruleset ID | `6131793` |

## The procedure

### 0. Pre-flight

- Confirm both repos are at green CI on `main`.
- Confirm the new sync pipeline (filter-stream, mailmap, fast-export/fast-import) has been validated against a **dry-run** target. The dry run should produce a tree-equivalent `main` to what's currently public, with rewritten authorship.
- Stop the then-nightly sync schedule for the duration of the historical cutover (workflow disabled in the UI).
- Notify stakeholders that public `main` will force-push.

### 1. Snapshot

In the public repo:

```sh
git fetch origin
git tag pre-authorship-cutover-$(date -u +%Y-%m-%d) origin/main
git push origin pre-authorship-cutover-$(date -u +%Y-%m-%d)
git push origin origin/main:refs/heads/legacy/main-pre-authorship-cutover
```

In the private repo, tag the matching state:

```sh
git tag pre-authorship-cutover-$(date -u +%Y-%m-%d) origin/main
git push origin pre-authorship-cutover-$(date -u +%Y-%m-%d)
```

### 1a. Inventory public-only paths (do not skip)

Before the force-push, enumerate every path on public `main` that lives under an excluded path in `sync-config.json` (or matches an excluded file) and is therefore **not present in the rewritten stream**. These are the files that will be wiped by the force-push and will need restoration afterward.

```sh
# In a clone of public repo
git ls-tree -r --name-only origin/main > /tmp/public-paths.txt
# Cross-reference against exclude_pathspecs from sync-config.json — anything
# matching an exclude is public-only and at risk.
```

Typical public-only paths:

- `README.md`, `CONTRIBUTING.md` (public-only versions of the private files)
- `.github/CODEOWNERS` (public review routing)
- `.github/workflows/*` (any workflow that only runs on public — e.g., PR redirect, public-side checks)
- `.github/scripts/*` (helpers used by those workflows)
- `.github/copilot-instructions.md` (if maintained separately on public)

Save the full list — you will replay it onto the new history in step 5a.

### 2. Disable the public `main` ruleset

The branch ruleset on public `main` blocks force-push even for bypass actors when certain rules are enabled. **Set the ruleset to "Disabled" in the UI** (Settings → Rules → Rulesets → Edit → Enforcement status: Disabled) for the duration of the force-push.

A ruleset *disable* is recoverable and audited; deleting and recreating the ruleset is not. Use disable.

### 3. Rebuild and force-push (historical cutover only)

At the 2026-04-29 cutover, a temporary non-incremental pipeline targeted public `main` directly. That retired pipeline:

1. Stream all of private `main` through `filter-stream.py` with `.github/sync-mailmap` applied.
2. Fast-import into a fresh ref on the public side.
3. Force-push that ref to `refs/heads/main`.

Confirm the resulting `main` head SHA matches the dry-run prediction before proceeding.

The current `sync-to-public.yml` cannot perform this operation. Any future history surgery requires a separately reviewed, time-bounded admin plan; it must not be added back as a routine workflow input or recovery path.

### 4. Re-enable the ruleset

At the 2026-04-29 cutover, the ruleset was set back to "Active" and the App remained a bypass actor.

> **Current boundary:** The App is no longer a public `main` ruleset bypass actor. Do not restore that historical configuration. The current bridge opens a reviewable public PR, waits for required checks, repeats the generated-diff scope guard, and rebase-merges as the App subject to the ruleset. See [Repo Sync Automation § Public Repo Branch Protection](repo-sync-automation.md#public-repo-branch-protection).

### 5. Verify

The historical cutover ran Verify Sync on the public repo and required `drift=false` before restoring operations. Drift immediately after the force-push indicated a path-exclusion or filter bug.

Spot-check public `git blame` on a few recently-edited samples; the authors should be the real contributors, not the App or a single human placeholder.

### 5a. Restore public-only files (do not skip)

The force-push wiped everything that was not in the rewritten stream — including the public-only files inventoried in step 1a. Open a PR on the public repo that restores those files **verbatim** from `legacy/main-pre-authorship-cutover`:

```sh
git fetch origin 'refs/heads/legacy/main-pre-authorship-cutover:refs/remotes/origin/legacy/main-pre-authorship-cutover'
git checkout -b restore/public-only-files-from-cutover
for f in <list-from-step-1a>; do
    mkdir -p "$(dirname "$f")"
    git checkout origin/legacy/main-pre-authorship-cutover -- "$f"
done
git commit -m "Restore public-only files lost during cutover"
gh pr create --base main
```

Do **not** skip this step. The 2026-04-29 cutover did skip it (the runbook didn't yet contain it) and the public repo lost its README, CONTRIBUTING, and several public-only workflows including PR redirect and PR checks. The omission was caught only when a contributor noticed the README missing days later — see [foundry-samples PR #676](https://github.com/microsoft-foundry/foundry-samples/pull/676).

### 6. Re-enable the schedule (historical)

At cutover time, the nightly workflow was re-enabled and its next run was checked. The current private→public workflow is manual-only.

## Historical rollback

The 2026-04-29 rollback plan was:

1. Disable the ruleset (step 2 above).
2. `git push --force origin refs/tags/pre-authorship-cutover-YYYY-MM-DD:refs/heads/main` from a local clone with admin/bypass credentials.
3. Re-enable the ruleset.
4. Disable the sync schedule until the underlying issue is resolved.

The `legacy/main-pre-authorship-cutover` branch remains historical evidence. Do not use this rollback for a current bridge incident. Current incidents must reconcile content through reviewed PRs and use the fail-closed recovery in [Repo Sync Automation](repo-sync-automation.md#graft-synthesis-recovery).

## Post-cutover follow-ups

The cutover surfaced three issues that were tracked separately:

- **Historical auto-merge behavior.** GitHub's `--auto` merge ran as the system process rather than the requesting actor. The bridge now uses poll-then-rebase-merge (`wait-and-merge.sh`) so the run observes the merge before saving marks. The App is ruleset-bypass-free. See [Repo Sync Automation § Wait-and-merge](repo-sync-automation.md#7-wait-and-merge-ruleset-bound-app-rebase-merge).
- **CodeQL `actions` analysis on public.** At cutover time, the public repo had `actions` enabled in default-setup CodeQL, producing false positives because the restored public workflow state was incomplete. The setting was corrected in the public repo's Code Security configuration.
- **Public-only files wiped by the force-push.** Step 1a / 5a above did not exist in the original runbook; as a result, README.md, CONTRIBUTING.md, and seven public-only `.github/` workflows / scripts were lost and had to be restored later. The runbook has been updated to make the inventory and replay steps explicit.

## Lessons from 2026-06-10 sync recovery

The sync saga of 2026-06-09 → 2026-06-10 reinforced several principles that this runbook predates. The older recovery runbook in `foundry-devx-eng-docs` remains useful for incident history, but its full-export, orphan-recovery, overlay, and per-file protected-path procedures are retired:

- [`foundry-devx-eng-docs/operations/sync-recovery-runbook.md`](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — historical sync-recovery context

Saga-specific lessons that *this* runbook absorbs:

- **The entire overlay is retired.** PR [microsoft-foundry/foundry-samples-pr#513](https://github.com/microsoft-foundry/foundry-samples-pr/pull/513) (ADO 5347427) established that public-only workflows did not belong in `public-overlay/`. The later 2026-08-26 incident, public PR [microsoft-foundry/foundry-samples#940](https://github.com/microsoft-foundry/foundry-samples/pull/940), showed that stale overlay copies of `README.md` and `CONTRIBUTING.md` could also overwrite public-owned metadata. `public-overlay/` is now reserved and has no active publication role.
- **Special CODEOWNERS forwarding is retired.** Public `.github/CODEOWNERS` is public metadata and is maintained through normal public PRs.
- **Positive scope replaces negative exclusions.** Current default scope is `infrastructure/**` and `samples/**`; `additional_paths` can add only approved non-reserved paths for one dispatch.
- **Generated-diff guards replace per-file protection.** The bridge validates every actual changed path before push and repeats the same validation against fresh public `main` immediately before merge.
- **Recovery must be verified before mutation.** Reconcile content through reviewed PRs, prove scoped tree equivalence, and run operator-driven seed recovery with `dry_run=true` before a real run.
- **Destructive modes are retired.** Current workflow contract tests reject force-full, direct-main, unanchored full-export, and unrelated-history paths.

For the full incident timeline and historical decisions, read the sync-recovery runbook linked above. For current behavior and recovery, use [Repo Sync Automation](repo-sync-automation.md).

## Why the historical cutover used a force-push

Three reasons:

1. **Authorship can't be rewritten in-place.** Git commits are immutable; rewriting authorship produces new SHAs for every commit. There is no way to "convert" the existing public history to use the new authors.
2. **A merge of rewritten history into existing history would double every commit.** Public would contain both the old single-author commit and the new rewritten commit for every change. `git blame` would still resolve to the latest commit — usually the rewritten one — but the log would be twice as long and confusing forever.
3. **The legacy branch and tag preserve the old state.** Anyone who wants to inspect pre-cutover history can check out the legacy branch; the cost of the force-push is therefore just the disruption of one moment, not permanent loss of history.

## Related Documents

- [Sync Recovery Runbook (foundry-devx-eng-docs)](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) — Historical incident context; retired destructive and overlay recovery options are not current procedure.
- [Repo Sync Automation](repo-sync-automation.md) — Current operator bridge scope, guards, failure semantics, and recovery
- [Validation Contract](validation-contract.md) — Validation responsibilities (no longer cross-coupled with sync)
- [Filter stream script](../.github/scripts/filter-stream.py) — Authorship rewriting + path filtering
- [Sync mailmap](../.github/sync-mailmap) — Internal alias → public identity mapping
