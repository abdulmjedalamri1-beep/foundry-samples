## Repository purpose and publication routing

- This private repository is internal-first and remains available for internal work.
- Work intended for publication belongs by default in a normal pull request in [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) under its [contribution policy](https://github.com/microsoft-foundry/foundry-samples/blob/main/CONTRIBUTING.md).
- Merging a change in this private repository does not automatically publish it.
- An operator-only retained bridge exists for authorized maintainers handling approved internal content. It is not a contributor publication route.
- Agents must not dispatch the retained bridge or initiate verified seed recovery without explicit authorization from an operator for that action.
- If private work should be published without an authorized bridge operation, its owner must manually recreate or port it into a public pull request.
- If a contributor lacks public branch access, surface that blocker and direct them to a repository owner. Do not invent an alternate publication route.
- Do not add pre-cutover notices to pull-request bodies.

Do not tell contributors that editing this private repository, `public-overlay/`, sync configuration, or publication machinery will publish changes. Do not invent or propose private merge policies, staging taxonomies, classifiers, manifests, staging roots, promotion commands or environments, formal handoff or immutable-SHA protocols, exception sync, reverse mirrors, replay, `force_full`, marks repair, unverified reseeding, or other retired destructive publication and recovery mechanisms.

## Files owned by the AI Platform Docs team

If a file is listed in the CODEOWNERS file with @azure-ai-foundry/ai-platform-docs as the owner, it is owned by the AI Platform Docs team.  For these files:

- Do not change the filename or move the file.
- Do not remove any comments which contain <some_text> or </some_text> (for any text in between the tags)
- Do not remove any cell in a notebook if it contains metadata with "name:" in it.

In a code review, if any of the above rules are broken, please add the following text to your review:
🛑STOP! This PR contains changes that may break documentation.  Please post a message on [ai-platform-docs](https://teams.microsoft.com/l/team/19%3AHhf4F_YfPn3kYGdmWvePNwlbF5-RR8wciQEUwwrcggw1%40thread.tacv2/conversations?groupId=fdaf4412-8993-4ea6-a7d4-aeaded7fc854&tenantId=72f988bf-86f1-41af-91ab-2d7cd011db47) to request help.

Only files owned by the AI Platform Docs team are subject to these rules. 

## Repository governance

Use the following documents for enduring validation and sample-quality guidance:

- `docs/validation-story-decisions.md` — Locked validation direction. For validation-related work, this wins if docs appear to disagree.
- `docs/validation-contract.md` — Transitional private ADO validation behavior, the private `sample.yaml` contract, and bridge-time status interpretation.

Legacy sync documentation, workflows, configuration, `public-overlay/`, and recovery runbooks may remain in the repository as historical or incident evidence; do not use them as contributor publication guidance. The retained bridge and its current operator runbook are not retired, but agents may operate the bridge or initiate verified seed recovery only with explicit operator authorization.

## Sample structure

Samples generally live under `samples/<language>/<area>/<feature>/`. Add `sample.yaml` when using the central private ADO validation pipeline; it discovers directories under `samples/` that contain `sample.yaml` and validates them through its transitional Level 3 (Load) contract. This private status does not satisfy or replace the public repository's required `trusted` check. For public work, follow the public [per-sample Build-readiness and Live-service contract](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md).

For every new Python or C# hosted-agent sample, read and follow [`internal/tools/samples-hosted-agents/README.md`](../internal/tools/samples-hosted-agents/README.md). A new hosted-agent sample must register a responsible Microsoft owner and add deterministic turns/assertions in `test-spec.yml`; legacy payloads and generated defaults are migration-only.
