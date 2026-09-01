# internal/tools

Test support for internal CI pipelines. Each subdirectory is consumed by a pipeline that exercises customer-facing samples end-to-end.

| Subdirectory | Purpose | Consumer |
|---|---|---|
| [`samples-hosted-agents/`](samples-hosted-agents/) | Required `test-spec.yml` registration, turns, assertions, and migration-only legacy payloads for samples under `samples/{python,csharp}/hosted-agents/**` | [`.azure-pipelines/hosted-agents-samples-ci.yml`](../../.azure-pipelines/hosted-agents-samples-ci.yml) |
| [`samples-hosted-agents-ci/`](samples-hosted-agents-ci/) | `discover-samples.sh` — builds the hosted-agent cloud-E2E matrix (sample x toolbox x deploy-mode) | [`.azure-pipelines/hosted-agents-samples-ci.yml`](../../.azure-pipelines/hosted-agents-samples-ci.yml) |
| [`voicelive-e2e/`](voicelive-e2e/) | VoiceLive end-to-end audio smoke test (`voicelive_audio_smoke_test.py`) plus fixtures | [`.azure-pipelines/hosted-agents-samples-ci.yml`](../../.azure-pipelines/hosted-agents-samples-ci.yml) |

This directory previously also held a Caleuche-based sample-generation pipeline (`ci/`, `sample-templates/`, `sample-configs/`, `sample-template-archive/`) vendored from the [Azure-Samples/template-samples](https://github.com/Azure-Samples/template-samples) repo. That tooling was retired in favor of the in-repo validation pipeline at [`.azure-pipelines/validation.yml`](../../.azure-pipelines/validation.yml) and the GitHub Actions sync workflow at [`.github/workflows/sync-to-public.yml`](../../.github/workflows/sync-to-public.yml); the legacy subdirectories were removed.
