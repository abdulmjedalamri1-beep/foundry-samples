# Validation Contract

> **Transitional private contract:** This document describes the still-live private ADO validator and the retained bridge's private-status filter while P6 retirement remains pending. It is not the public contribution or merge contract. Public pull requests require the `trusted` check and use the public [Build-readiness and Live-service contract](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md).

This document defines what private validation means in `foundry-samples-pr` and how those results can hold content back during a separately authorized bridge run.

It governs two contracts:

1. **Validation behavior** — what a sample must prove, how `sample.yaml` participates in validation, and how build-readiness levels are interpreted.
2. **Sync gating** — how validation results become per-sample pass/block signals for the private-to-public sync.

The posting mechanics for external validation pipelines live in [Validation Results Contract](validation-results-contract.md). The sync workflow internals live in [Repo Sync Automation](repo-sync-automation.md).

## Transitional bridge rule

> **Private statuses filter an authorized bridge run.** They do not initiate publication, authorize an operator dispatch, or satisfy the public `trusted` gate.

This is the locked direction from [Validation Story — Phase B Decisions](validation-story-decisions.md). That decision supersedes the earlier "manifest decided against" and "sync gating decided against" text.

## Private ADO build-readiness levels

The private ADO pipeline uses cumulative numbered levels. This terminology remains only for that live transitional contract; current public documentation uses **Build readiness** and **Live-service validation**.

| Level | Name | What it proves | Example |
|-------|------|----------------|---------|
| 1 | **Parse** | Code is syntactically valid | `python -m py_compile sample.py` |
| 2 | **Resolve** | Dependencies install cleanly | `pip install -r requirements.txt` exits 0 |
| 3 | **Load** | Code loads with all dependencies resolved | `python -c "import sample"` exits 0 |
| 4 | **Run** | Code runs against live resources or deployed infrastructure | Provision with `azd`, deploy, then exercise the sample against Azure |

**Level 3 (Load) remains the floor for tracked samples.** A tracked sample that does not demonstrate load-readiness is not eligible for sync.

**Level 4 (Run), now called Live-service validation in the public contract, is opt-in and additive.** It covers live Azure resources, deployed services, federated identity / OIDC, and end-to-end checks that cannot be expressed as ordinary build/load validation. It never replaces private Level 3; it augments private bridge-time evidence for samples whose owning pipeline reports it.

### Tier promotion is implicit

There is no `level: 4` field in `sample.yaml` and no central registry of samples that "require L4".

The act of reporting is the act of opting in:

- A pipeline that reports L3 results gates those samples at L3.
- A pipeline that reports L4 results gates those samples at L4.
- If a sample needs L4, its owning team makes sure an L4-capable pipeline reports a status for that sample.

The sync gate does not need to understand the level number. It honors reported validation statuses.

## The `sample.yaml` Contract

`sample.yaml` is the contract used by the ADO sample validation pipeline (`.azure-pipelines/validation.yml`). It gives the pipeline a sample root, metadata, and optional custom commands.

`sample.yaml` is **one path** to being tracked by private validation. It is not the only path. Team-owned internal pipelines can track samples through their own manifests and status reporters. For example, Hosted Agents uses `agent.manifest.yaml` and reports through its own cloud E2E workflow. Those tracking-set definitions belong in [Validation Results Contract](validation-results-contract.md).

### Schema

```yaml
# Required metadata
name: my-sample                      # Human-readable identifier
description: What this demonstrates  # Brief description

# Optional validation commands (run in order)
build: <command>       # Build step (Level 2: resolve dependencies)
validate: <command>    # Validation step (Level 3: prove load-readiness)
test: <command>        # Test step (optional, post-validation)
```

### Behavior rules

1. ADO `validation.yml` discovers samples by finding `sample.yaml` under `samples/`.
2. If **any** of `build`, `validate`, or `test` are specified, those commands run and language defaults are skipped.
3. If **none** are specified, the pipeline applies default validation based on the language directory.
4. Commands run in order: `build` -> `validate` -> `test`. If any step exits non-zero, the sample fails.
5. A directory without `sample.yaml` is invisible to ADO `validation.yml`; it can still be tracked by another pipeline if that pipeline reports statuses for it.

### Default validation by language

When `sample.yaml` has no custom commands, these defaults apply:

