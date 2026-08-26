# Contributing to Foundry Samples

> **Last updated:** 2026-08-25 — aligned private routing with the public-default contribution model.

> [!IMPORTANT]
> This private repository is for internal work that is not intended for publication. Publication work belongs in the public [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) repository.
>
> Merging a change here does not automatically publish it. Authorized maintainers retain a manual, operator-only bridge for an explicitly approved private-main publication batch. The bridge opens a public pull request and merges it only after required public checks pass and repository rules permit the merge. Contributors must not invoke the bridge or treat it as an alternative publication route.

Use this repository for internal sample work, supporting files, and tooling that must remain private. To contribute, join the GitHub organization, get write access, and optionally set up your team for review routing. Teams manage their own membership; no central gatekeeper is required.

## Getting access

### 1. Join the Microsoft Foundry GitHub organization

1. Open the **microsoft-foundry** organization in the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry>
2. Select **Join**.
3. Confirm that you can view this repository: <https://github.com/microsoft-foundry/foundry-samples-pr>

### 2. Get write access

Write access comes from membership in [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) or one of its child teams.

| Path | When to use |
|---|---|
| **Join an existing child team** | Your group already has a team, such as `hosted-agents` or `agents-service`. |
| **Join `foundry-samples-writers` directly** | You are an individual contributor, or your group does not need a team. |
| **Create a child team** | Your group owns an internal sample area and wants review routing for it. |

#### Join an existing child team

