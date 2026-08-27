# Internal Directory

This directory contains internal-only test support and tooling for the **private** `foundry-samples-pr` repository. It is outside the bridge's default positive scope and must not be supplied through `additional_paths`.

## Purpose

`internal/` holds test fixtures, payloads, and test suites that exercise samples in the validation and CI pipelines. None of these should ship to customers.

- **Playwright E2E suite** that validates hosted-agent samples deploy via the AI Foundry VS Code extension (`playwright-tests/`)
- **Hosted-agent test specs and legacy payloads** consumed by the cloud E2E pipeline (`tools/samples-hosted-agents/`)
- **VoiceLive audio smoke test** consumed by the cloud E2E pipeline (`tools/voicelive-e2e/`)

## Bridge Behavior

The public `foundry-samples` repository is the normal route for publication. This private repository remains authoritative only for internal work. A private merge does not publish.

```text
foundry-samples-pr (private)  ── authorized manual bridge ──►  public pull request
```

- The retained bridge runs only through an explicitly authorized `workflow_dispatch`.
- Its default positive scope is `infrastructure/**` and `samples/**`; `internal/**` is outside that scope.
- A valid one-run `additional_paths` value can authorize a specific non-reserved file or directory, including under a normally private tree. Do not treat path location alone as a security boundary.
- The bridge opens a public pull request, waits for public rules, repeats its scope guard, and rebase-merges as the ruleset-bound App.

For the full mechanics — sync gate, validation status interpretation, fast-export filtering, author rewriting, App-authenticated PR creation, wait-and-merge, drift verification — see [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md).

## Directory Structure

```
internal/
├── playwright-tests/       # E2E Playwright suite: validates hosted-agent samples deploy via the AI Foundry VS Code extension
└── tools/
    ├── samples-hosted-agents/    # Test specs and legacy payloads for hosted-agent cloud E2E
    └── voicelive-e2e/      # VoiceLive end-to-end audio smoke test
```

Re-run `git ls-tree --name-only HEAD internal/` to refresh this listing if it falls behind.

## Sync Configuration

The durable default positive scope and public-repository target are defined in [`.github/sync-config.json`](../.github/sync-config.json). Do not use legacy `exclude_pathspecs` as publication policy. Reserved public metadata (`README.md`, `CONTRIBUTING.md`, `.github/**`, and `public-overlay/**`) cannot be authorized through `additional_paths`.

## Sync Workflow Secrets

The private → public sync runs as a GitHub App (`foundry-samples-repo-sync`) installed on both repos. Two repository secrets back it:

| Secret | Description |
|--------|-------------|
| `SYNC_APP_ID` | GitHub App ID |
| `SYNC_APP_PRIVATE_KEY` | App private key (PEM) |

The public-scoped App token needs contents and pull-request write access. Private workflow permissions provide status read and bypass-log issue comments. The App is not a public `main` ruleset bypass actor.

## Manual Sync Triggers

`.github/workflows/sync-to-public.yml` supports authorized manual dispatch with `dry_run`, `additional_paths`, verified seed-recovery inputs, and validation override inputs. It has no full re-export or direct-public-main mode. Always start recovery with `dry_run=true`; see [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md).

---

## Guidelines

### What Belongs Here

- ✅ Internal E2E and smoke test suites
- ✅ Test fixtures and payloads consumed by CI workflows
- ✅ Experimental tooling that should not ship publicly

### What Does NOT Belong Here

- ❌ Customer-facing samples (author those in public `microsoft-foundry/foundry-samples`)
- ❌ Public documentation (maintain it through a normal public pull request)
- ❌ Symlinks or imports from `internal/` into public content — they would break after sync
