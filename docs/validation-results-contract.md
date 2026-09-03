# Validation Results Contract

> **Status:** Initial contract. Created 2026-04-29 as Phase C4 of the validation realignment.
>
> **Internal-only.** This file lives under `docs/`, which is excluded from public sync by `.github/sync-config.json`.
>
> **Source of truth for decisions:** `docs/validation-story-decisions.md`. If this document appears to disagree with that file, the decisions file wins and this file should be corrected.
>
> **P6 transition:** This remains the private status-posting contract for the live ADO and team-owned reporters consumed by an authorized bridge run. It does not define normal public publication or the public required merge gate. Public pull requests require `trusted`; current public validation uses [Build readiness and Live-service validation](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md).

## Purpose & audience

This is the technical contract for posting private validation results that participate in the retained bridge's transitional block-list for `microsoft-foundry/foundry-samples-pr`.

Audience:

- DevX Engineering, for the repo-owned ADO validation pipeline.
- Internal feature teams that own their own validation pipeline.
- Anyone implementing the sync gate or debugging why a sample did or did not sync.

The goal is simple: an internal pipeline can validate the samples it owns, publish durable per-sample results to private GitHub commit statuses, and have an authorized bridge run honor those results without a central manifest service.

This document is about **how to post results**. The validation levels, sample metadata expectations, and repo-wide validation story live in `docs/validation-contract.md` and `docs/validation-story-decisions.md`.

## The mechanism in 30 seconds

Post a GitHub commit status to `microsoft-foundry/foundry-samples-pr` for every sample your pipeline ran against.

- Post to the exact commit SHA your pipeline validated.
- Use the context convention `validation/<pipeline-id>/<sample-path>`.
- Use `success` for pass.
- Use `failure`, `error`, or `pending` for a result that should block sync.
- Include a `target_url` for non-success states so the owner can get to the run that failed.

At sync time, the gate reads the commit statuses on the private repo commit being synced. Any current validation status under the convention with state `failure`, `error`, or `pending` blocks that sample from syncing to public.

## Contract

### Status target

Post to the commit SHA your pipeline ran against.

For `main` HEAD freshness:

- Trigger on `push` to `main`.
- Optionally add a schedule to refresh results when platform dependencies, SDKs, credentials, or live resources drift without a repo change.

The sync gate reads statuses from the private repo commit it is syncing. For a manually dispatched sync, that is `main` HEAD in `foundry-samples-pr`.

### Status context naming

All validation reporters **MUST** use this context shape:

```text
validation/<pipeline-id>/<sample-path>
```

| Segment | Rule |
|---------|------|
| `validation` | Literal prefix. This is how the gate distinguishes validation statuses from ordinary CI checks. |
| `pipeline-id` | Lowercase, hyphenated slug for the validating pipeline. It must be listed in the registry below before a team treats it as production-owned. |
| `sample-path` | Canonical sample directory relative to the repo root, for example `samples/python/hosted-agents/echo-agent`. |

Normative examples:

```text
validation/ado-build/samples/python/quickstart-chat
validation/hosted-agents-e2e/samples/python/hosted-agents/echo-agent
```

If GitHub status context length or a downstream display constraint forces flattening, replace `/` in `sample-path` with `--` consistently for that pipeline:

```text
validation/hosted-agents-e2e/samples--python--hosted-agents--echo-agent
```

Do not mix flattened and unflattened forms for the same pipeline. A rename or encoding change creates a new context from the gate's point of view.

### State semantics

GitHub commit status states are interpreted as follows:

| State | Gate behavior | Meaning |
|-------|---------------|---------|
| `success` | Does not block | This pipeline says this sample passed for the target SHA. |
| `failure` | Blocks this sample | The sample ran and failed validation. |
| `error` | Blocks this sample | The pipeline could not produce a trustworthy pass/fail result. Treat as unsafe. |
| `pending` | Blocks this sample | Validation is in progress or intentionally holding sync. |

The gate uses GitHub's current combined status semantics for each context: **latest write wins**. If a pipeline posts `failure` and later posts `success` to the same `sha` + `context`, the current result is `success` and does not block. If it later posts `pending`, the current result blocks.

### Reader behavior

