# Validation Reporting — Decisions

> **Status:** Design-locked 2026-05-14. Companion to `docs/validation-story-decisions.md` (the gate) — this doc covers the **reporting layer** that consumes the gate's signal.
>
> **Internal-only.** Lives under `docs/`, which is excluded from public sync.

## Context

The sync gate (`docs/validation-story-decisions.md` §8) posts per-sample GitHub commit statuses on every `push: main` in `microsoft-foundry/foundry-samples-pr`. Live state is one API call away (`gh api repos/.../commits/main/status`). Today the only "view" of that signal is the workflow-run summary on each sync run.

This effort makes the gate's signal **visible at-a-glance**, **trendable over time**, and **routable to owning teams**.

## Phase shape

| Phase | Anchor | Scope summary |
|---|---|---|
| **Design Lock** | (this doc) | Lock decisions Q1, Q3–Q6, Q9 before writing code. Q2/Q7/Q8 deferred. |
| **View Exploration** | (chat) | Find real-world examples of each GitHub-native form factor; lock Q2 by looking, not imagining. |
| **Health Board** | ADO 5237809 | Ship the v1 visible artifact. |
| **Trend History** | ADO 5237811 | Daily snapshot + rolling metrics, additive on Health Board. Q7 locks here. |
| **Team Routing** | ADO 5237812 | Per-team grouping. Q8 locks after Health Board ships and we see how the data feels. |

Phase names are binding: do not refer to these as `G`, `G1`, `G2`, `G3` in branches, commits, PR titles, ADO task titles/notes, or doc headings.

## Decisions

### Q1 — Audience: PMs/leads reporting up

The Health Board optimizes for **rollup narrative** (% healthy, trend, exec-grade summary), not Monday-morning triage. Design implications:

- Lead with summary numbers, not a table of every sample.
- Drill-down via `target_url` is present but secondary.
- Single-glance answer to "are we healthy?" is the primary success criterion.

Triage flow (who owns each red, where to click) is still supported but not the load-bearing path. Team Routing (when shipped) will optimize for the triage audience.

### Q2 — Form factor: pinned GitHub issue (revised 2026-05-28)

Originally locked 2026-05-14 as a committed static markdown page at `internal/dashboards/validation-health.md` (Upptime-style). Revised 2026-05-28 after the first production cron run failed.

**Why it changed.** Branch protection on `main` requires PRs for all writers — even `github-actions[bot]` with `contents: write`. The cron-direct-commit-to-main model bounced with `GH013: Repository rule violations`. The pre-flight check on "can the bot push to main?" was missed during design lock. Two recovery options existed:

1. **Auto-PR per refresh** (shipped briefly in PR #394) — workflow opens a branch + auto-merge PR per run via a GitHub App with bypass perms. Worked, but added daily PR noise, pumped commits through the sync gate's SHA stream (benign today, fragile if gate semantics tighten), polluted `main` history, and embedded a governance carve-out (the App's bypass) for routine writes.
2. **Pinned GitHub issue** (current) — workflow rewrites the body of a pinned dashboard issue. No branch protection involved, no main commits, no PR list noise, no sync-gate interaction, no rule carve-out. One-link discoverability (better than the original committed-file UX it replaced).

**Current mechanism:**

- **Primary surface:** pinned issue [microsoft-foundry/foundry-samples-pr#396](https://github.com/microsoft-foundry/foundry-samples-pr/issues/396) — body rewritten on each refresh.
- The same renderer (`render-validation-health.sh`) produces the markdown; only the delivery step changed.
- Workflow uses the default `GITHUB_TOKEN` with `issues: write` — no App-token machinery required for this workflow (the App still exists for other workflows in the repo).
- Workflow reopens the issue if someone closes it (the workflow is the source of truth).

**Trade-offs accepted:**

- No `git log` / `git blame` on dashboard state over time. Acceptable because Trend History phase (next, ADO 5237811) will own per-sample historical state as a first-class concern, not as a byproduct of dashboard edits.
- Issue body has a ~64KB cap. Current render is ~5KB. Plenty of headroom; revisit if the sample list ~10×s.
- Issue body is editable by anyone with triage perm. Self-heals on next refresh; workflow is the source of truth.
- Loses the "fallback held in reserve" framing of the original Q2 (committed-page + `$GITHUB_STEP_SUMMARY` as second-place). Job-summary remains available if a per-run drill-down view is ever needed, but it's no longer paired with this primary surface.

### Q3 — Freshness: daily cron + `workflow_dispatch` (cron-only)

Originally locked as "piggyback on `sync-to-public.yml` + daily cron." Revised 2026-05-14 after rubber-duck pass surfaced two concrete blockers with the sync-piggyback approach:

1. `sync-to-public.yml` has `permissions: contents: read` — a final commit step would need elevation.
2. `verify-sync.yml` (workflow_run-triggered) checks out the private repo without pinning to `github.event.workflow_run.head_sha`. A dashboard auto-commit landing between sync's push and verify's checkout would cause verify to compute the block-list on the wrong SHA, raising false drift alerts. Fixing that would require modifying gate machinery, which Q9 forbids.

Final mechanism:

- A dedicated cron workflow at `30 6 * * *` UTC is the **only** writer of the Health Board file. It originally ran 30 minutes after the nightly sync; with private→public sync now manual-only, the health refresh remains an independent daily snapshot.
- `workflow_dispatch` for manual refresh.
- No `push:main` trigger, no piggyback in `sync-to-public.yml`.
- Trade-off accepted: max staleness ~24h. If sync-time visibility becomes desirable later, the fallback step-summary form factor (Q2) can be turned on inside `sync-to-public.yml` as a read-only side effect (no git mutations), keeping the gate untouched.

### Q4 — Grouping: sample-path tree

Primary axis: `samples/<lang>/<area>/<feature>/`. Secondary column on each row: pipeline-id(s) reporting on that sample.

Rationale: PMs think in "Python quickstarts" / "C# agents" / etc., not in "ado-build" / "hosted-agents-e2e". Pipeline-id matters when something's red (who do I escalate to?) — it's metadata, not the organizing principle.

### Q5 — Untracked samples: surfaced, distinct, never green

- Untracked samples appear in a dedicated section, separate from the gate's tracked-set status.
- Visual treatment: ⚪ / "ungated" — distinct from green (passing) and red/yellow (blocked).
- Include both a **count** and a **listing**. This is the silent-fail-open visibility lever; aggregating it away would defeat the purpose. We accept the noise of a long list because the alternative (silent grandfathering invisible at the rollup level) is worse.
- Related: Feature 5247733 (frozen grandfather list) is the gate-side fix for the same concern; this doc only covers making it visible.

**Discovery rule (sub-decision 2026-05-14):** "Expected to be reported on" is computed from the documented pipeline registry in `docs/validation-results-contract.md`, not a single `find` proxy. v1 covers both registered pipelines:

- `ado-build` (`validation.yml`): directories under `samples/` containing `sample.yaml`, recursive, excluding `.ci-skip`.
- `hosted-agents-e2e`: directories under `samples/python/hosted-agents/` and `samples/csharp/hosted-agents/` containing `agent.manifest.yaml`, excluding `.ci-skip`.

The "ungated" listing is the set of expected paths (union of both rules) that have **no** matching status context on the SHA being rendered. Hosted-agents pipeline isn't posting today, so on day one its expected paths show as ungated — accurate and aligned with the registry.

When a new pipeline lands, the script needs a 5-line registry update. v2 (post-Health-Board) can drive this off `docs/validation-results-contract.md` programmatically if it earns its keep.

### Q5b — Coverage display: two distinct numbers, not one compressed metric

Sub-decision 2026-05-14 (within Q1's rollup-narrative audience):

- **Tracked pass rate** = success / reported-tracked. This is the gate's pass signal.
- **Coverage** = reported-tracked / (reported-tracked + expected-uncovered). This is the discovery-vs-reality signal.

Both surfaced at the top. Never compress into a single "% healthy" — that hides the silent-fail-open mode Q5 exists to expose.

### Q5c — Multi-reporter state precedence

When more than one pipeline reports on the same sample path:

1. Any `failure` or `error` → **red**.
2. Else any `pending` → **yellow**.
3. Else all `success` → **green**.

Evidence column for non-green rows lists every non-success `target_url`. Green rows show "—" in the evidence column.

### Q6 — `pending` status display: yellow

Three colors total: green (success), yellow (pending), red (failure/error). Matches the gate semantics in `validation-story-decisions.md` §8 Q2 (pending blocks sync). Not currently emitted by any production pipeline — first occurrence is a separate audit (Task 5247662) — but the Health Board renders it correctly from day one.

### Q7 — Trend History storage: DEFERRED to Trend History phase

Lock when the Health Board form factor (Q2) is locked. The form-factor decision constrains storage options (e.g., if the Health Board is a static page committed under `internal/dashboards/`, history naturally lives next to it as `internal/dashboards/history/YYYY-MM-DD.json`).

### Q8 — Team Routing this iteration: DEFERRED

Decide after the Health Board ships and we see how the rollup-axis data feels. Two real options when we revisit: CODEOWNERS lookup vs. `sample.yaml team:` field. Default expectation: ship Health Board + Trend History this iteration, push Team Routing to a follow-up if it would slip the other two.

### Q9 — Out-of-scope guardrail: confirmed

The reporting layer does **not** modify the gate. Explicitly out of scope:

| ADO | Title | Why out |
|---|---|---|
| 5247733 | Frozen grandfather list (fail-open hole) | Gate change |
| 5242694 | Validation pipeline heartbeat status | Gate change |
| 5242695 | Sync gate enforces expected tracked-set per pipeline (v2) | Gate change |
| 5247789 | Weekly sync-gate digest issue | Adjacent; can ride on Health Board / Trend History later |
| 5247631 | PR-time advisory validation checks (sync gate v2) | Gate v2 |

## Working agreements (carry into execution)

- Branch: `brandom/validation-reporting` off `main`.
- One PR per phase (Health Board → soak → Trend History → maybe Team Routing).
- Reuse `compute-blocklist.sh` + `parse-validation-statuses.sh` for status-context parsing — do not reimplement. The dashboard's richer output needs (per-context state, `target_url`) are met by adding a new output mode to `parse-validation-statuses.sh` (e.g., `--json`) rather than forking the normalization logic. Gate callers keep using the existing mode.
- Markdown escape `|`, backticks, and newlines on any field derived from status payloads before rendering.
- Cron workflow rewrites the pinned dashboard issue body via `gh issue edit` (Q2 revised 2026-05-28). No git push, no PR, no concurrency-group retry needed.
- Brandon cannot self-approve PRs. Open and stop; do not merge.
- Commit trailer: `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

## Changelog

| Date | Change |
|---|---|
| 2026-05-14 | Design Lock — Q1, Q3, Q4, Q5, Q6, Q9 decided. Q2 deferred to View Exploration. Q7 deferred to Trend History phase. Q8 deferred until after Health Board ships. |
| 2026-05-14 | Q2 locked after View Exploration — committed static Markdown page under `internal/dashboards/` (Upptime-style). Job-summary form factor held as fallback. |
| 2026-05-14 | Post-rubber-duck sub-decisions: Q3 revised to cron-only (sync piggyback dropped — verify-sync race + permission gap); Q5 discovery widened to cover `hosted-agents-e2e` registry rule; Q5b two-number coverage display; Q5c multi-reporter precedence. Working agreements expanded: parser reuse via new `--json` mode, markdown escaping, push retry. |
| 2026-05-19 | PR #313 merged. First production cron failed: branch protection on `main` rejected the bot's direct push. Recovered same-day in PR #394 (App-token + auto-merge PR) — temporary fix, superseded 2026-05-28. |
| 2026-05-28 | Q2 revised — switched from committed-page-on-main to pinned dashboard issue #396. One-link UX, no branch-protection interaction, no daily PR/commit noise, no governance carve-out. Renderer unchanged; only delivery step rewritten. |
