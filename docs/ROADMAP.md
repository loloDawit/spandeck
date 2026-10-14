# Roadmap

> **Tracking:** [M0 master issue #2](https://github.com/loloDawit/spandeck/issues/2) links to the nine evidence-first M0 research and test issues. These issue-title workstreams are **not yet GitHub Milestone objects**.

Roadmap stages, not yet-created GitHub milestones. Work must be traceable to issues and acceptance tests. Do not ship features before M0 validates the foundation.

## M0 — Security and accounting baseline
- [ ] Inventory permissions, process execution, credentials, network destinations, stored files, and login-item behavior.
- [ ] Document how to reproduce and opt out of each data-collection path.
- [ ] Build anonymized fixtures for duplicate stream updates, missing request IDs, timestamp boundaries, renamed models, bad pricing entries, and partial log files.
- [ ] Cross-check fixture-based totals with independent calculations; distinguish modeled cost from billed cost.
- [ ] Run and record baseline `swift test`, `swift build`, CPU, memory, scan time, and startup measurements.
- [ ] Add checks for credential leakage and external egress.
**Exit:** Known risks recorded, core arithmetic regression-tested, and first hardening changes planned with measurable acceptance criteria.

## M1 — Privacy-first foundation
- [ ] Explicit permission model and settings; no credential extraction on default startup. *(Claude Keychain read opt-in since #15; Grok credentials since #17. Hidden gauges pause quota polling, #19.)*
- [ ] Opt-in login-item registration and reversible integration installation. *(Login item opt-in since #15.)*
- [ ] Storage/retention policy, data classification, and migration/versioning.
- [ ] Extract adapters and reconciliation behind testable interfaces without changing existing working UI behavior.
- [ ] Document unsupported or unauthorized quota sources.
**Exit:** Default experience has no unauthorized collection, secrets access, or persistent settings mutations.

## M2 — Claude observability
- [ ] Supported telemetry and status-line adapters where available.
- [ ] Session explorer with model/project metrics, provenance, freshness, coverage, and estimated prices.
- [ ] Context/cache/compaction charts only where reliable source data exists.
- [ ] Agent/tool attribution with clear unknown and partial-coverage states.
- [ ] Bedrock-specific data scoped separately from subscription usage; optional integration after review.
**Exit:** Metrics reconcile in defined fixtures; gaps and confidence are visible to the user.

## M3 — Intelligence and alerts
- [ ] Quota, context, abnormal usage, and run-health alerts with threshold/suppression controls.
- [ ] Explain why an alert occurred, including baseline and source.
- [ ] Advisory efficiency suggestions validated against before/after measurements.
**Exit:** Low false-positive rate on test scenarios; every alert can be traced to events.

## M4 — Open-source release readiness
- [ ] Security/privacy and performance regression suites; threat model review.
- [ ] Signed, notarized, verified release artifacts and least-privilege distribution.
- [ ] Onboarding/offboarding docs and install/uninstall validation.
- [ ] Accessibility checks and UI QA.
**Exit:** Reproducible release process and documented user data lifecycle.

## Working agreements
- Small reviewable PRs; no direct commits to main for product work.
- Tests and acceptance criteria before declaring issues complete.
- Avoid conflating provider-reported limits, transcript totals, estimated equivalent costs, and actual billed charges.
- Prefer upstreamable fixes while preserving original MIT copyright.
