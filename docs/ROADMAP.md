# Roadmap

**Live status:** GitHub Project **SpanDeck — Product Roadmap** ([repository Projects tab](https://github.com/loloDawit/spandeck/projects)). Phases are GitHub Milestones `M0`–`M4`, with no dates. How tracking works: [`PROJECT_MANAGEMENT.md`](PROJECT_MANAGEMENT.md).

**Snapshot:** 2026-10-15, `main` = `3972167`. If this page and the Project disagree, the Project is right.

Work must be traceable to issues and acceptance tests. Do not ship features before M0 validates the foundation. Evidence labels: **[mocked]** means it is shown by tests with injected dependencies, not observed on a real macOS system. Hosted CI has not been run (owner's budget decision, 2026-10-14). Test results so far are owner-reported local runs.

## Now, next, later

| Order | Item | Milestone | Status | Notes |
|---|---|---|---|---|
| Done | R8: minimize and protect the local usage cache, #33 | M1 | Done — PR #34 (`8bcb1e7`) | Mocked, local evidence only; permissions on a real install not checked. |
| Next 1 | R10: restrict `--snapshot` to debug builds or a synthetic store | M1 | In progress, #36 | Small and independent. |
| Next 2 | R11: SHA-pin actions, least `permissions`, signing / notarization plan | M0 | Pending, #37 | Workflow and doc change only. Validate with local lint; don't run hosted CI without the owner's approval. |
| Next 3 | #3: OS-level runtime verification (audit §7 Phase 2) | M0 | Open | Last unmet acceptance item of #3. Needs a supported Mac and a dedicated account. |
| Next 4 | #6 streaming / dedupe fixtures and #8 performance baseline | M0 | Not started | Independent of each other. #8 needs supported macOS hardware. |
| Then | #7 provenance contract (remaining), #5 data minimization (after R8), then #9 ADR | M0 | In progress / blocked | #9 waits on findings from #3, #5, #6 and #7. |
| Later | #4 capability matrix and integration lifecycle spec, #10 supported Claude surfaces | M0 | Open | Feed M1 integrations and M2 adapters. |

## Remediation series (R1–R12)

From the security inventory in #3 ([`audits/0003-security-inventory.md`](audits/0003-security-inventory.md) §8). Remediations are implementation work and are tracked as sub-issues of the research issue that found them.

| ID | Change | Issue → PR | Milestone | Status |
|---|---|---|---|---|
| R1 + R2 | Login item and Claude Keychain / usage endpoint opt-in | #15 → #16 | M1 | Merged [mocked] |
| R3 | Hidden gauges pause quota collection | #19 → #20 | M1 | Merged [mocked] |
| R4 | Grok credentials and `grok` CLI execution opt-in | #17 → #18 | M1 | Merged [mocked] |
| R5 | Grok failures shown, not hidden as "not configured" | #21 → #22 | M1 | Merged [mocked] |
| R6 | Built-in pinned, verified pricing snapshot; no request at launch | #27 → #28 | M1 | Merged [mocked] |
| R7 | Unknown price is not $0; totals carry coverage | #30 → #31 | M0 | Merged [mocked]; rendered UI unverified |
| R8 | Cache: opaque ids, `0600`/`0700`, migration, clear action | #33 | M1 | **Done** (#34) |
| R9 | Honest User-Agent; back off after HTTP 401 | #24 → #25 | M1 | Merged [mocked] |
| R10 | `--snapshot` limited to debug builds or synthetic data | #36 | M1 | **In progress** |
| R11 | CI / release hardening | to be created | M0 | **Pending** |
| R12 | Injectable dependencies and mocked launch tests | #12 → #14 | M0 | Merged |

Done: 11 of 12 remediations (R1–R9, R12). Pending: R10 (#36), R11 (#37).

## M0 — Security and accounting baseline (in progress)

Epic: #2. Research issues #3–#11 stay open until all their acceptance criteria are met.

- [ ] Inventory permissions, process execution, credentials, network destinations, stored files and login-item behavior. *Code-level inventory done (#3, PR #13); OS-level confirmation outstanding (#3).*
- [ ] Document how to reproduce and opt out of each data-collection path. *Egress and capability matrices in the #3 audit; opt-outs exist for credentials, quota polling and the login item. Cache deletion: Settings ▸ Clear cached usage data (R8, #34).*
- [ ] Anonymized fixtures for duplicate stream updates, missing request IDs, timestamp boundaries, renamed models, bad pricing entries and partial log files. *Unpriced-model fixtures exist (R7); the rest is #6, not started.*
- [ ] Cross-check fixture totals with independent calculations; distinguish modeled cost from billed cost. *Cost coverage (complete / partial / unavailable) merged in R7; metric contract and remaining golden tests in #7.*
- [ ] Record baseline `swift test`, `swift build`, CPU, memory, scan time and startup. *`swift test` / `swift build` owner-reported on 2026-10-13 (#2); CPU, memory, scan and startup not measured (#8).*
- [ ] Checks for credential leakage and external egress. *Mocked launch-path tests show no credential read and no network request on default launch [mocked]; not observed at OS level.*
- [ ] ADR: canonical events, source adapters, deduplication and storage (#9). *Blocked on #3, #5, #6, #7.*
- [ ] Supported Claude observability surfaces and Bedrock coverage (#10). *Not started.*
- [ ] CI, source-integrity and distribution audit (#11), including R11. *Not started.*

**Exit:** known risks recorded, core arithmetic regression-tested, and first hardening changes planned with measurable acceptance criteria. *Status: risks recorded at code level; hardening planned and mostly merged; arithmetic regression fixtures (#6) and performance baseline (#8) missing.*

## M1 — Privacy-first foundation (in progress, ahead of M0 exit)

The remediation series landed here because the #3 audit found these changes safe to make before M0's research closed.

- [x] Explicit permission model; no credential extraction on default startup. *R1, R2, R4 (#15, #17); collection follows the menu-bar toggles (R3, #19); honest identity and 401 backoff (R9, #24) [mocked].*
- [ ] Opt-in login-item registration and reversible integration installation. *Login item opt-in done (#15). Integration lifecycle spec is part of #4; no integrations exist yet.*
- [ ] Storage / retention policy, data classification and migration / versioning. *R8 merged (#34): cache schema v4, retention and migration documented in `USAGE_CACHE.md`; the rest of #5 is open.*
- [ ] No data written outside SpanDeck's own storage without consent. *R10 pending.*
- [ ] Extract adapters and reconciliation behind testable interfaces without changing working UI behavior. *Test seams exist (R12); extraction waits on the #9 ADR.*
- [ ] Document unsupported or unauthorized quota sources. *Partly in the #3 audit; capability matrix in #4, #10.*
- [x] No network request at default launch. *R6 (#27) [mocked].*

**Exit:** the default experience has no unauthorized collection, secrets access, or persistent settings mutations. *Status: met in source and mocked tests for credentials, quota requests, login item and launch egress; R10 remains (R8 merged in #34), and nothing is confirmed at OS level yet.*

## M2 — Claude observability (not started)

Depends on: #9 ADR, #10 source verification, #6 / #7 fixtures and contracts.

- [ ] Supported telemetry and status-line adapters where available.
- [ ] Session explorer with model / project metrics, provenance, freshness, coverage and estimated prices.
- [ ] Context / cache / compaction charts only where reliable source data exists.
- [ ] Agent / tool attribution with clear unknown and partial-coverage states.
- [ ] Bedrock-specific data scoped separately from subscription usage; optional integration after review.

**Exit:** metrics reconcile in defined fixtures; gaps and confidence are visible to the user.

## M3 — Intelligence and alerts (not started)

Depends on: M2 data with known coverage.

- [ ] Quota, context, abnormal usage and run-health alerts with threshold / suppression controls.
- [ ] Explain why an alert occurred, including baseline and source.
- [ ] Advisory efficiency suggestions validated against before / after measurements.

**Exit:** low false-positive rate on test scenarios; every alert can be traced to events.

## M4 — Open-source release readiness (not started)

Depends on: M1 exit, #11 / R11, #8 performance budget.

- [ ] Security / privacy and performance regression suites; threat model review.
- [ ] Signed, notarized, verified release artifacts and least-privilege distribution.
- [ ] Onboarding / offboarding docs and install / uninstall validation.
- [ ] Accessibility checks and UI QA.

**Exit:** reproducible release process and documented user data lifecycle.

## Release blockers

Nothing should be published as a SpanDeck release until these are cleared:

1. **No OS-level evidence.** Every safety claim so far is [mocked] or code-level (#3, audit §7 Phase 2).
2. ~~**Cache still stores raw transcript paths** with default file modes until R8 merges (#33).~~ Resolved in source by R8 (#34); not verified on a real install.
3. **`--snapshot` can write real usage data to any path** until R10 merges (#36; in review).
4. **No CI run and no signing or notarization.** Hosted CI is unavailable for budget reasons; R11 and #11 are open.
5. **No accounting regression fixtures or performance baseline** (#6, #8), so M0 cannot exit.

## Dependencies

```
#3 (OS-level check) ─┐
#5 (minimization) ───┤
#6 (fixtures) ───────┼─► #9 ADR ─► M1 adapter extraction ─► M2 ─► M3
#7 (provenance) ─────┘                       ▲
#10 (Claude surfaces) ───────────────────────┘
#4 (consent / integration lifecycle) ─► M1 reversible integrations, M2 telemetry adapters
#8 (performance) ─► M4 regression budget
#11 + R11 ─► M4 signed release
R10 ─► M1 exit (R8 done, #34)
```

## Working agreements

- Small reviewable PRs; no direct commits to `main` for product work.
- Tests and acceptance criteria before declaring issues complete. Research issues close only when every acceptance item is met.
- Avoid conflating provider-reported limits, transcript totals, estimated equivalent costs and actual billed charges.
- Prefer upstreamable fixes while preserving original MIT copyright.
