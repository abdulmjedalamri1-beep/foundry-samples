# internal/tools

Test support for internal CI pipelines. Each subdirectory is consumed by a GitHub Actions workflow that exercises customer-facing samples end-to-end.

| Subdirectory | Purpose | Consumer |
|---|---|---|
| [`samples-hosted-agents/`](samples-hosted-agents/) | Required `test-spec.yml` registration, turns, assertions, and migration-only legacy payloads for samples under `samples/{python,csharp}/hosted-agents/**` | [`.github/workflows/hosted-agents-cloud-e2e.yml`](../../.github/workflows/hosted-agents-cloud-e2e.yml) |
| [`voicelive-e2e/`](voicelive-e2e/) | VoiceLive end-to-end audio smoke test (`voicelive_audio_smoke_test.py`) plus fixtures | [`.github/workflows/hosted-agents-cloud-e2e.yml`](../../.github/workflows/hosted-agents-cloud-e2e.yml) |

This directory previously also held a Caleuche-based sample-generation pipeline (`ci/`, `sample-templates/`, `sample-configs/`, `sample-template-archive/`) vendored from the [Azure-Samples/template-samples](https://github.com/Azure-Samples/template-samples) repo. That tooling was retired in favor of the in-repo validation pipeline at [`.azure-pipelines/validation.yml`](../../.azure-pipelines/validation.yml) and the GitHub Actions sync workflow at [`.github/workflows/sync-to-public.yml`](../../.github/workflows/sync-to-public.yml); the legacy subdirectories were removed.
