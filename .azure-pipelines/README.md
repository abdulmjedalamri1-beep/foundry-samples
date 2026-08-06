# Sample Validation Pipeline

*Last updated: 2026-08-03*

This directory contains the Azure DevOps pipeline configuration for validating code samples in this repository. The `validation.yml` pipeline is the repo-owned ADO validator registered as `ado-build` in [`docs/validation-results-contract.md`](../docs/validation-results-contract.md).

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
2. **Validate** - Runs language-specific L1-L3 validation jobs in parallel
3. **Report** - Summarizes results, publishes artifacts, and prepares validation output for sync gating

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

> **📖 Full spec:** For complete details on build readiness levels, sync gating, and the validation contract, see [`docs/validation-contract.md`](../docs/validation-contract.md). For the per-sample GitHub commit status contract used by sync gating, see [`docs/validation-results-contract.md`](../docs/validation-results-contract.md).

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

## See also

- [`docs/validation-contract.md`](../docs/validation-contract.md) — Build readiness levels (L1–L3), the `sample.yaml` contract, and sync-gating semantics.
- [`docs/validation-results-contract.md`](../docs/validation-results-contract.md) — Per-sample GitHub commit status contract that this pipeline produces (as the `ado-build` provider) and that the sync gate consumes.
- [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md) — How validation statuses feed the private → public sync gate.