The D3 reader (`.github/scripts/parse-validation-statuses.sh`) consumes a GitHub commit-statuses-list payload, or an equivalent JSON object with a `statuses` array, and emits the `SYNC_BLOCKED_PATHS` value consumed by sync: colon-separated repo-relative sample paths.

Reader rules:

- Ignore non-`validation/` contexts.
- Ignore malformed validation contexts that do not include all three required segments: `validation/<pipeline-id>/<sample-path>`.
- For duplicate contexts, sort by `created_at` and let the newest entry win.
- Decode flattened sample paths by replacing `--` with `/`.
- Deduplicate blocked sample paths after evaluating all contexts.
- If API pagination is used, the caller must pass an aggregate payload that includes all pages needed for the target SHA.

### `target_url`

`target_url` is required when `state` is not `success`.

It should link to the run, build, matrix job, or status page that produced the result. The goal is that a sample owner can click from the blocking status directly to evidence.

For `success`, `target_url` is still strongly recommended but not required.

### `description`

`description` is optional.

Keep it short and human-readable. GitHub displays it in constrained UI surfaces.

Avoid dumping logs into `description`; use `target_url` for evidence. Good examples: `L3 load validation passed`, `Cloud E2E failed: deploy step`, `Waiting for cloud E2E run`.

### API

Use the GitHub Statuses API:

```http
POST /repos/microsoft-foundry/foundry-samples-pr/statuses/{sha}
```

