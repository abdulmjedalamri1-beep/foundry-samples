# Internal Directory

This directory contains internal-only test support and tooling for the **private** `foundry-samples-pr` repository. Nothing under `internal/` is ever synced to the public `foundry-samples` repository.

## Purpose

`internal/` holds test fixtures, payloads, and test suites that exercise samples in the validation and CI pipelines. None of these should ship to customers.

- **Playwright E2E suite** that validates hosted-agent samples deploy via the AI Foundry VS Code extension (`playwright-tests/`)
- **Hosted-agent test specs and legacy payloads** consumed by the cloud E2E pipeline (`tools/samples-hosted-agents/`)
- **VoiceLive audio smoke test** consumed by the cloud E2E pipeline (`tools/voicelive-e2e/`)

## Sync Behavior

The sync flow is **private → public**, not the other way around. `foundry-samples-pr` is the upstream authoritative repo where authors push, validation runs, and internal content lives. `foundry-samples` is the downstream public repo that customers read.

```text
foundry-samples-pr (private)  ──── daily + on-merge sync ────►  foundry-samples (public)
```

- **Daily sync** runs at 06:00 UTC via `.github/workflows/sync-to-public.yml` and uses `git fast-export` / `git fast-import` to push private `main` to public `main`, with path filtering and author rewriting.
- **Mirror-back** is the inverse direction and is **not** a bulk content sync: `.github/workflows/mirror-back.yml` opens a per-commit review PR back to private whenever a non-sync-App commit lands directly on public `main`. This is a backstop for hand-edits made directly in the public repo, not the primary sync direction.
- **`internal/` is statically excluded** from the private → public sync. Anything under this directory is guaranteed to stay private.

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

Static path exclusions and the public-repo target are defined in [`.github/sync-config.json`](../.github/sync-config.json). The exclusion list is the `exclude_pathspecs` array (note: `pathspecs`, plural, and these are git pathspecs starting with `:!`, not plain path strings). To exclude an additional path from the public sync, add a `":!<path>/"` entry to that array.

The set excluded today: `internal/`, `docs/`, `.azure-pipelines/`, `.github/`, `CONTRIBUTING.md`, `README.md`, `public-overlay/`.

> **Do not** put temporary validation holds in `exclude_pathspecs`. The sync gate computes per-run dynamic exclusions for samples that fail or are pending validation — see [`docs/validation-contract.md`](../docs/validation-contract.md) and [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md).

## Sync Workflow Secrets

The private → public sync runs as a GitHub App (`foundry-samples-repo-sync`) installed on both repos. Two repository secrets back it:

| Secret | Description |
|--------|-------------|
| `SYNC_APP_ID` | GitHub App ID |
| `SYNC_APP_PRIVATE_KEY` | App private key (PEM) |

App permissions: Contents (Read & Write), Pull Requests (Read & Write), Statuses (Read), Issues (Write — for bypass-log comments).

## Manual Sync Triggers

`.github/workflows/sync-to-public.yml` supports manual dispatch from the Actions tab with inputs for dry-run, full re-export, marks-cache reseeding, and per-sample / full validation-gate bypass. See the workflow file for the complete input list and [`docs/repo-sync-automation.md`](../docs/repo-sync-automation.md) for when each is appropriate.

---

## Guidelines

### What Belongs Here

- ✅ Internal E2E and smoke test suites
- ✅ Test fixtures and payloads consumed by CI workflows
- ✅ Experimental tooling that should not ship publicly

### What Does NOT Belong Here

- ❌ Customer-facing samples (those go in `samples/`, `samples-classic/`, `samples-mistral/`)
- ❌ Public documentation (`README.md`, `CONTRIBUTING.md`, anything under `docs/`)
- ❌ Symlinks or imports from `internal/` into public content — they would break after sync
