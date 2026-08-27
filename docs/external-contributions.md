# External Partner Contributions (Historical)

> **Historical internal record:** This page preserves the partner ownership and service model used before public-default contribution routing was finalized on 2026-08-27. It is not an onboarding guide or a publication path.

External and partner changes intended for publication now follow the public [`microsoft-foundry/foundry-samples` contribution policy](https://github.com/microsoft-foundry/foundry-samples/blob/main/CONTRIBUTING.md). The required public merge gate is `trusted`. A contributor who cannot create a public branch must contact a repository owner; do not grant private access or use the retained bridge as a workaround.

Private `foundry-samples-pr` access, private validation, and private CODEOWNERS routing are for internal-only work. A private merge does not publish. The retained bridge is an operator-only mechanism for an explicitly approved private-main batch, not an external-contribution route.

## Durable governance history

The former white-glove model established useful ownership expectations that still apply when a maintainer sponsors partner content in a public pull request:

| Role | Durable responsibility |
|------|------------------------|
| **Foundry DevX Engineering** | Repository infrastructure and best-effort Build-readiness diagnosis |
| **Feature-team DRI** | Functional correctness, partner relationship, escalation, and any sample-owned Live-service validation |
| **External partner** | Sample code, dependency currency, and timely response to functional issues |

- Every partner area needs a named Microsoft DRI.
- Build-readiness success does not prove functional correctness against a live service.
- Sample-owned Live-service checks remain the owning team's responsibility.
- Historically, partner teams used a four-business-day response target before maintainers considered removing broken public content. Removal now requires a normal reviewed public pull request; deleting or relocating private content does not automatically change public content.
- Historical partner comments in private [CODEOWNERS](../.github/CODEOWNERS) are internal routing evidence only. Current public ownership belongs in the public repository's [CODEOWNERS](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/CODEOWNERS).

## Current validation references

- [Public per-sample validation contract](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/scripts/validate-sample.README.md) - current Build-readiness and Live-service commands and behavior
- [Public daily validation cadence](https://github.com/microsoft-foundry/foundry-samples/blob/main/.github/validation-pilot.README.md) - warm-project fleet validation and reporting
- [Private validation contract](validation-contract.md) - transitional private ADO and bridge-time behavior pending P6

## Historical changes

| Date | Change |
|------|--------|
| 2026-08-27 | Retired private partner onboarding and automatic-sync guidance; public contribution policy is authoritative. |
| 2026-06-22 | Simplified the former private onboarding process and retained partner ownership in CODEOWNERS comments. |
| 2026-04-29 | Added team-owned validation as a first-class category in the former sync-gating model. |