Reference: [GitHub REST API — Commit statuses](https://docs.github.com/rest/commits/statuses).

Minimal payload:

```json
{
  "state": "success",
  "context": "validation/ado-build/samples/python/quickstart-chat",
  "target_url": "https://dev.azure.com/...",
  "description": "L3 load validation passed"
}
```

## Tracked sets per pipeline

A sample is tracked by a pipeline when that pipeline reports a validation status for that sample path.

Each pipeline owns its tracked-set definition. The sync gate does not discover the pipeline's intent from YAML schemas, CODEOWNERS, or path globs. It honors the statuses that exist at sync time.

Registered tracked sets today:

| Pipeline | Tracked-set definition | Source |
|----------|------------------------|--------|
| `ado-build` | Directories under `samples/` containing `sample.yaml`. The ADO pipeline enumerates these with `find samples -name "sample.yaml" -type f` during full validation. | `.azure-pipelines/validation.yml` |
| `hosted-agents-e2e` | Directories under `samples/python/hosted-agents` and `samples/csharp/hosted-agents` containing `azure.yaml`, excluding directories that contain `.ci-skip`. | `.azure-pipelines/hosted-agents-samples-ci.yml` |

Notes:

- Unreported samples are grandfathered in v1. They sync unless some other status context reports a blocking result for their path.
- A directory does not need `sample.yaml` to be gated by a team-owned internal pipeline. `sample.yaml` is the ADO pipeline's discovery mechanism, not the only way to participate in the private bridge filter.
- A pipeline may report only the samples it actually ran. For example, PR-time runs can report changed samples only; `push: main` and scheduled runs are what keep `main` HEAD fresh.

## Pipeline registry

This registry is informational, not an enforced allow-list in v1. It documents who owns each context namespace and how to interpret it.

| pipeline-id | Owning team | Trigger | Tracked-set definition | Expected creator identity | Pipeline URL/path |
|-------------|-------------|---------|------------------------|---------------------------|-------------------|
| `ado-build` | DevX Engineering | PR to `main`; `push: main`; schedule Mon/Wed/Fri 00:00 UTC; manual with `validateAll` | Directories containing `sample.yaml` under `samples/` | GitHub App `foundry-samples-validation-bot` installed on `microsoft-foundry/foundry-samples-pr` with `commit:statuses:write`. The App authors all `validation/ado-build/*` statuses. App credentials are stored in ADO variable group `foundry-samples-validation-bot-credentials`; the pipeline mints a short-lived installation token per run. | `.azure-pipelines/validation.yml` |
| `hosted-agents-e2e` | Hosted Agents | Manual GitHub Actions run only | Directories under `samples/python/hosted-agents` and `samples/csharp/hosted-agents` containing `azure.yaml` and not containing `.ci-skip` | `github-actions[bot]`; the ADO pipeline no longer posts private sync-gate statuses | `.github/workflows/hosted-agents-cloud-e2e.yml` |

Do not reuse another team's `pipeline-id`. The `pipeline-id` is the namespace that prevents one reporter from overwriting another reporter's status.

### App operations (`ado-build`)

Identity recap:

- GitHub App: `foundry-samples-validation-bot`.
- Purpose: author `validation/ado-build/<sample-path>` commit statuses for the ADO validation pipeline.
- Credential home: ADO variable group `foundry-samples-validation-bot-credentials`.
- Required variables: `GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY`.

Current ownership state:

- The App is currently owned by Brandon's personal GitHub account, following the Microsoft convention where an IC creates the App first and transfers it later.
- Follow-up: transfer ownership to the `microsoft-foundry` org.

Credential rotation:

1. In the App settings, generate a new private key.
2. Replace `GH_APP_PRIVATE_KEY` in the ADO variable group.
3. Run the ADO validation pipeline and confirm statuses are posted.

No `GH_APP_ID` or `GH_APP_INSTALLATION_ID` change is expected for private-key rotation.

Reinstalling or adding repository access:

- Use the MS-internal `microsoft/github-operations` repo PR process to install the existing App on another repo or change repository access.
- That process handles installation of existing Apps. It does not define new GitHub Apps.

Org transfer:

- Transferring App ownership to `microsoft-foundry` is a separate MS-internal process and is not documented here.
- After transfer, verify the ADO variables still match the App ID, installation ID, and active private key before relying on the pipeline.

MS-specific gotcha:

- Org admins generally cannot create new GitHub Apps directly via `https://github.com/organizations/<org>/settings/apps/new`.
- The working convention is IC creates the App on a personal account, then transfers it to the org.
- The `microsoft/github-operations` PR path is for installing existing Apps, not creating the App definition.

## Onboarding a new pipeline

1. Pick a `pipeline-id` and document the tracked-set rule.
   - Use lowercase hyphenated text.
   - Make it stable. Renaming a pipeline-id creates new contexts and leaves old contexts behind.
   - Define which sample directories the pipeline owns in terms the team can maintain.
2. Open a PR adding a row to the registry above.
   - Include owning team, triggers, tracked-set definition, expected creator identity, and pipeline path or URL.
   - Mark unknown credential identity details as `TODO`; do not invent them.
3. Start posting statuses under the convention.
   - No repo code change is required to "register" with the v1 gate.
   - The gate honors any well-formed `validation/<pipeline-id>/<sample-path>` status on the target SHA.

## Trust model

The v1 trust model is convention-based.

Any status posted under `validation/<pipeline-id>/<sample-path>` is honored by the gate, regardless of creator identity. That is intentional for v1:

- `foundry-samples-pr` is internal-only.
- Posting a commit status requires credentials with access to this repo.
- The expected creator landscape is small: GitHub Actions and ADO/service-connection identities.
- The context convention is specific enough that accidental collisions should be rare.

The reserved upgrade path is an enforced creator allow-list in `.github/sync-config.json`, keyed by `pipeline-id` and checked by the sync gate. `docs/validation-story-decisions.md` explicitly reserves that as a v2 hardening option if creator collisions, broader contributor access, or adversarial concerns become real.

Until that exists, the registry's `Expected creator identity` column is documentation and an audit hint, not a gate.

## Operational notes

### Freshness

v1 has no max-age rule.

Whatever status is current on the target SHA at sync time is consumed. Scheduled runs provide natural refresh for drift from SDKs, platform changes, credentials, or live resources.

If a pipeline needs stronger freshness, it should schedule itself and post to current `main` HEAD. A central max-age rule is deferred.

### `ado-build` carry-over on `push:main` partial runs

The `ado-build` pipeline only runs L3 validation on the changed subset of samples on `push:main` for cost reasons, but the sync gate inspects every tracked sample on the synced SHA. To avoid silently demoting unchanged samples to "untracked" (which would grandfather them through the gate), the Report stage fans out and posts a status for every `sample.yaml` directory in the validated languages on `push:main`:

- Sample was actually validated this run → its real `success` / `failure` / `error` status (existing behavior).
- Sample was unchanged on this commit → look up the parent commit's `validation/ado-build/<sample-path>` status:
  - parent `success` → post `success` "Validation carried over from previous run on unchanged source"
  - parent `failure` → post `failure` "Sample remains failing on unchanged source from previous run"
  - parent `error` → post `error` "Sample remained errored on unchanged source from previous run"
  - parent `pending` or no parent status → post `error` "No prior decisive validation result to carry over"

Carry-over is only applied on `push:main` runs where `validateAll != true`. Scheduled / manual full-validation runs validate every sample directly.

**Known gap:** changes to `validation.yml` itself or `.azure-pipelines/scripts/**` don't invalidate carry-over. Drift is bounded by the Mon/Wed/Fri scheduled run, which re-validates everything within 2-3 days — matching the staleness budget in `docs/validation-story-decisions.md` §4.

**Rollout note:** the first `push:main` run after the carry-over change is deployed will mass-post `error` for samples whose parent SHA only validated the changed subset. Operators should run the pipeline manually with `validateAll=true` on `main` immediately after deploy to seed every sample with a fresh `success` baseline.

### Multiple statuses per sample

Multiple validation contexts for the same sample all gate independently.

Example:

```text
validation/ado-build/samples/python/hosted-agents/echo-agent = success
validation/hosted-agents-e2e/samples/python/hosted-agents/echo-agent = failure
```

Result: the sample is blocked because one validation context is failing.

This is how Level 3 and Level 4 validation compose. L4 does not replace L3 unless the owning teams intentionally stop reporting L3 for that sample.

### Public repo propagation

Validation statuses do **not** propagate to the public `foundry-samples` repo.

The sync process rewrites history during private-to-public export/import. Public commits have different SHAs after author rewriting, and GitHub commit statuses are attached to private-repo SHAs. That is by design: the gate is a private-repo concern, and public receives only the content that survived the private gate.

### Renames

A renamed sample appears as a new `sample-path` and a hole in the old one.

Treat renames like deprecations:

- Report under both old and new paths for a transition window when practical.
- Let the old status age out operationally once no sync logic or dashboard expects it.
- Avoid changing context encoding during a rename unless unavoidable.

### `pending` blocks sync

`pending` is a blocking state.

Use it deliberately:

- Set `pending` at the start of a long run if sync should wait for that pipeline.
- Skip `pending` and post only the final state if the pipeline should not hold sync while running.

Do not leave stale `pending` statuses on `main` unless blocking sync is intentional.

### Sync exclusions remain separate

`.github/sync-config.json` still owns path-based sync exclusions; see the exclusion paths defined in [`.github/sync-config.json`](../.github/sync-config.json) `exclude_pathspecs` for the authoritative list.

Validation statuses decide which otherwise-syncable sample directories are held back. They do not make excluded internal files public.

## Reference posting snippets

These snippets are intentionally minimal. Production pipelines should add retries, clear logging, and secret handling appropriate to their environment.

### GitHub Actions: `actions/github-script`

Use this pattern for pipelines that run as GitHub Actions workflows.

Required workflow permission:

```yaml
permissions:
  contents: read
  statuses: write
```

Matrix job snippet:

```yaml
- name: Publish validation status
  if: always()
  uses: actions/github-script@v7
  with:
    script: |
      const samplePath = '${{ matrix.path }}';
      const state = '${{ job.status }}' === 'success' ? 'success' : 'failure';
      const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;

      await github.rest.repos.createCommitStatus({
        owner: 'microsoft-foundry',
        repo: 'foundry-samples-pr',
        sha: context.sha,
        state,
        context: `validation/hosted-agents-e2e/${samplePath}`,
        target_url: runUrl,
        description: state === 'success' ? 'Cloud E2E passed' : 'Cloud E2E failed'
      });
```

Notes:

- `${{ secrets.GITHUB_TOKEN }}` is used automatically by `actions/github-script`.
- On `push: main` and schedule, `context.sha` is the commit being validated.
- For PRs, this posts to the PR head SHA. The sync gate consumes `main` statuses, but PR statuses are still useful for preview and review.

### Azure DevOps: `Bash@3` with `curl`

Use this pattern for `.azure-pipelines/validation.yml` after a language job has produced per-sample pass/fail files.

Credential model (decided 2026-04-29):

- **GitHub App.** A repo-installed App authors all `ado-build` statuses. Rotateable, auditable, not bound to a user, survives personnel turnover. Installation tokens are short-lived (~1 hour) and minted per pipeline run from the App ID + private key held as ADO secrets.
- PAT was considered and rejected: tied to a personal account, expires (silent fail-open in a gate is the wrong direction to fail), and dilutes audit identity.
- **Open setup work** (tracked in ADO under Feature 5015284): register the App on the org, confirm bot handle, install on `foundry-samples-pr`, store credentials as ADO pipeline variables, plumb a token-mint step before the status-posting step.

Example (assumes a preceding pipeline step has minted an installation token into `$(GitHubAppToken)`):

```yaml
- task: Bash@3
  displayName: 'Publish GitHub validation statuses'
  condition: always()
  env:
    GITHUB_TOKEN: $(GitHubAppToken) # short-lived installation token minted earlier in the pipeline
    SHA: $(Build.SourceVersion)
    BUILD_URL: $(System.CollectionUri)$(System.TeamProject)/_build/results?buildId=$(Build.BuildId)
  inputs:
    targetType: inline
    script: |
      set -euo pipefail

      post_status() {
        sample_path="$1"
        state="$2"
        description="$3"
        context="validation/ado-build/${sample_path}"

        curl --fail-with-body \
          -X POST \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          "https://api.github.com/repos/microsoft-foundry/foundry-samples-pr/statuses/${SHA}" \
          -d "$(jq -n \
            --arg state "$state" \
            --arg context "$context" \
            --arg target_url "$BUILD_URL" \
            --arg description "$description" \
            '{state: $state, context: $context, target_url: $target_url, description: $description}')"
      }

      for file in "$(Pipeline.Workspace)"/Results*/passed_*.txt; do
        [ -f "$file" ] || continue
        while IFS= read -r sample_path; do
          [ -n "$sample_path" ] || continue
          post_status "$sample_path" success "L3 load validation passed"
        done < "$file"
      done

      for file in "$(Pipeline.Workspace)"/Results*/failed_*.txt; do
        [ -f "$file" ] || continue
        while IFS= read -r sample_path; do
          [ -n "$sample_path" ] || continue
          post_status "$sample_path" failure "L3 load validation failed"
        done < "$file"
      done
```

If a language job can fail before writing a failed sample list, add a recovery step that posts `error` for the samples assigned to that job. A silent job failure creates missing reports, and missing reports are grandfathered rather than blocking in v1.

## Changelog

| Date | Change |
|------|--------|
| 2026-04-29 | Initial contract per `docs/validation-story-decisions.md`. |
| 2026-04-29 | Locked `ado-build` credential to a GitHub App; PAT path retired. |
| 2026-04-30 | Registered `foundry-samples-validation-bot` GitHub App; installation ID and credentials provisioned in ADO variable group `foundry-samples-validation-bot-credentials`. |
| 2026-04-30 | D3 reader implemented in PR #214: `.github/scripts/parse-validation-statuses.sh` now consumes statuses-list payloads and emits SYNC_BLOCKED_PATHS-compatible output. |
| 2026-04-30 | Added App operations notes for `foundry-samples-validation-bot`; retired the standalone registration runbook in favor of durable ops guidance here. |
| 2026-05-05 | D5 canary: `hosted-agents-cloud-e2e.yml` begins posting `validation/hosted-agents-e2e/<sample-path>` for `samples/python/hosted-agents/agent-framework/responses/01-basic`. First externally-owned reporter on the contract; widen pending the gate dry-run criteria in `docs/validation-story-decisions.md` §9. |
| 2026-08-25 | `hosted-agents-e2e` migrated from GitHub Actions to Azure DevOps (`.azure-pipelines/hosted-agents-samples-ci.yml`); the GitHub workflows were deleted. Context namespace, canary scope and SHA targeting are unchanged. Creator identity moves from `github-actions[bot]` to the `foundry-samples-validation-bot` App, and statuses are now posted once per sample from the Summary stage (a sample passes only if every one of its combos passed) instead of once per matrix job. |
