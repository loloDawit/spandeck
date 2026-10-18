# Roadmap

**Live status:** GitHub Project **SpanDeck — Product Roadmap** ([repository Projects tab](https://github.com/loloDawit/spandeck/projects)). Phases are GitHub Milestones `M0`–`M4`, with no dates. How tracking works: [`PROJECT_MANAGEMENT.md`](PROJECT_MANAGEMENT.md).

**Snapshot:** 2026-10-18, `main` = `37623fe` (M0 tracking reconciliation, #2). If this page and the Project disagree, the Project is right. M0's progress bar is #2's closed sub-issues: 4 of 11.

Work must be traceable to issues and acceptance tests. Do not ship features before M0 validates the foundation. Evidence labels: **[mocked]** means it is shown by tests with injected dependencies, not observed on a real macOS system. **[CI]** means the test suite passed on a GitHub-hosted runner. That shows the [mocked] tests pass on that toolchain. It doesn't show how the app behaves on a real Mac. Before 2026-10-15, test results were owner-reported local runs only. See [Hosted CI baseline](#hosted-ci-baseline).

## Now, next, later

| Order | Item | Milestone | Status | Notes |
|---|---|---|---|---|
| Done | #3: credential, permission and egress audit with OS-level runtime runs 1 and 2 | M0 | Closed 2026-10-16 | [Results](audits/0003-runtime-verification.md#8-results). Default launch offline as observed [runtime]. Not covered: Intel, other macOS versions, signed builds, V16 (#4). |
| Done | #5: privacy verification (audit 0007), P1/P2/P4 fixes #66, #68, #70, Run 4 | M0 | Closed 2026-10-18 | Residual risks accepted by the owner, not verified absent. The personal-account trial is still **NO-GO**. |
| Done | #6: ledger fixtures F01–F49; fixes #55–#58 (PRs #60–#63) | M0 | Closed 2026-10-18 | No overlapping-source fixture (#9). Open policies P2/P5/P6/P10/P12 → #9, P11 → #10, P15 → #7. |
| Done | #11 part: SpanDeck identity isolated from Headroom (PR #65, audit 0008) | M0 | Merged | No migration of Headroom state. The rest of #11 is open. |
| Next | #9 ADR and #7 metric contract, in one joint design pass | M0 | Next / in progress | Each waits on the other, so they're drafted together. |
| Next | #11 repository protection and release gate | M0 | In progress | The `main` ruleset targets no branch, and `release.yml` can publish an unsigned DMG on any `v*` tag. Findings are on #11. |
| Later | #10 supported Claude surfaces, then #4 capability matrix and consent / rollback spec | M0 | Open | #10 owns the capability matrix; #4 consumes it. Feeds M1 integrations and M2 adapters. |
| Later | #8 performance baseline | M0 | Open | Relative synthetic debug timings posted on #8; no committed harness, and no startup, memory or CPU baseline. |
| Backlog | #46 blocking subprocesses can starve Swift's shared executor | M0 | Open, P1 | Engineering follow-up, not an M0 exit criterion. CI runs serially until it is resolved. |

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
| R8 | Cache: opaque ids, `0600`/`0700`, migration, clear action | #33 → #34 | M1 | Merged [mocked] |
| R9 | Honest User-Agent; back off after HTTP 401 | #24 → #25 | M1 | Merged [mocked] |
| R10 | `--snapshot` limited to debug builds or synthetic data | #36 → #39 | M1 | Merged [mocked]; binaries not run |
| R11 | CI / release hardening | #37 → #41 | M0 | Merged [CI]; signing and notarization planned, not done |
| R12 | Injectable dependencies and mocked launch tests | #12 → #14 | M0 | Merged |

Done: **12 of 12** remediations (R1–R12) merged. That completes the remediation series. It doesn't complete M0 or M1, and it isn't a release approval.

### Hosted CI baseline

- **First green run:** [run 38844113831](https://github.com/loloDawit/spandeck/actions/runs/38844113831) on `main` = `6d51227` (2026-10-16 UTC). 187 tests passed, and the workflow hardening check passed.
- **Latest at this snapshot:** [run 39078822895](https://github.com/loloDawit/spandeck/actions/runs/39078822895) on `37623fe`: 296 tests passed with 4 known issues (fixture F12, policy P10 on #9).
- **Runner:** `macos-15` arm64 (3 cores). Image `macos-15-arm64` 20260907.0337, default Xcode 16.4 according to the image README. The Swift version isn't printed in the log. Local development uses Xcode 26.6 / Swift 6.3.3.
- **Serial tests:** CI runs `swift test --no-parallel` (PR #45). Run in parallel on 3 cores, tests whose fakes block a thread for up to 2 s timed out ([run 38843030419](https://github.com/loloDawit/spandeck/actions/runs/38843030419)). The working diagnosis and the conditions for running in parallel again are in #46.
- **How we got there:** the push of merge #41 started the first hosted run, [38827646254](https://github.com/loloDawit/spandeck/actions/runs/38827646254). It failed because Xcode 16.4 couldn't type-check two test expressions. #42 and #43 fixed that compile failure, #44 replaced a 1 s wall-clock test bound, and #45 made the tests run serially.
- **What CI shows:** the source compiles and the [mocked] tests pass on a hosted runner. **It doesn't show how the app behaves on a real Mac** (Keychain prompts, file modes, network traffic, login item), which still needs #3 Phase 2. CI builds no signed or notarized artifact.

## M0 — Security and accounting baseline (in progress)

Epic: #2. Research issues #3–#11 stay open until all their acceptance criteria are met.

- [x] Inventory permissions, process execution, credentials, network destinations, stored files and login-item behavior. *#3 closed: code-level inventory (PR #13) and default-launch runtime runs 1 and 2 on one Mac. Consent-enabled paths (V16) remain unverified (#4).*
- [ ] Document how to reproduce and opt out of each data-collection path. *Egress and capability matrices in the #3 audit; opt-outs exist for credentials, quota polling and the login item. Cache deletion: Settings ▸ Clear cached usage data (R8, #34).*
- [ ] Anonymized fixtures for duplicate stream updates, missing request IDs, timestamp boundaries, renamed models, bad pricing entries and partial log files. *#6 closed: fixtures F01–F49 with golden results, run in tail, full-scan, relaunch and rebuild modes. No overlapping-source fixture yet (#9).*
- [ ] Cross-check fixture totals with independent calculations; distinguish modeled cost from billed cost. *Cost coverage merged in R7, and #7's golden tests exist. The metric contract and the observed / estimated / actual vocabulary are open in #7.*
- [ ] Record baseline `swift test`, `swift build`, CPU, memory, scan time and startup. *`swift test` runs in hosted CI on every push to `main` (serial, debug only). Relative synthetic ledger timings are posted on #8; CPU, memory and startup aren't measured, and the harness isn't committed.*
- [ ] Checks for credential leakage and external egress. *Default launch: no credential read and no network request [mocked][runtime, #3 runs 1–2, #5 Run 4], within the monitors' windows. Consent-enabled paths are unverified (V16, #4).*
- [ ] ADR: canonical events, source adapters, deduplication and storage (#9). *Next: drafted jointly with #7. The P4 identity policy and Headroom no-migration are decided; no ADR document yet.*
- [ ] Supported Claude observability surfaces and Bedrock coverage (#10). *Not started.*
- [ ] CI, source-integrity and distribution audit (#11), including R11. *R11 merged (#37, PR #41): pinned actions, least permissions, signing / notarization plan ([RELEASE_SIGNING.md](RELEASE_SIGNING.md), plan only). Identity isolation merged (PR #65). The rest of #11 is open: an effective branch ruleset with required checks, a release gate in `release.yml`, private vulnerability reporting, Developer ID signing, notarization, and Intel and macOS 14 runs. The 2026-10-18 findings are on #11.*

**Exit:** known risks recorded, core arithmetic regression-tested, and first hardening changes planned with measurable acceptance criteria. *Status: risks recorded and runtime-checked on one Mac; arithmetic regression fixtures done (#6); performance baseline (#8), ADR (#9) and the release-hardening list (#11) still open. The exit criteria themselves are tracked on #2.*

## M1 — Privacy-first foundation (in progress, ahead of M0 exit)

The remediation series landed here because the #3 audit found these changes safe to make before M0's research closed.

- [x] Explicit permission model; no credential extraction on default startup. *R1, R2, R4 (#15, #17); collection follows the menu-bar toggles (R3, #19); honest identity and 401 backoff (R9, #24) [mocked].*
- [ ] Opt-in login-item registration and reversible integration installation. *Login item opt-in done (#15). Integration lifecycle spec is part of #4; no integrations exist yet.*
- [ ] Storage / retention policy, data classification and migration / versioning. *R8 merged (#34); the cache is now v7, and retention and migration are documented in `USAGE_CACHE.md`. #5 closed 2026-10-18 with no automatic migration of Headroom state (owner decision).*
- [ ] No data written outside SpanDeck's own storage without consent. *R10 merged (#39): `--snapshot` is refused in release builds and writes only synthetic images in debug builds; not verified at OS level.*
- [ ] Extract adapters and reconciliation behind testable interfaces without changing working UI behavior. *Test seams exist (R12); extraction waits on the #9 ADR.*
- [ ] Document unsupported or unauthorized quota sources. *Partly in the #3 audit; capability matrix in #4, #10.*
- [x] No network request at default launch. *R6 (#27) [mocked].*

**Exit:** the default experience has no unauthorized collection, secrets access, or persistent settings mutations. *Status: met in source and mocked tests for credentials, quota requests, login item and launch egress; R8 and R10 merged (#34, #39), and nothing is confirmed at OS level yet.*

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

1. ~~**No OS-level evidence.**~~ Default-launch behavior verified [runtime] on one Apple Silicon Mac with macOS 26.5 and an ad-hoc build ([runtime verification](audits/0003-runtime-verification.md) §8.4). Still open: Intel, other macOS versions, a Developer ID-signed build (#11), and consent-enabled paths (V16).
2. ~~**Cache still stores raw transcript paths** with default file modes until R8 merges (#33).~~ Resolved in source by R8 (#34); not verified on a real install.
3. ~~**`--snapshot` can write real usage data to any path** until R10 merges (#36).~~ Resolved in source by R10 (#39); not verified by running a release binary.
4. **No signing or notarization.** Builds are signed ad hoc, and the Developer ID plan ([RELEASE_SIGNING.md](RELEASE_SIGNING.md)) hasn't been carried out. If triggered, `release.yml` would still publish an ad-hoc-signed, unnotarized DMG; the release gate is open in #11. Hosted CI now passes ([run 38844113831](https://github.com/loloDawit/spandeck/actions/runs/38844113831)), but it runs tests only, serially (#46).
5. ~~**No accounting regression fixtures**~~ (#6 closed). **No performance baseline** (#8), so M0 cannot exit.
6. **No effective repository protection.** The `main` ruleset targets no branch, so there is no PR requirement or required check, and private vulnerability reporting is off (#11, 2026-10-18).

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
M1 exit (R8 done #34, R10 done #39)
```

## Working agreements

- Small reviewable PRs; no direct commits to `main` for product work.
- Tests and acceptance criteria before declaring issues complete. Research issues close only when every acceptance item is met.
- Avoid conflating provider-reported limits, transcript totals, estimated equivalent costs and actual billed charges.
- Prefer upstreamable fixes while preserving original MIT copyright.
