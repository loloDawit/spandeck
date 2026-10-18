# Metric and provenance contract

- **Status:** Proposed. Contract version **0.1** (design only; no code change). Refs #7, drafted jointly with #9 ([ADR 0001](adr/0001-canonical-events-identity-and-storage.md)).
- **Date:** 2026-10-18

This contract says what each number SpanDeck shows means, where it comes from, how fresh and complete it is, and how missing data is shown. Labels follow the ADR: **[decided]**, **[proposed]**, **[owner]**, **[blocked #10]**.

## 1. Four kinds of number that must never be mixed [decided in principle: #7 problem statement, PRODUCT.md]

| Kind | Example | Unit | Authority | Today's source |
|---|---|---|---|---|
| **Token quantity** | 250 tokens of `claude-test-1` today | tokens | observed from local logs | Claude JSONL, Grok `usage.json` |
| **Estimated API-equivalent cost** | ≈ $0.004 | USD at list price | estimate: LiteLLM price table at a pinned revision | `Pricing` (R6) |
| **Provider-reported cost** | Grok turn cost | USD (1e-10 ticks) | observed, as the provider's CLI reported it; not a bill | Grok `costUsdTicks` |
| **Subscription quota** | Session 42 % used, resets 18:00 | percent of a plan window | provider-reported, **unofficial** endpoint, opt-in | `ClaudeLimitsClient`, `GrokClient` |
| **Actual charge** | an invoice line | USD | provider billing | **none: always *unavailable*** (no source exists; Bedrock / AWS cost sources blocked #10) |

**Rules:**
- A quota percent is never summed with, compared to or derived from tokens or costs (#7 non-goal).
- An estimate is never labelled as a charge.
- A provider-reported cost is never relabelled as a bill.

## 2. Metric table

| Metric | Source | Dimensions | Period | Freshness | Accuracy limits |
|---|---|---|---|---|---|
| Claude tokens | `claude.jsonl` | slot (15 min UTC) × model | today / 7 d / 30 d / 5 h window, local days | at most one refresh behind: hot files tailed each refresh, full scan ≤5 min | P2 snapshots, P4 identity, P6 pending, P7 unread, P8 flawed, P9 cache tiers, P10/P11 open |
| Claude estimated cost | tokens × price table | model | as tokens | price revision and retrieval date (`PricingInfo`) | unpriced models unknown (P17); tier-unresolved is a lower bound; disputed is unpriced |
| Grok tokens | `grok.usage-json` | slot × model | as Claude, no 5 h window | each refresh (`mtime` change) | dedupe on `endedAt`, `totalTokens`, `costUsdTicks`; **missing counters read as 0 today (F-1)** |
| Grok reported cost | `costUsdTicks` | slot × model | as Grok tokens | as Grok tokens | turns without it are unknown (R7) |
| Claude quota | `claude.quota-endpoint` (opt-in, unofficial) | limit kind (session, weekly, model-scoped) | the provider's window, ending at `resets_at` | `fetchedAt` per poll | **missing percent read as 0 today (F-2)**; shape can change without notice |
| Grok quota | `grok.billing` (opt-in) | plan, products | the provider's billing period | `fetchedAt`; stale shown after a temporary failure (#21) | product `usagePercent` missing read as 0 today (F-2) |
| Actual charges | none | n/a | n/a | n/a | always *unavailable* |
| Session, project, agent, tool metrics | none today | n/a | n/a | n/a | blocked #10 / ADR D7 |

## 3. Statuses shown to the user [proposed; wording owner]
Every displayed number carries exactly one **value status** and zero or more **qualifiers**.

**Value status:**
- **observed:** read from a source that records the quantity itself (tokens in logs, a reported percent or cost).
- **estimated:** computed from observed quantities and a stated method (list-price cost).
- **unavailable:** there is no value. Never shown as `0`, `$0` or `0 %`; shown as "—" with a reason.
- **actual:** reserved for a provider charge. No source today, so never shown.

**Qualifiers** (each maps to an existing facet, so most need no new data):

| Qualifier | Meaning | Existing facet | Current UI text (#55, #58, R7) |
|---|---|---|---|
| partial | some contributing values unknown; the shown amount is a lower bound | `CostEstimate.Coverage.partial`, `minimum` | "≥ $x" |
| provisional | quantities disagree between sources; no bound claimed | `QuantityUncertainty.disputedTokens`, `CostEstimate.isProvisional` | cache-write conflict note |
| approximate identity | some operations identified by less than both ids | `IdentityCoverage.uncertain > 0` | "Usage may be approximate: some records lack identifiers." |
| incomplete data | unread records or flawed counters in the period | `DataCompleteness.isComplete == false` | unread / flawed note |
| pending | a transcript's last line is unfinished | `DataCompleteness.pending` | none shown as a gap (normal while writing) |
| saturated | a sum held at `Int.max` | `QuantityUncertainty.saturated` | held note |
| stale | the last successful fetch is older than its expected cadence | `GrokPlan` after a temporary failure; **not yet for Claude quota or prices** | Grok stale label |
| boundary-uncertain | a window's first slot may include records before its start | none yet (P15) | none |
| unofficial | value from an undocumented endpoint | none yet | consent card text (#15) |

**Proposed stale thresholds [owner]:**
- quota: older than 2 poll intervals, or than its `resets_at`;
- prices: the built-in snapshot's `retrieved` date is shown, not a staleness alarm, since prices change only by an explicit download (R6).

## 4. Null versus zero [decided as a principle; rules proposed]
1. **Absent ≠ 0.** A counter, percent or cost that is missing, `null`, non-numeric, negative, fractional or too large is **absent**.
   - Absent counters make the operation `flawed` (P8).
   - An absent quota percent makes the quota **unavailable**.
   - An absent cost makes the cost **unknown** (R7).
2. **Real zero is a value.** `"output_tokens": 0`, `"costUsdTicks": 0` and `"percent": 0` are exact zeros.
3. **No data in a period** (no records at all) is exactly 0 tokens with `complete` coverage. But if any source that covers the period failed or is unread, the total carries **incomplete data**.
4. **Sums keep their worst status.** One unknown term makes a sum partial; all unknown makes it unavailable (`CostEstimate +`, `UsageSummary.combine`).
5. **Clamping hides data.** A derived counter that would be negative is a data conflict, flagged, not clamped to 0. Today: Grok `max(inputTokens − cachedReadTokens, 0)`; see F-1.

## 5. Current violations to fix (findings, not fixed here)
- **F-1, Grok local usage reads missing as 0.**
  - `parseGrokUsage` (`Ledger.swift:1469–1476`) uses `int(_:)`, which returns 0 for an absent or non-numeric key (`Util.swift:176`). This covers `inputTokens`, `outputTokens`, `cacheCreationTokens`, `cachedReadTokens`, `modelCalls`, and `totalTokens` in the dedupe key.
  - It also clamps `input − cached` at 0.
  - **Proposed:** read counters with the P8 `Ledger.counter` rules; flag Grok turns like Claude groups (Grok gains a `DataCompleteness`); the dedupe key uses `optionalInt` with absent spelled distinctly (the open "Grok dedupe identity" item from #7's 2026-10-15 comment).
  - **Fold into:** #7, or a small child of it, since there's no existing Grok-accounting issue.
- **F-2, quota parsing reads missing as 0 %.**
  - `ClaudeLimitsClient.fetch` uses `l.double("percent") ?? 0` and `utilization ?? 0`.
  - `GrokClient` product `usagePercent ?? 0`.
  - The Grok top-level percent is already strict (#21).
  - **Proposed:** a missing percent makes that limit unavailable, kept with its reset time if present.
  - **Fold into:** #4 (quota integration lifecycle), or #7.
- **F-3, no staleness for Claude quota or prices.** The Claude gauge goes blank on errors (`claudeGaugeBlankOnOtherErrors`) rather than showing the last value as stale. That is safe but loses information. This needs an owner choice.

## 6. Reconciliation and accounting invariants
These hold in today's code unless marked, and every refactor must keep them (fixture-tested):
- **I-1:** across an operation's records, each counter takes its maximum, and totals never decrease. Cache writes are the exception: one quantity, the larger quantity wins with its classification (P2, P9; `Agg.reconciled`).
- **I-2:** reconciliation is commutative and associative. Arrival order, file grouping, rescans and joins reach the same operation.
- **I-3:** each aggregate bucket equals the sum of its operations' parts (`count` / `uncount` / `rebuild`).
- **I-4:** a partial id joins a pair only when unambiguous, and a join is never undone (P4).
- **I-5:** unread records reduce completeness, never totals (P7).
- **I-6:** sums saturate at `Int.max` and say so; they never wrap (P8, #58).
- **I-7 [proposed]:** sources that can't be proven to observe the same operation are never summed. They're shown as separate views.
- **I-8 [proposed]:** operations are scoped by provider (and by account once known), and never matched across providers.
- **I-9:** a quota percent is never added to, or derived from, tokens or costs.
- **I-10:** an estimated cost carries its price revision. A provider-reported cost is never relabelled actual. Actual stays unavailable until a billing source exists.
- **I-11:** coverage adds field-wise through every total, so one provider's gap keeps the combined total qualified (`UsageSummary.combine`).

## 7. Time windows [P14, P16 decided; P15 blocked]
- **Local days:** computed from 15-minute UTC slots in the current calendar, correct across DST and in ±hh:15/30/45 offsets (F21, F46, F47).
- **Views:**
  - *today* is local midnight → now;
  - *7 days* and *30 days* include today, starting at local midnight 6 and 29 days ago;
  - retention is 32 days.
- **5-hour session window:** start = `resets_at − 5 h` from the quota endpoint (an **assumption**: the endpoint is unofficial and its window semantics undocumented). It needs the quota opt-in; without it there's no window, not an empty one.
  - Proposed: when the start isn't on a slot boundary, the first slot is **boundary-uncertain** (F22).
  - **Blocked:** characterising real `resets_at` values (#10).
- **Coverage gaps:** a period with a failed read, unread records or pending files carries **incomplete data** or **pending**. A period older than 32 days is outside retention and shows **unavailable**, not 0.

## 8. Enterprise, Bedrock and account limits [blocked #10; stated now]
- **No account dimension today.** Usage from several Claude accounts on one Mac (personal and work) is summed as one, because transcripts carry no account field SpanDeck reads. This is a known limit to show in the UI.
- **Bedrock / Vertex:** model ids are accepted and counted, and costed at LiteLLM's first-party list price if the id matches. **That is not the Bedrock price or a charge.**
  - Proposed: label Bedrock/Vertex-shaped ids as *estimated at Anthropic list price; cloud provider pricing differs* until #10 says otherwise.
- **Enterprise / managed:** quota percentages may not be exposed for some accounts (#10 non-goal: don't assume). The quota is unavailable, never 0 %.
- **Actual spend:** no AWS Cost Explorer or Anthropic billing source is read, or planned without a separate threat-model review.

## 9. Golden tests already covering this contract
- `CostCompletenessTests`;
- `DataCompletenessTests`;
- `QuantityTests`;
- `IdentityCoverageTests`;
- `QuotaVisibilityTests`;
- `GrokErrorStateTests`;
- `LedgerFixtureTests` F01–F49;
- `TimeZoneTests`.

**New ones needed per slice:** F-1 (Grok missing counters), F-2 (quota missing percent), P10 decision (F12), P15 boundary slot (F22).

## 10. Owner decisions
1. The status vocabulary and qualifier wording (§3).
2. Stale thresholds (§3), and F-3: blank vs stale for the Claude quota.
3. Where F-1 and F-2 are tracked (fold into #7 / #4).
4. The Bedrock/Vertex labelling text (§8).
