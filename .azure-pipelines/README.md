# Sample Validation Pipeline

*Last updated: 2026-08-27*

This directory contains the Azure DevOps pipeline configuration for validating code samples in this repository. The `validation.yml` pipeline is the repo-owned ADO validator registered as `ado-build` in [`docs/validation-results-contract.md`](../docs/validation-results-contract.md).

> **Transitional private pipeline:** P6 retirement work is still open, so this ADO behavior remains operational and must not be deleted yet. Its statuses apply to private quality and an authorized bridge run only. They do not initiate publication or satisfy the public repository's required `trusted` check. Public authors should use the public [Build-readiness and Live-service validator](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md).

## Overview

The `validation.yml` pipeline automatically discovers samples by finding `sample.yaml` files under `samples/`, then validates build readiness through L1-L3 (Parse, Resolve, Load) as defined in [`docs/validation-contract.md`](../docs/validation-contract.md). It validates samples across multiple languages:
- **C#**
- **Python**
- **TypeScript/JavaScript**
- **Java**
- **Go**

As part of the validation realignment, this pipeline reports per-sample GitHub commit statuses using the context format `validation/ado-build/<sample-path>` described in [`docs/validation-results-contract.md`](../docs/validation-results-contract.md). The ADO implementation preserves `/` in `<sample-path>` (for example, `validation/ado-build/samples/python/quickstart-chat`) per the contract's normative form for `ado-build`. Status posting uses the `foundry-samples-validation-bot-credentials` variable group (`GH_APP_ID`, `GH_APP_INSTALLATION_ID`, `GH_APP_PRIVATE_KEY`) to mint a short-lived GitHub App installation token. Both token minting and status publishing are fail-loud: if credentials are missing, minting fails, or any individual status POST fails, the build fails so the next sync does not silently grandfather unvalidated samples through the gate.

For full-validation runs (`validateAll=true` or scheduled), the `ChangedSamples` artifact is populated with every `sample.yaml` directory, so the Report stage publishes a status for every tracked sample on those runs (not just a changed subset).

## When Does Validation Run?

| Trigger | Scope | Description |
|---------|-------|-------------|
| **Pull Request** | Changed samples only | Validates samples modified in the PR |
| **Push to main** | Changed samples only | Validates samples changed in the commit |
| **Scheduled (Mon/Wed/Fri)** | All samples | Full validation to catch SDK drift |
| **Manual (validateAll=true)** | All samples | On-demand full validation |

## Pipeline Stages

1. **DetectChanges** - Identifies which samples were modified by walking changed files up to the nearest `sample.yaml`, or enumerates all `sample.yaml` files for scheduled/manual full runs
2. **Validate** - Runs the private ADO language-specific L1-L3 validation jobs in parallel
3. **Report** - Summarizes results, publishes artifacts, and prepares private statuses for the retained bridge's transitional block-list

---

## Adding a New Sample

### Directory Structure

Samples follow a `samples/<language>/<area>/<feature>` structure:

```
samples/
└── <language>/           # csharp, python, java, typescript, go
    └── <area>/           # Feature area (e.g., chat, embeddings, audio)
        └── <feature>/    # Specific feature or variation
            ├── sample.yaml       # Sample configuration
            ├── <source files>    # Language-specific files
            └── ...
```

**Example:**
```
samples/
└── python/
    └── chat/
        └── streaming/
            ├── sample.yaml
            ├── requirements.txt
            └── sample.py
```

### The `sample.yaml` File

Every sample **must** have a `sample.yaml` file in its root directory. This file identifies the directory as a sample and optionally defines custom validation commands.

#### Minimal `sample.yaml`

If your sample uses standard build tools, you can use a minimal configuration:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline will use **default validation** based on the language:
- **C#**: `dotnet build *.csproj`
- **Python**: Create venv, `pip install -r requirements.txt`, syntax check with `py_compile`
- **TypeScript/JS**: `npm install`, `npm run build`
- **Java**: `mvn compile` or `gradle build`
- **Go**: `go build ./...`