| Language | Default build | Default validation |
|----------|---------------|--------------------|
| C# | `dotnet build *.csproj` | — (build proves load) |
| Python | Create venv + `pip install -r requirements.txt` | `py_compile` all `.py` files |
| TypeScript/JS | `npm install` | `npm run build` (if build script exists) |
| Java | `mvn compile` or `gradle build` | — (compilation proves load) |
| Go | `go build ./...` | — (compilation proves load) |

### Python Hosted Agent dependency admission policy

In addition to build-readiness validation, pull requests use a ratchet policy for executable Python projects under `samples/python/hosted-agents/`. New Python Hosted Agent services and existing services whose dependency inputs change must commit a fully resolved `requirements.txt` as the portable consumer artifact. This admission check runs before sample-specific commands and is not a repository-wide Python requirement.

The ratchet does not retroactively fail legacy Hosted Agent dependencies during source-only or documentation-only changes. See the [Python Hosted Agent dependency policy](../samples/python/hosted-agents/DEPENDENCY_POLICY.md) for its triggers, accepted requirement forms, authoring-tool neutrality, closure validation, and exception process.

### Recommended custom commands

For samples that specify custom validation, use these patterns:

| Language | `build` | `validate` | What it proves |
|----------|---------|------------|----------------|
| Python | `pip install -r requirements.txt` | `python -c "import sample"` | Deps resolve, code loads |
| C# | `dotnet restore` | `dotnet build` | Compilation proves load |
| Java | `mvn dependency:resolve` | `mvn compile` | Compilation proves load |
| Go | `go mod download` | `go build ./...` | Compilation proves load |
| TypeScript | `npm install` | `npx tsc --noEmit` | Type-checks all imports |
| JavaScript | `npm install` | `node -e "require('./sample')"` | Deps resolve, code loads |

## The transitional bridge filter contract

The retained bridge uses a **per-sample block-list** driven by GitHub commit statuses on `main` commits in `microsoft-foundry/foundry-samples-pr`. This is separate from the public pull request's required `trusted` check.

Default = sync. A sample is blocked iff it has at least one reported validation status with state `failure`, `error`, or `pending` at the private `main` SHA being synced. Passing samples and untracked samples continue through the sync, subject to normal path exclusions.

### Status context naming

All validation reporters MUST use this context format:

```text
validation/<pipeline-id>/<sample-path>
```

Where:

| Segment | Meaning |
|---------|---------|
| `validation` | Fixed prefix. Only statuses under this prefix participate in sample gating. |
| `pipeline-id` | Short documented slug for the validating pipeline, such as `ado-build` or `hosted-agents-e2e`. |
| `sample-path` | Canonical sample directory relative to the repo root, such as `samples/python/agents/basic`. |

`sample-path` should preserve `/` where GitHub status contexts allow it. If a reporter must flatten the path, use `--` as the separator and document that in [Validation Results Contract](validation-results-contract.md).

### State semantics

| Private GitHub status state | Authorized bridge behavior for that sample |
|---------------------|-------------------------------|
| `success` | Does not block sync. |
| `failure` | Blocks sync. |
| `error` | Blocks sync. |
| `pending` | Blocks sync; do not publish while validation is still running. |

Statuses live on private-repo SHAs. They do not propagate to public commits after fast-export / author rewriting / import and do not control normal public pull requests. The filter is evaluated only during an authorized bridge run.

## Tracked vs Untracked

A sample is **tracked** iff at least one validation pipeline reports a `validation/<pipeline-id>/<sample-path>` status for it.

A sample is **untracked** if no validation pipeline reports a status for it. Untracked samples are grandfathered and sync ungated. This is intentional for v1: existing content keeps flowing until an owning pipeline explicitly opts it into validation gating.

Known tracking sources:

| Source | Tracking rule | Tier |
|--------|---------------|------|
| ADO `validation.yml` | Directory under `samples/` containing `sample.yaml` | L3 |
| Hosted Agents cloud E2E | Directory containing `agent.manifest.yaml` and not opted out by that workflow | L4 |
| Future pipelines | Defined by the pipeline and documented in `docs/validation-results-contract.md` | L3 or L4 |

A directory with no `sample.yaml` but with a reported external status is tracked. A directory with `sample.yaml` is tracked by ADO validation once ADO reports a status for it.

Non-sample content — README files, LICENSE, CODEOWNERS, top-level helpers — is not sample-gated unless a validation reporter explicitly posts a sample-style status for it. Path-based sync exclusions remain separate and are defined in `.github/sync-config.json`.