1. Find your team under [foundry-samples-writers child teams](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers/teams), or search the [Open Source Portal teams page](https://repos.opensource.microsoft.com/orgs/microsoft-foundry/teams).
2. Ask a team Maintainer to add you.
3. [Verify write access](#verify-write-access).

#### Join `foundry-samples-writers` directly

Ask a Maintainer of [`foundry-samples-writers`](https://github.com/orgs/microsoft-foundry/teams/foundry-samples-writers) to add you.

#### Create a child team

This requires temporary administrator access:

1. Open this repository in the Open Source Management Portal:
   <https://repos.opensource.microsoft.com/orgs/microsoft-foundry/repos/foundry-samples-pr>
2. Select **Elevate to Administrator**.
3. Open the repository on GitHub and go to **Settings** > **Collaborators and teams**.
4. Select **Add teams** > **Create a new team**.
5. Name the team after your group.
6. Set `foundry-samples-writers` as the parent team.
7. Add team members and promote at least two people to Maintainer.
8. Add a [CODEOWNERS entry](#set-up-codeowners-for-your-internal-area).

Team members must join the `microsoft-foundry` organization before they can be added to a team.

#### Verify write access

After joining a team, confirm that you can push a branch:

```shell
git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
cd foundry-samples-pr
git checkout -b test/your-name-access-check
git push origin test/your-name-access-check
git push origin --delete test/your-name-access-check
```

## Owning internal paths

Teams should own their internal paths through [CODEOWNERS](https://docs.github.com/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners). Ownership routes pull requests for review and issues for triage.

### Set up CODEOWNERS for your internal area

Add an entry to [`.github/CODEOWNERS`](.github/CODEOWNERS) for the paths your team owns:

```text
/samples/<language>/<area>/  @microsoft-foundry/<team-slug>
```

For example:

```text
/samples/python/hosted-agents/  @microsoft-foundry/hosted-agents
/samples/csharp/hosted-agents/  @microsoft-foundry/hosted-agents
```

Add team-owned entries above the AI Platform Docs section in `.github/CODEOWNERS`.

CODEOWNERS controls reviewer routing and issue triage; it does not grant write access. Access is controlled through team membership.

### Manage your team

Team Maintainers own membership. Add members through the team's GitHub page and keep at least two Maintainers so the team does not become orphaned.

## Submit a private pull request

### Before you start

1. Search the [open private pull requests](https://github.com/microsoft-foundry/foundry-samples-pr/pulls) for related work.
2. Confirm that the work is internal and not intended for publication.
3. For work intended for publication, use the public [`microsoft-foundry/foundry-samples`](https://github.com/microsoft-foundry/foundry-samples) repository instead.

### Set up your environment

1. Clone this repository:

   ```shell
   git clone https://github.com/microsoft-foundry/foundry-samples-pr.git
   cd foundry-samples-pr
   ```

2. Install development dependencies for Python contributions:

   ```shell
   python -m pip install -r dev-requirements.txt
   ```

3. Set up pre-commit:

   ```shell
   pre-commit install
   ```

   Run all configured checks locally with:

   ```shell
   pre-commit run --all-files
   ```

### Make your changes

1. Create a feature branch:

   ```shell
   git checkout -b your-name/short-description
   ```

2. Add or update the internal sample, tooling, or supporting files.
3. Include a descriptive `README.md` in sample directories.
4. Follow any path-specific instructions and ownership requirements.

### Submit the pull request

1. Push your branch:

   ```shell
   git push origin your-name/short-description
   ```

2. Open a pull request against this repository's `main` branch.
3. Fill out the pull request description and complete applicable checklist items.
4. Respond to reviewer feedback and resolve failures from applicable internal checks.

Private pull requests and their checks are for internal repository quality only. They do not publish content or transfer changes to the public repository.

## Internal validation

This repository can run internal validation for samples and tooling. Internal validation does not initiate publication. When an authorized maintainer runs the retained bridge, applicable validation results can determine which content is eligible for that run.

### Validation paths

| Path | How it opts in | Who owns it |
|------|----------------|-------------|
| **Central ADO pipeline** | Add `sample.yaml` | DevX Engineering |
| **Team-owned pipeline** | Configure checks through the owning team | Feature team |

The central pipeline discovers sample directories that contain `sample.yaml`. Each owning pipeline runs its configured build, validation, or service-specific checks.

### Build readiness levels

Validation can measure build readiness in cumulative levels:

| Level | Name | What it checks | Example |
|-------|------|----------------|---------|
| 1 | **Parse** | Does the code parse? | `python -m py_compile sample.py` |
| 2 | **Resolve** | Do dependencies install? | `pip install -r requirements.txt` |
| 3 | **Load** | Does the code load without error? | `python -c "import sample"` |
| 4 | **Run** | Does the sample run against live resources or deployed infrastructure? | Provision, deploy, and exercise the sample end-to-end |

### Configure central validation

For central ADO validation, add a `sample.yaml` file to the sample directory:

```yaml
name: my-sample
description: A brief description of what this sample demonstrates
```

The pipeline applies language defaults and supports custom `build`, `validate`, and `test` commands. See the [Validation Pipeline README](.azure-pipelines/README.md) for the schema and directory conventions.

#### Reference validation commands

| Language | `build` | `validate` | What it proves |
|----------|---------|------------|----------------|
| Python | `pip install -r requirements.txt` | `python -c "import sample"` | Dependencies resolve and code loads |
| C# | `dotnet restore` | `dotnet build` | Code compiles |
| Java | `mvn dependency:resolve` | `mvn compile` | Code compiles |
| Go | `go mod download` | `go build ./...` | Code compiles |
| TypeScript | `npm install` | `npx tsc --noEmit` | Imports type-check |
| JavaScript | `npm install` | `node -e "require('./sample')"` | Dependencies resolve and code loads |

## Fix pre-commit failures

| Check | Fix |
|---|---|
| **black** | Run `pre-commit run black --all-files` and commit the changes. |
| **ruff** | Run `pre-commit run ruff --all-files`, then address any remaining findings. |
| **nb-clean** | Run `pre-commit run nb-clean --all-files` and commit the changes. |

To avoid exposing secrets in committed code, use empty string placeholders:

```python
os.environ["AZURE_SUBSCRIPTION_ID"] = ""
```

## Discoverability

If internal sample work is later ported to a public pull request, YAML frontmatter in its `README.md` can prepare it for the [Microsoft code samples browser](https://learn.microsoft.com/samples):

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

## Contributor License Agreement

This project requires a Contributor License Agreement (CLA). When you submit a pull request, a CLA bot will check whether you need to sign one and guide you through the process. You only need to do this once across all Microsoft repositories. For details, visit <https://cla.opensource.microsoft.com>.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information, see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com).
