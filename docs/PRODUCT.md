# SpanDeck — Product charter

Status: proposed direction; not a statement of implemented functionality.

## Mission
A secure, local-first observability tool for AI coding agents. Make resource use, model activity, context growth, and execution behavior understandable and auditable without requiring prompt or source-code collection.

## Initial audience
Engineers using Claude Code on macOS, including users with subscription and enterprise-managed configurations. Later providers are adapters, not a reason to compromise the initial Claude experience.

## Principles
1. **No surveillance by default.** Do not record prompts, code, tool arguments/results, raw API bodies, credentials, or private repository names by default.
2. **Numbers have provenance.** Every displayed metric must indicate origin, units, estimation method, period, completeness, and freshness. Unknown is not zero.
3. **One operation, one count.** Deduplicate overlapping logs, telemetry, and status-line observations by stable identity; do not sum independent views of the same model request.
4. **Read-only observation.** No silent modifications to Claude settings, hooks, context, model choice, or network behavior.
5. **Least privilege and reversibility.** Explicit opt-in for every integration; documented rollback and cleanup.
6. **Evidence before optimization.** Suggestions must be backed by measured observations and reversible experiments.
7. **Native, lightweight experience.** Menu-bar indicators stay responsive without a heavyweight always-on cloud service.

## MVP
- Safe baseline of current Headroom features, with attribution.
- Claude session explorer with per-model and per-project usage where source data supports it.
- Context utilization, compaction, cache, and tool activity when instrumented and available.
- Transparent quota availability (supported vs unofficial), estimated equivalent cost, and source-specific coverage.
- Local retention controls and a small settings surface for data collection.

## Not in the initial MVP
- AI rewriting or summarizing prompts automatically.
- Uploading raw transcripts to a hosted service.
- Automatic agent intervention, model switching, or context manipulation.
- Cross-device sync and organization-wide monitoring.
- Treating estimated API-equivalent prices as actual subscription charges.

## Success criteria
- Reconciled token totals on representative fixtures, with explicit known gaps.
- No automatic credential extraction or login-item registration.
- No prompt, tool argument, response body, or sensitive transcript payload persisted by default.
- Observable overhead measured on low/high log-volume machines and documented.
- Clear audit trail for data-source selection and user-visible limitations.