## When Validation Runs

| Trigger | Scope | Purpose |
|---------|-------|---------|
| Pull request to `main` | Changed samples only | Fast feedback for authors |
| Push to `main` | Changed samples validated; **all tracked samples receive a status** via carry-over fan-out from parent SHA | Publish per-sample statuses for the synced commit (gates D4) |
| Scheduled (Mon/Wed/Fri) | All `sample.yaml` samples for ADO validation | Catch SDK drift and broken dependencies |
| Manual (`validateAll=true`) | All `sample.yaml` samples for ADO validation | On-demand full sweep |
| Manual (re-queue, `validateAll=false`) on `main` | Same as a push to `main`: fan-out posts statuses | Re-run after incident / token issue without an organic push |

Push-to-`main` runs are queued for **every** commit on `main`, regardless of whether `samples/` was touched. Commits that only change docs, infrastructure, or pipeline scripts still produce a fully-populated set of `validation/ado-build/<sample-path>` statuses — the changed-set is empty, so every sample's status carries over from the parent SHA. This is what D4's per-SHA sync gate depends on.

External validation pipelines define their own triggers. To participate in sync gating, they must report statuses on the `main` commit that sync will evaluate.

## What This Contract Does Not Cover

This contract intentionally stays at the what/why layer.

It does **not** define:

- The GitHub Statuses API call shape, credentials, retry behavior, or per-pipeline registration process. Those live in [Validation Results Contract](validation-results-contract.md).
- The internals of the private-to-public sync workflow, fast-export filtering, author rewriting, or dynamic path exclusion. Those live in [Repo Sync Automation](repo-sync-automation.md).
- A freshness/max-age rule for validation results. v1 honors whatever status is current at sync time; scheduled runs provide natural refresh.
- Advisory/non-blocking validation contexts. In v1, if a pipeline does not want to block sync, it should not report under the `validation/` context convention.
- Break-glass overrides or operator UX for blocked samples. Those are follow-up workflow concerns.

## Implementation Status

> **Last updated:** 2026-08-27 for public-default routing and the P6 transition boundary.

| Feature | Status | Notes |
|---------|--------|-------|
| Per-language default validation | ✅ Implemented | `validation.yml` handles C#, Python, TypeScript/JS, Java, and Go. |
| Python Hosted Agent dependency ratchet | ✅ Implemented | New or dependency-updated runtimes under `samples/python/hosted-agents/` must commit a fully resolved `requirements.txt`. |
| `sample.yaml` discovery | ✅ Implemented | ADO pipeline discovers samples with `find samples -name sample.yaml`. |
| Custom build/validate/test commands | ✅ Implemented | Overrides defaults when present. |
| PR comment reporting | ✅ Implemented | `GitHubComment@0` posts PR summaries. |
| Per-sample GitHub commit statuses | 🔲 Required for gate | Normative context: `validation/<pipeline-id>/<sample-path>`. Posting details live in `validation-results-contract.md`. |
| Per-sample sync block-list | 🔲 Required for gate | Sync must block samples with `failure`, `error`, or `pending` validation statuses at the private `main` SHA. |
| L4 opt-in validation | 🟡 Canary exists | Hosted Agents cloud E2E is the canary; it must report statuses to become load-bearing for sync. |
| `samples-classic/` coverage | 🔲 Not yet | Classic samples are untracked unless a pipeline reports statuses for them. |

## Changelog

- 2026-04-29: Reopened L3 cap (added L4 opt-in tier). Reopened sync-gating decision (now per-sample block-list via commit statuses). See `docs/validation-story-decisions.md`.

## Related Documents

- [Validation Story — Phase B Decisions](validation-story-decisions.md) — Locked decisions that supersede earlier validation/sync-gating text.
- [Validation Results Contract](validation-results-contract.md) — Pipeline registry, status posting convention, credentials, retry semantics, and tracking-set definitions.
- [Repo Sync Automation](repo-sync-automation.md) — How the manually dispatched sync from private to public works.
- [External Contributions](external-contributions.md) — Historical private partner-governance record and current public pointer.
- [Public per-sample validation contract](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md) — Current Build-readiness and Live-service behavior.
- [Public daily validation cadence](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/validation-pilot.README.md) — Warm-project fleet validation and reports.
- [Pipeline README](../.azure-pipelines/README.md) — Operational details of the ADO validation pipeline.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — Contributor guide with validation quick-reference.