#### Custom Validation Commands

For samples that need custom build, validation, or test commands, specify them in `sample.yaml`:

```yaml
name: my-sample
description: A sample with custom validation

# Optional: Custom commands (run in order if specified)
build: dotnet build -c Release
validate: dotnet format --verify-no-changes
test: dotnet test --no-build
```

| Field | Description | Required |
|-------|-------------|----------|
| `name` | Sample identifier | Recommended |
| `description` | What the sample demonstrates | Recommended |
| `build` | Build command | Optional |
| `validate` | Validation/lint command | Optional |
| `test` | Test command | Optional |

> **Full private spec:** For the transitional private ADO levels and bridge-time filter, see [`docs/validation-contract.md`](../docs/validation-contract.md). For private per-sample GitHub status posting, see [`docs/validation-results-contract.md`](../docs/validation-results-contract.md).

**Behavior:**
- If **any** of `build`, `validate`, or `test` are specified, those commands are run and default validation is skipped
- If **none** are specified, the pipeline uses default language-specific validation
- Commands run in order: `build` → `validate` → `test`
- If any command fails, the sample is marked as failed

### Example

#### Python Sample with Custom Commands

```yaml
name: chat-completion
description: Basic chat completion with Azure OpenAI

build: pip install -r requirements.txt
validate: python -m py_compile main.py
test: python -m pytest tests/ -v
```

### Python Hosted Agent dependency policy

Pull requests that add a Python service under `samples/python/hosted-agents/` or change an existing Hosted Agent runtime's dependency inputs run a separate ratchet check before sample validation. The runtime must commit a fully resolved `requirements.txt` as its portable consumer artifact. Existing legacy samples remain grandfathered during source-only and documentation-only changes.

The check is implemented by `.azure-pipelines/scripts/check-hosted-agent-python-requirements.py`. See [`samples/python/hosted-agents/DEPENDENCY_POLICY.md`](../samples/python/hosted-agents/DEPENDENCY_POLICY.md) for the policy, supported authoring tools, local commands, diagnostics, and exception process.

---

## Hosted Agents Cloud E2E (`hosted-agents-samples-ci.yml`)

`hosted-agents-samples-ci.yml` is a separate, Level 4 (Run) pipeline registered as `hosted-agents-e2e` in [`docs/validation-results-contract.md`](../docs/validation-results-contract.md). It deploys every hosted-agent sample to a real Foundry project with `azd`, invokes it, and asserts against the sample's `test-spec.yml`.

It was migrated from the GitHub Actions workflows `.github/workflows/hosted-agents-cloud-e2e.yml` + `hosted-agents-cloud-e2e-runner.yml`, which have been deleted; this pipeline is now the only hosted-agent E2E runner. The helper scripts it calls still live under `.github/scripts/` (both that directory and `.azure-pipelines/` are excluded from public sync, so the location is cosmetic).

| Stage | What it does |
|-------|--------------|
| `Discover` | Runs the hosted-agent test-spec/toolbox/session-quota unit tests, then builds the combo matrix via [`internal/tools/samples-hosted-agents-ci/discover-samples.sh`](../internal/tools/samples-hosted-agents-ci/discover-samples.sh) and publishes it as the `HostedAgentSamplesMatrix` artifact |
| `CleanupOrphanedToolboxes` | Reclaims CI toolboxes older than 24h leaked by cancelled runs |
| `CloudE2E_python` / `CloudE2E_csharp` | One matrix job per combo. The job body is written once and expanded per shard by a compile-time `${{ each shard in parameters.shards }}` loop, so each language gets its own matrix and stays under the Azure Pipelines 256-job cap |
| `Summary` | Aggregates `result.txt` from every combo and publishes the build summary plus the `sample-status` artifact |

Notes:

- **Combos.** Each sample is expanded across deploy modes (`container`, `code`) and, for toolbox samples, across every endpoint in `TOOLBOX_ENDPOINT_NCUS`. Drop a `.ci-skip` file in a sample directory to exclude it entirely, or `.code-ci-skip` to keep only the container arm.
- **Matrix payload.** Only `comboId` travels through the ADO matrix; each job hydrates the rest of its record from the `HostedAgentSamplesMatrix` artifact, because a full matrix would exceed what a single ADO variable can carry.
- **Auth.** Every `azd`/`az` step runs inside `AzureCLI@2` against `$(AZURE_SERVICE_CONNECTION)`, which replaces the OIDC login and retry logic the GitHub workflow needed.
- **Configuration.** Variable group `samples-hosted-agents-ci`. Most of these previously lived as **GitHub repo variables** (`vars.*`) and were copied into the group verbatim — the pipeline reads them directly as macros:

  | Variable | Purpose |
  |---|---|
  | `CLOUD_E2E_ENABLED` | Optional kill-switch. Set to `false` to skip the pipeline; unset or any other value runs it. Azure Pipelines can also disable the pipeline from its settings. |
  | `AZURE_SERVICE_CONNECTION` | Service connection every `azd`/`az` step authenticates through. ADO-only — there is no GitHub equivalent, so it must be maintained by hand. It has to be scoped to the same subscription as `AZURE_SUBSCRIPTION_ID`. |
  | `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP` | Target subscription / resource group. |
  | `AZURE_AI_PROJECT_ID`, `AZURE_AI_PROJECT_ENDPOINT`, `AZURE_AI_PROJECT_NAME` | Default Foundry project. |
  | `TOOLBOX_ENDPOINT_NCUS` | Toolbox fan-out list, one `label=url\|query` per line. Empty means toolbox samples are skipped. |
  | `TOOLBOX_PROJECT_ID`, `TOOLBOX_PROJECT_ENDPOINT` (+ `_WESTUS2`) | Dedicated toolbox project. |
  | `CLOUD_E2E_CODE_DEPLOY_ENABLED` | Set `false` to drop the code-deploy arm globally. |
  | `GH_PAT` | Templated into toolbox connection credentials and the Copilot SDK sample. |
  | `PLAYWRIGHT_SERVICE_ACCESS_TOKEN` | Browser Automation samples. |
  | `AZURE_AI_RAI_POLICY_ID` | Real RAI policy ARM ID for the content-safety sample. |
  | `CONTENT_SAFETY_TEST_PROMPT` | Policy-violating prompt for the guardrail block test. Unset = that test no-ops. |

  Everything else the samples need (`SKIP_PROVISION`, `AZURE_AI_ACCOUNT_NAME`, `AZURE_CONTAINER_REGISTRY_ENDPOINT`, `AZURE_OPENAI_*`, `TOOLBOX_MODEL_DEPLOYMENT_NAME`, …) is forwarded to `azd env set` by prefix, so adding it to the variable group is enough.

  If the required variables are missing the `Discover` stage **fails** rather than skipping. An earlier `eq(CLOUD_E2E_ENABLED, 'true')` stage gate meant an unset variable skipped every stage and reported the build green — a false pass on a pipeline the sync gate reads.
- **azd env passthrough.** GitHub Actions could dump every repo variable with `toJson(vars)`; Azure Pipelines has no equivalent, so the runner forwards pipeline variables to `azd env set` using a prefix allow-list (`AZURE_`, `FOUNDRY_`, `TOOLBOX_`, `MODEL_`, `OPENAI_`, …). Add a prefix in the runner template if a new variable falls outside it.
- **Status page.** The GitHub workflow also published an HTML status page to `gh-pages`; that step was not migrated. The same data is available from the `sample-status` artifact and the build summary.

---

## See also

- [`docs/validation-contract.md`](../docs/validation-contract.md) — Transitional private ADO levels, the `sample.yaml` contract, and bridge-time status filtering.
- [`docs/validation-results-contract.md`](../docs/validation-results-contract.md) — Private per-sample GitHub status contract produced by `ado-build`.
- [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md) — How an authorized bridge run consumes private validation statuses.
- [Public per-sample validation contract](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md) — Current public Build-readiness and Live-service behavior.
