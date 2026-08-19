# Contributing to Foundry Samples

> **August 25: one simpler home for Foundry samples**
>
> Beginning August 25, 2026, we're moving published sample contributions to
> [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples)
> so sample authors and reviewers can collaborate in one clear, shared place.
> Until August 25, continue using the current contribution process.
> This private repository will remain available for internal work at the cutover date,
> but the sync automation that carries changes to the public repo will be disabled. We'll
> share any next steps for in-flight contributions before the change takes effect.

> **Last updated:** 2026-08-03 — added the reproducible dependency policy for Python Hosted Agent samples.

This is the **private staging repository** for Microsoft Foundry documentation samples. Changes merged here are automatically synced to the public [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) repository on a nightly basis.

All contributions — new samples, updates, bug fixes — should be submitted as pull requests to this repo.

## How this repo works

| Repository | Visibility | Purpose |
|---|---|---|
| [`foundry-samples-pr`](https://github.com/microsoft-foundry/foundry-samples-pr) (this repo) | **Private** | Staging — submit your changes here |
| [`foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) | **Public** | Published — synced nightly from this repo |

When your PR is merged into `main`:

1. CI validation runs against your sample (see [Validation](#validation) below).
2. Validation results appear in PR checks/comments — **you must pass validation before merging**.
3. On `main`, validation results are published as per-sample GitHub commit statuses.
4. A nightly GitHub Actions workflow syncs the eligible contents of this repo to the public `foundry-samples` repo. Tracked samples with failing, errored, or pending validation are held back until validation passes.
5. Your sample becomes publicly available after it passes validation and the nightly sync runs.

Some paths are excluded from sync to public; see [`.github/sync-config.json`](.github/sync-config.json) `exclude_pathspecs` for the authoritative list.

> [!IMPORTANT]
> **Microsoft contributors: set up your sync-mailmap entry before your first PR.**
> Every `@microsoft.com` commit author must have an entry in [`.github/sync-mailmap`](.github/sync-mailmap)
> or the CI precheck will block your PR. See [Sync mailmap](#sync-mailmap-required-for-all-contributors) for the
> two-minute setup. Also note: `@microsoft.com` addresses cannot appear anywhere in a commit
> message body (description text, trailers, etc.) — the precheck catches those too. See
> [Commit message bodies](#commit-message-bodies) for details.



This is a private repository. To contribute you need to (1) join the GitHub org, (2) get write access, and optionally (3) set up your team for review routing. **No central gatekeeper is required** — teams manage their own membership.

> [!NOTE]
> **Onboarding an external partner (non-org member)?** Partners cannot join the `microsoft-foundry` org and cannot be added to GitHub teams. DRIs add them as outside collaborators using JIT admin elevation — see [external-contributions.md](docs/external-contributions.md) for the process.

### 1. Join the Microsoft Foundry GitHub Organization

1. Navigate to the **microsoft-foundry** org page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry>
2. Click the **Join** button to add yourself to the organization.
3. Confirm you can view this repository: <https://github.com/microsoft-foundry/foundry-samples-pr>

### 2. Get write access

Write access comes from membership in [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) or any of its child teams. Choose whichever path fits:

| Path | When to use |
|---|---|
| **Join an existing child team** | Your group already has a team (e.g., `hosted-agents`, `agents-service`). This is the most common case. |
| **Get added to `foundry-samples-writers` directly** | You're an individual contributor, or your group doesn't need its own team. |
| **Create a new child team** | Your group is contributing a new sample area and wants to own reviews for it. |

#### Join an existing child team

1. Find your team on GitHub under [foundry-samples-writers → child teams](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers/teams), or search the [Open Source Portal teams page](https://repos.opensource.microsoft.com/orgs/microsoft-foundry/teams).
2. Ask a **Maintainer** of that team to add you. To find Maintainers, open the team page on GitHub and filter members by **Role → Maintainer**.
3. [Verify write access](#verify-write-access) below.

#### Get added to `foundry-samples-writers` directly

Ask any Maintainer of [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) to add you. This grants write access immediately without creating or joining a child team.

#### Create a new child team

> [!NOTE]
> This path is for **Microsoft org members only**. If you are onboarding an external partner who is not a `microsoft-foundry` org member, GitHub teams are not available — use the [outside collaborator path](#onboarding-an-external-partner-non-org-member) instead.

This requires temporary admin access (one-time setup per team):

1. Navigate to the **foundry-samples-pr** repo page on the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/repos/foundry-samples-pr>
2. In the right sidebar, click **Elevate to Administrator** under Just-in-time elevation.
3. Click **Open on GitHub.com** → **Settings** → **Collaborators and teams**.
4. Click **Add teams** → **Create a new team**.
5. Name the team after your group (e.g., `fabrikam-extensions`).
6. Set **`foundry-samples-writers`** as the parent team. This gives your team inherited write permissions.
7. Add your teammates and **promote at least two people to Maintainer** (see [Managing your team](#managing-your-team)).
8. Add a [CODEOWNERS entry](#set-up-codeowners-for-your-sample-area) for your sample paths so PRs route to your team automatically.

> [!NOTE]
> Team members must have already joined the `microsoft-foundry` org ([step 1](#1-join-the-microsoft-foundry-github-organization)) before they can be added to a team. You can check enrollment at <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/people?q=> using a GitHub or Microsoft alias.

> [!TIP]
> **Can't find a Maintainer, or no one responds?** Any org member can use JIT admin elevation (described above in "Create a new child team") to temporarily gain admin access and add themselves.

#### Verify write access

After joining a team, confirm you can push a branch:

```shell
git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
cd foundry-samples-pr
git checkout -b test/your-name-access-check
git push origin test/your-name-access-check
git push origin --delete test/your-name-access-check
```

## Owning your samples

Multiple teams contribute samples to this repo. Each team should own their sample paths via [CODEOWNERS](https://docs.github.com/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners) for two reasons: (1) PRs that touch your paths automatically request your team for review, and (2) issues filed against your paths are routed to your team for triage.

### Set up CODEOWNERS for your sample area

When your team owns a sample area (e.g., `samples/*/hosted-agents/`), add an entry to [`.github/CODEOWNERS`](.github/CODEOWNERS) so your team is automatically requested for review on PRs that touch those paths.

The pattern to follow is:

```
/samples/<language>/<area>/  @microsoft-foundry/<team-slug>
```

For example, if your team `hosted-agents` owns the hosted-agents samples across all languages:

```
/samples/python/hosted-agents/  @microsoft-foundry/hosted-agents
/samples/csharp/hosted-agents/  @microsoft-foundry/hosted-agents
```

To add your entry, open a PR that edits `.github/CODEOWNERS` — add your lines **above** the AI Platform Docs section (marked with a comment).

> [!IMPORTANT]
> CODEOWNERS controls **reviewer routing and issues triage** — it does not grant write access, and code-owner approval is **not required to merge**. The merge gate is CI/validation checks passing. If you want to block a PR that touches your paths, use **Request Changes** on the PR explicitly. Access is controlled through team membership as described in [Getting access](#getting-access).

### Managing your team

Each team is responsible for its own membership. There is no central approval process — **team Maintainers are the owners**.

**Adding members:** Go to your [team page on GitHub](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers/teams), click **Add a member**, and search for the person's GitHub username. New members must have already [joined the org](#1-join-the-microsoft-foundry-github-organization).

**Promoting Maintainers:** On the team page, click the **Role** dropdown next to a member's name and select **Maintainer**. Maintainers can add/remove members and promote other Maintainers.

> [!IMPORTANT]
> **Every team should have at least two Maintainers.** If a team has only one Maintainer and they leave, the team becomes orphaned and no one can manage membership. If you find yourself in this situation, use [JIT admin elevation](#create-a-new-child-team) to regain access.

## Submitting a pull request

### Before you start

1. Search the [open pull requests](https://github.com/microsoft-foundry/foundry-samples-pr/pulls) to make sure your change isn't already in progress.
2. Confirm this is the right repo for your contribution:
   - **In scope:** Sample code, notebooks, and supporting files that demonstrate Microsoft Foundry scenarios.
   - **Out of scope:** Long-form documentation (use the [azure-docs repository](https://github.com/MicrosoftDocs/azure-docs) instead).

### Set up your environment

1. **Clone the repo** (this repo uses feature branches, not forks):

   ```shell
   git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
   cd foundry-samples-pr
   ```

2. **Install dev dependencies** (for Python contributors):

   ```shell
   python -m pip install -r dev-requirements.txt
   ```

3. **Set up pre-commit** to catch formatting and lint issues locally:

   ```shell
   pre-commit install
   ```

   This runs [black](https://github.com/psf/black), [ruff](https://github.com/astral-sh/ruff), and [nb-clean](https://github.com/srstevenson/nb-clean) automatically on each commit. You can also run it manually:

   ```shell
   pre-commit run --all-files
   ```

### Make your changes

1. Create a feature branch:

   ```shell
   git checkout -b your-name/short-description
   ```

2. Add or update your sample. Samples follow the directory structure `samples/<language>/<area>/<feature>/`. Use `sample.yaml` for the central ADO validation path, or coordinate with your owning team to ensure a team-owned pipeline posts validation statuses. See the [Validation Pipeline README](.azure-pipelines/README.md) for the full spec on directory layout and `sample.yaml` format.

3. Include a descriptive `README.md` in your sample directory.

4. For a new Python Hosted Agent sample, or when changing dependency inputs under `samples/python/hosted-agents/`, commit a fully resolved `requirements.txt` for each affected runtime project. Authors may use any locking tool, but `requirements.txt` is the portable consumer artifact. Follow the [Python Hosted Agent dependency policy](samples/python/hosted-agents/DEPENDENCY_POLICY.md) and run its local checker before submitting the PR.

### Submit your PR

1. Push your branch and open a pull request against `main`:

   ```shell
   git push origin your-name/short-description
   ```

2. Fill out the PR description and complete any checklist items.
3. Respond to reviewer feedback and resolve any failing CI checks.

> [!IMPORTANT]
> If your contribution is time-sensitive, plan accordingly — PRs require passing CI/validation checks before merge, and the public sync runs nightly. Code owners are auto-requested for review but their approval does not block the merge.

### Partner and external contributions

Partner and external contributions follow the same PR, validation, and sync flow with a named Microsoft DRI. If a partner sample fails validation and needs a partner-owned fix, the DRI starts the 4 business day SLA: if there is no response or fix by Day 4, DevX removes the sample from synced paths until it can be reinstated by PR. See [`docs/external-contributions.md`](docs/external-contributions.md) for the full escalation model.

## Validation

Validation results **gate the nightly sync to public**. A tracked sample is not eligible for `foundry-samples` while any validation status for that sample is `failure`, `error`, or `pending` on the private `main` commit being synced.

There are two supported validation paths:

| Path | How it opts in | Who owns it |
|------|----------------|-------------|
| **Central ADO pipeline** | Add `sample.yaml`; the ADO build posts `validation/ado-build/<sample-path>` statuses | DevX Engineering |
| **Team-owned pipeline** | The owning team posts `validation/<pipeline-id>/<sample-path>` statuses (Hosted Agents is the reference model) | Feature or partner team |

### How it works

1. The central pipeline discovers sample directories by looking for `sample.yaml` files; team-owned pipelines define their own tracked set.
2. For each tracked sample, the owning pipeline runs its build, validate, or service-specific checks.
3. The pipeline posts a GitHub commit status to the validated SHA using the `validation/<pipeline-id>/<sample-path>` context.
4. The nightly sync workflow reads validation statuses on the private `main` commit being synced. `success` allows that sample to sync; `failure`, `error`, or `pending` holds that sample back.

### Build readiness levels

Validation measures **build readiness** — whether your code can be built and loaded by a customer who copies it. Levels are cumulative:

| Level | Name | What it checks | Example |
|-------|------|----------------|---------|
| 1 | **Parse** | Does the code parse? | `python -m py_compile sample.py` |
| 2 | **Resolve** | Do dependencies install? | `pip install -r requirements.txt` |
| 3 | **Load** | Does the code load without error? | `python -c "import sample"` |
| 4 | **Run** | Does the sample run against live resources or deployed infrastructure? | Provision, deploy, and exercise the sample end-to-end |

**The sync threshold for tracked samples is level 3 (load).** Your sample must demonstrate that its code loads with all dependencies resolved. Team-owned pipelines may add level 4 validation; if any reporting validation pipeline posts `failure`, `error`, or `pending`, that sample does not sync.

### What you need to provide

For the central ADO validation path, each sample directory must contain a **`sample.yaml`** file. A minimal config is:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline applies default validation per language (e.g., `dotnet build` for C#, `pip install && py_compile` for Python). You can override with custom `build`, `validate`, and `test` commands in `sample.yaml`.

If your team brings its own validation pipeline instead, it must post per-sample GitHub commit statuses using the validation context convention above; reporting under `validation/<pipeline-id>/<sample-path>` is the act of opting into sync gating for that sample. For the full `sample.yaml` schema, directory structure, and per-language defaults, see the [Validation Pipeline README](.azure-pipelines/README.md). For the complete validation contract — including build readiness levels, sync gating rules, and team-owned pipeline onboarding — see [`docs/validation-contract.md`](docs/validation-contract.md) and [`docs/validation-results-contract.md`](docs/validation-results-contract.md).

#### Reference validate commands

For samples that specify a custom `validate` command, these are the recommended patterns by language:

| Language | `build` | `validate` | What it proves |
|----------|---------|------------|----------------|
| Python | `pip install -r requirements.txt` | `python -c "import sample"` | Deps resolve, code loads |
| C# | `dotnet restore` | `dotnet build` | Compilation proves load |
| Java | `mvn dependency:resolve` | `mvn compile` | Compilation proves load |
| Go | `go mod download` | `go build ./...` | Compilation proves load |
| TypeScript | `npm install` | `npx tsc --noEmit` | Type-checks all imports |
| JavaScript | `npm install` | `node -e "require('./sample')"` | Deps resolve, code loads |

### What happens when…

| Scenario | Effect on sync | Effect on PRs |
|----------|---------------|---------------|
| ✅ Validation passes | Sample syncs to public (nightly) | PR checks pass |
| ❌ Validation fails | Tracked sample is held back until validation passes | PR checks fail — must fix before merging |
| ⚠️ No `sample.yaml` and no team-owned status | Sample is untracked in v1 and syncs ungated | No central validation runs for this directory |
| ⚠️ No `sample.yaml`, but team-owned status exists | Status gates sync for that sample | Team-owned status/check must pass |

> [!IMPORTANT]
> If your sample directory does not contain a `sample.yaml` file, it will not be validated by the central ADO pipeline. Adding `sample.yaml` is the default way to enable CI to catch breakage before it reaches customers. If your team uses its own validation pipeline, make sure it posts per-sample statuses so sync can honor those results.

## Sync mailmap (required for all contributors)

This repository syncs to a **public** GitHub repo nightly. To protect internal email addresses, every `@microsoft.com` commit author must have an entry in [`.github/sync-mailmap`](.github/sync-mailmap) that maps their internal email to a GitHub noreply address.

### Why this is needed

When your commits sync to the public repo, the author/committer email goes with them. Without a mailmap entry, the sync fails — your internal email would be exposed publicly, or the pipeline blocks entirely.

### How you'll know

If your email isn't mapped, you'll see a CI failure on your PR:

```
❌ Found 1 unmapped internal email(s):
  • yourname@microsoft.com
    Lookup: https://repos.opensource.microsoft.com/people?q=yourname
```

### How to fix it

1. **Find your GitHub noreply email.** Go to [github.com/settings/emails](https://github.com/settings/emails). Under "Keep my email addresses private", you'll see your noreply address in the format:
   ```
   12345678+yourusername@users.noreply.github.com
   ```

2. **Add yourself to `.github/sync-mailmap`.** Add a line in this format:
   ```
   Your Display Name <12345678+yourusername@users.noreply.github.com> <yourmsalias@microsoft.com>
   ```

3. **Commit the change** as part of your PR (or as a separate PR if you prefer).

> [!TIP]
> If you're unsure about your GitHub username, look yourself up at [repos.opensource.microsoft.com/people](https://repos.opensource.microsoft.com/people?q=) using your Microsoft alias.

> [!NOTE]
> If the self-healing workflow has already opened a PR with a suggested mapping for you, you can simply verify and approve that PR instead of adding the entry manually.

### Commit message bodies

The precheck also scans the **full text of every commit message body** — description text, `Co-authored-by:` lines, `Signed-off-by:` lines, and any other content. Any `@microsoft.com` address anywhere in the message body fails the check. The sync pipeline only rewrites author/committer identity fields; message text passes through verbatim to the public repo.

**In commit description text:** rephrase to avoid the internal address. Reference people by name, GitHub alias, or PR number instead.

**In a `Co-authored-by:` or `Signed-off-by:` trailer:** replace the `@microsoft.com` address with the GitHub noreply address from `.github/sync-mailmap`:

```
Co-authored-by: Their Name <12345678+alias@users.noreply.github.com>
```

If you need to amend an already-pushed commit:

```shell
git commit --amend    # most recent commit only
# or
git rebase -i <base>  # mark each affected commit as 'reword' or 'edit'
git push --force-with-lease
```

## Fixing pre-commit failures

If pre-commit checks fail on your PR:

| Check | Fix |
|---|---|
| **black** | `pre-commit run black --all-files` and commit the changes |
| **ruff** | `pre-commit run ruff --all-files` and commit. For issues ruff can't auto-fix, see the [ruff rule list](https://docs.astral.sh/ruff/rules/). |
| **nb-clean** | `pre-commit run nb-clean --all-files` and commit the changes |

> [!TIP]
> To avoid exposing secrets in committed code, use empty string placeholders:
> ```python
> os.environ["AZURE_SUBSCRIPTION_ID"] = ""
> ```

## Discoverability

Samples can be indexed in the [Microsoft code samples browser](https://learn.microsoft.com/samples). To enable this, add YAML frontmatter to your sample's `README.md`:

```yaml
---
page_type: sample
languages:
- python
products:
- ai-services
description: Brief description of the sample.
---
```

See the [product taxonomy](https://review.learn.microsoft.com/en-us/help/platform/metadata-taxonomies?branch=main#product) and [language taxonomy](https://review.learn.microsoft.com/en-us/help/platform/metadata-taxonomies?branch=main#dev-lang) for valid values.

## Further reading

For detailed governance documentation, see the [`docs/`](docs/) directory:

- [Validation Contract](docs/validation-contract.md) — Full spec for build readiness levels and the `sample.yaml` schema
- [Repo Sync Automation](docs/repo-sync-automation.md) — How the nightly sync to public works
- [External Contributions](docs/external-contributions.md) — Partner contribution model and SLAs

## Contributor License Agreement

This project requires a Contributor License Agreement (CLA). When you submit a pull request, a CLA bot will check whether you need to sign one and guide you through the process. You only need to do this once across all Microsoft repos. For details, visit https://cla.opensource.microsoft.com.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com).

