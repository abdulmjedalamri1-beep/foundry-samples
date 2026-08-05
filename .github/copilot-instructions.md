## Files owned by the AI Platform Docs team

If a file is listed in the CODEOWNERS file with @azure-ai-foundry/ai-platform-docs as the owner, it is owned by the AI Platform Docs team.  For these files:

- Do not change the filename or move the file.
- Do not remove any comments which contain <some_text> or </some_text> (for any text in between the tags)
- Do not remove any cell in a notebook if it contains metadata with "name:" in it.

In a code review, if any of the above rules are broken, please add the following text to your review:
🛑STOP! This PR contains changes that may break documentation.  Please post a message on [ai-platform-docs](https://teams.microsoft.com/l/team/19%3AHhf4F_YfPn3kYGdmWvePNwlbF5-RR8wciQEUwwrcggw1%40thread.tacv2/conversations?groupId=fdaf4412-8993-4ea6-a7d4-aeaded7fc854&tenantId=72f988bf-86f1-41af-91ab-2d7cd011db47) to request help.

Only files owned by the AI Platform Docs team are subject to these rules. 

## Repository governance

This repo has detailed governance documentation in `docs/`:

- `docs/validation-story-decisions.md` — Locked validation direction. For validation-related work, this wins if docs appear to disagree.
- `docs/validation-contract.md` — Validation behavior, `sample.yaml` contract, build readiness levels, and sync-gating semantics.
- `docs/validation-results-contract.md` — How ADO, GitHub Actions, and external pipelines post per-sample GitHub commit statuses that participate in sync gating.
- `docs/validation-reporting-decisions.md` — Decisions on how `validation-health-refresh.yml` and related reporters keep `main`-HEAD statuses current.
- `docs/repo-sync-automation.md` — How private-to-public sync works, including static exclusions, dynamic validation exclusions, fast-export/import, author rewriting, and PR automation.
- `docs/sync-cutover-runbook.md` — One-time pipeline-replacement / authorship-rewrite surgery procedure. For ordinary sync-incident recovery (orphan-wipe, marks reseed, guard failures), see the [Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) in `foundry-devx-eng-docs`.
- `docs/external-contributions.md` — Partner contribution model, validation paths, 4 business day SLA, and escalation path.

When answering questions about validation, sync behavior, or the contribution process, reference these docs rather than guessing.

## Validation and sync direction

Validation gates public sync. The sync gate is a per-sample block-list driven by GitHub commit statuses on the private `main` commit being synced. Status contexts use `validation/<pipeline-id>/<sample-path>`; `failure`, `error`, or `pending` blocks that sample, while `success` does not. Samples with no reporting pipeline are untracked/grandfathered and sync ungated in v1.

## Sample structure

Samples generally live under `samples/<language>/<area>/<feature>/`. Add `sample.yaml` when using the central ADO validation pipeline; it discovers directories under `samples/` that contain `sample.yaml` and validates them to Level 3 (Load). External/team-owned pipelines may track samples through their own manifests and must report statuses per `docs/validation-results-contract.md`.

For every new Python or C# hosted-agent sample, read and follow [`internal/tools/samples-hosted-agents/README.md`](../internal/tools/samples-hosted-agents/README.md). A new hosted-agent sample must register a responsible Microsoft owner and add deterministic turns/assertions in `test-spec.yml`; legacy payloads and generated defaults are migration-only.

## Sync exclusions

The exclusion list lives in `.github/sync-config.json` under `exclude_pathspecs`; consult it for the authoritative set of internal-only paths excluded from sync to public. Do not put temporary validation holds in that file; the sync gate creates dynamic per-run exclusions for blocked samples.

## Public-overlay and protected paths

Two additional sync mechanisms live in `.github/sync-config.json` alongside `exclude_pathspecs`:

- **`public-overlay/`** — Content under this directory ships to the public repo on every sync via `apply_public_overlay`. Use it for files that should exist on public but should not be authored in the synced tree (e.g., public-only `README.md`, `CONTRIBUTING.md`, mirror-back workflow source). The directory itself is *excluded* from the normal sync stream and re-applied as an overlay, so editing a file under `public-overlay/` is how you change the corresponding file on public main. **Public workflow files do NOT belong here** — see `docs/repo-sync-automation.md` § "Public→private mirror-back" for context.
- **`protected_paths`** — A guard list of paths that exist on public main but are *not* in private's include-set or `public-overlay/`. `sync-core.sh` simulates the prospective rebase-merge tree and hard-fails the sync if any listed path would be deleted or modified. Today's list covers `mirror-back.yml` and `run-setup.yml`. See `docs/repo-sync-automation.md` § "Protected-paths guard" for the mechanism and recovery procedure.

When a sync incident touches either mechanism, the canonical recovery playbook is the [Sync Recovery Runbook](https://msdata.visualstudio.com/Vienna/_git/foundry-devx-eng-docs?path=/operations/sync-recovery-runbook.md) in `foundry-devx-eng-docs`.

## Sync incident response

When a user pastes a failing `sync-to-public` run URL (e.g., `https://github.com/microsoft-foundry/foundry-samples-pr/actions/runs/<id>`) or says a sync run has failed, **read `.github/skills/sync-incident-response.md` before taking any other action.** That file is the authoritative diagnostic and recovery playbook: how to get logs, identify the failure type, confirm root cause, and choose the right recovery option. Do not guess or improvise — follow the playbook.
