# Metric and provenance contract

- **Status:** Partly accepted. Contract version **0.2** (design only; no code change). Refs #7, drafted jointly with #9 ([ADR 0001](adr/0001-canonical-events-identity-and-storage.md)).
  - **Accepted by the owner on 2026-10-18:** missing is not zero; the value statuses and qualifiers (§3); F-1 → #7, F-2 → #4; the F-3 direction; Bedrock/Vertex labelling (§8).
  - **Still open:** the stale threshold (§3); P10 display (ADR §D4.1).
- **Date:** 2026-10-18

This contract says what each number SpanDeck shows means, where it comes from, how fresh and complete it is, and how missing data is shown. Labels follow the ADR: **[decided]**, **[proposed]**, **[owner]**, **[blocked #10]**.

## 1. Five kinds of number that must never be mixed [decided: #7 problem statement, PRODUCT.md; owner 2026-10-18]

| Kind | Example | Unit | Authority | Today's source |
|---|---|---|---|---|
| **Token quantity** | 250 tokens of `claude-test-1` today | tokens | observed from local logs | Claude JSONL, Grok `usage.json` |
| **Estimated API-equivalent cost** | ≈ $0.004 | USD at list price | estimate: LiteLLM price table at a pinned revision | `Pricing` (R6) |
| **Provider-reported cost** | Grok turn cost | USD (1e-10 ticks) | observed, as the provider's CLI reported it; not a bill | Grok `costUsdTicks` |
| **Subscription quota** | Session 42 % used, resets 18:00 | percent of a plan window | provider-reported, **unofficial** endpoint, opt-in | `ClaudeLimitsClient`, `GrokClient` |
| **Actual charge** | an invoice line | USD | a **verified** provider billing source | **none: always *unavailable*** (no such source exists; Bedrock / AWS cost sources blocked #10) |

**Rules:**
- A quota percent is never summed with, compared to or derived from tokens or costs (#7 non-goal).
- An estimate is never labelled as a charge.
- A provider-reported cost is never relabelled as a bill.

## 2. Metric table

| Metric | Source | Dimensions | Period | Freshness | Accuracy limits |
|---|---|---|---|---|---|
| Claude tokens | `claude.jsonl` | slot (15 min UTC) × model | today / 7 d / 30 d / 5 h window, local days | at most one refresh behind: hot files tailed each refresh, full scan ≤5 min | P2 snapshots, P4 identity, P6 pending, P7 unread, P8 flawed, P9 cache tiers, P10/P11 open |
| Claude estimated cost | tokens × price table | model | as tokens | price revision and retrieval date (`PricingInfo`) | unpriced models unknown (P17); tier-unresolved is a lower bound; disputed is unpriced |
| Grok tokens | `grok.usage-json` | slot × model | as Claude, no 5 h window | each refresh (`mtime` change) | a missing or invalid counter flags the turn (F-1, #80); copies deduped on `endedAt`, the reported total and the R7 cost part, a copy without a total matched on its counters; an uncertain match is flagged; no input/cache split claimed for a conflict |
| Grok reported cost | `costUsdTicks` | slot × model | as Grok tokens | as Grok tokens | turns without it are unknown (R7) |
| Claude quota | `claude.quota-endpoint` (opt-in, unofficial) | limit kind (session, weekly, model-scoped) | the provider's window, ending at `resets_at` | `fetchedAt` per poll | **missing percent read as 0 today (F-2)**; shape can change without notice |
| Grok quota | `grok.billing` (opt-in) | plan, products | the provider's billing period | `fetchedAt`; stale shown after a temporary failure (#21) | product `usagePercent` missing read as 0 today (F-2) |
| Actual charges | none | n/a | n/a | n/a | always *unavailable* |
| Session, project, agent, tool metrics | none today | n/a | n/a | n/a | blocked #10 / ADR D7 |

## 3. Statuses shown to the user [accepted 2026-10-18; exact wording and stale threshold open]
Every displayed number carries exactly one **value status** and zero or more **qualifiers**.

**Value status:**
- **observed:** read from a source that records the quantity itself (tokens in logs, a reported percent or cost).
- **estimated:** computed from observed quantities and a stated method (list-price cost).
- **unavailable:** there is no value. Never shown as `0`, `$0` or `0 %`; shown as "—" with a reason.
- **actual:** only for a charge read from a **verified** billing source. None exists today, so it is never shown.

A **valid zero** (a counter, percent or cost that is present and exactly 0) is an *observed* (or *estimated*) 0. It is never shown as *unavailable*, and a missing or malformed value is never shown as 0 (§4).

**Qualifiers** (each maps to an existing facet, so most need no new data):

| Qualifier | Meaning | Existing facet | Current UI text (#55, #58, R7) |
|---|---|---|---|
| partial | some contributing values unknown; the shown amount is a lower bound | `CostEstimate.Coverage.partial`, `minimum` | "≥ $x" |
| provisional | quantities disagree between sources; no bound claimed | `QuantityUncertainty.disputedTokens`, `CostEstimate.isProvisional` | cache-write conflict note |
| uncertain identity | some operations identified by less than both ids, or (P5) a message id seen under more than one request id | `IdentityCoverage.uncertain > 0`; the P5 signal is a later slice | "Usage may be approximate: some records lack identifiers." |
| possible cross-model duplicate | one id pair has records under more than one model (P10): tokens are a range `[L, U]`, never exact | none yet; gated (ADR §D4.1) | none (today counted as exact, the defect F12 shows) |
| incomplete data | unread records or flawed counters in the period | `DataCompleteness.isComplete == false` | unread / flawed note |
| pending | a transcript's last line is unfinished | `DataCompleteness.pending` | none shown as a gap (normal while writing) |
| saturated | a sum held at `Int.max` | `QuantityUncertainty.saturated` | held note |
| stale | a last-known value shown after a failed or missed refresh, with its age, and only while it is still meaningful (see *Stale rule*) | `GrokPlan` after a temporary failure; **not yet for the Claude quota** | Grok stale label |
| boundary-uncertain | a window's first slot may include records before its start | none yet (P15) | none |
| unofficial | value from an undocumented endpoint | none yet | consent card text (#15) |

**Stale rule [direction accepted 2026-10-18; threshold open]:**
- **Within its window:** a quota value stays meaningful only within its own window. After a failed refresh, the last-known value is shown as *stale* with its age (`fetchedAt`) **while now < that limit's `resets_at`**.
- **After the reset:** the value is **unavailable**. No current value is inferred or extrapolated after a reset.
- **No reset time:** a limit with no `resets_at` has no proven window, so a failed refresh makes it unavailable.
- **Grok:** the same rule applies to the billing period. The last plan is *stale* only while now < `GrokPlan.periodEnd` (`Clients.swift:157`); after it, or with no `periodEnd`, it is unavailable.
  - **Today:** #21's stale plan isn't bounded by `periodEnd`, so the same gap as F-3 exists.
  - **Proposed:** track it with F-3 under #4.
- **Prices aren't "stale":** they change only by an explicit download (R6). The built-in snapshot's revision and `retrieved` date are shown instead.

**Polling cadence and failure behaviour, as observed in code (2026-10-18):**
- Quota limits refresh every 60 s (`main.swift:42`); local usage every 10 s (`main.swift:43`).
- Claude: a 429 backs off 300 s, and a 401 pauses 300 s (`ProviderServices.swift:264–265`, `claudeAuthPause`).
  - On any error the last limits are kept in `Store` and `claudeError` is set.
  - The **menu-bar gauge blanks** (`StatusRenderer.swift:71`).
  - The **popover still lists the last limits** with "⟨error⟩, showing data from ⟨age⟩" (`PopoverView.swift:465`), with no check against `resets_at`.
  - Only a missing login (`notConfigured`) clears them (`ProviderServices.swift:260`).
- Grok: a rejected key pauses 600 s (`grokAuthPause`). Temporary failures keep the last plan, labelled stale (#21).
- **Still undocumented:**
  - how long the Claude endpoint takes to answer, and its own rate limits;
  - what happens across sleep and wake;
  - whether a hidden gauge's paused polling counts as a miss.

**The threshold** (how many missed refreshes before *stale* shows) **is not finalized** until the points above are documented. A candidate for review is "two consecutive missed or failed refreshes".

## 4. Null versus zero [decided as a principle; rules proposed]
1. **Absent ≠ 0.** A counter, percent or cost that is missing, `null`, non-numeric, negative, fractional or too large is **absent**.
   - Absent counters make the operation `flawed` (P8).
   - An absent quota percent makes the quota **unavailable**.
   - An absent cost makes the cost **unknown** (R7).
2. **Real zero is a value.** `"output_tokens": 0`, `"costUsdTicks": 0` and `"percent": 0` are exact zeros.
3. **No data in a period** (no records at all) is exactly 0 tokens with `complete` coverage. But if any source that covers the period failed or is unread, the total carries **incomplete data**.
4. **Sums keep their worst status.** One unknown term makes a sum partial; all unknown makes it unavailable (`CostEstimate +`, `UsageSummary.combine`).
5. **Clamping hides data.** A derived counter that would be negative is a data conflict, flagged, not clamped to 0. Grok's `max(inputTokens − cachedReadTokens, 0)` was such a clamp; see F-1.

## 5. Current violations to fix (findings, not fixed here)
- **F-1, Grok local usage reads missing as 0.**
  - **Found:** `parseGrokUsage` used `int(_:)`, which returns 0 for an absent or non-numeric key (`Util.swift:176`) and reads booleans as 1 or 0. This covered `inputTokens`, `outputTokens`, `cacheCreationTokens`, `cachedReadTokens`, `modelCalls`, and `totalTokens` in the dedupe key. It also clamped `input − cached` at 0, and took an invalid `costUsdTicks` as a cost.
  - **Addressed in #80:**
    - Counters follow the P8 `Ledger.counter` rules. A missing or invalid one is left out and flags the turn (Grok's `DataCompleteness.flawed`); the valid ones count; a reported 0 is exact. An invalid cost is unknown (R7).
    - Cache reads above the input are a flagged conflict: only `min(input, cached)` counts, and **no input/cache split is claimed** for it. No view shows Grok's split, and Grok cost comes from `costUsdTicks`, not the price table.
    - Dedupe: a missing or invalid total never makes a new operation on its own. A copy without a total is matched to the kept turns at its `endedAt` on the counters valid in both: one agreeing turn, sharing a nonzero token counter, is its copy (the complete copy counts); disagreeing with all is a distinct turn; several agreeing turns, or no nonzero token counter to compare, merge it into the first and flag *uncertain identity* (`IdentityCoverage.ambiguous`, one per merged turn, §3).
    - Both notes on the usage card cover Grok (counts only). Tests: `GrokCounterCompletenessTests`.
  - **Limitations kept:**
    - On Grok an absent counter flags the turn; on Claude (P8) it doesn't.
    - An uncertain merge may drop a turn that was distinct (flagged; totals may be low).
    - The cost part of the key is R7's (`Dictionary.int`), reviewed and unchanged. **Collisions:** a missing, `null`, non-numeric or `false` cost keys like a reported $0, by design, so the costed copy can win; `true` and `1.5` key like a real 1 tick; other invalid numbers key by their truncated value (`-5` as −5). **Split:** a copy without a cost and a copy reporting a nonzero cost key apart and count twice (known issue in `GrokCounterCompletenessTests`, follow-up on #7).
    - A turn without a parseable `endedAt`, or a `usage.json` that isn't valid JSON, is still dropped without being counted as unread.
  - **Tracked in #7** (owner decision, 2026-10-18).
- **F-2, quota parsing reads missing as 0 %.**
  - `ClaudeLimitsClient.fetch` uses `l.double("percent") ?? 0` and `utilization ?? 0`.
  - `GrokClient` product `usagePercent ?? 0`.
  - The Grok top-level percent is already strict (#21).
  - **Proposed:** a missing percent makes that limit unavailable, kept with its reset time if present.
  - **Tracked in #4** (owner decision, 2026-10-18).
- **F-3, Claude quota staleness is inconsistent.**
  - On an error the menu-bar gauge blanks (`StatusRenderer.claudeGauge`, `StatusRenderer.swift:71`; test `claudeGaugeBlankOnOtherErrors`).
  - The popover keeps listing the last limits with their age, **even after their `resets_at`** (`PopoverView.swift:465`). That shows a value outside its window, which the rule below forbids.
  - **Direction (owner, 2026-10-18):** keep the last-known value with *stale* and its age while it's still within its original window; unavailable after its reset (§3 *Stale rule*).
  - Implementation waits for the stale threshold.

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
- **I-10:** an estimated cost carries its price revision. A provider-reported cost is never relabelled actual. Actual stays unavailable until a verified billing source exists.
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
- **Rule [accepted 2026-10-18]:**
  - Every Bedrock or Vertex estimate names its price source: the price table (LiteLLM), its revision, and the entry used. For example: *estimated at Anthropic list price (LiteLLM `<revision>`, entry `claude-…`); cloud-provider pricing differs*.
  - It is never described as an actual cloud-provider charge.
  - If no entry matches, the cost is unknown, never $0 (P17).
- **Enterprise / managed:** quota percentages may not be exposed for some accounts (#10 non-goal: don't assume). The quota is unavailable, never 0 %.
- **Actual spend:** no AWS Cost Explorer or Anthropic billing source is read, or planned without a separate threat-model review.

## 9. Golden tests already covering this contract
- `CostCompletenessTests`;
- `DataCompletenessTests`;
- `GrokCounterCompletenessTests` (F-1);
- `QuantityTests`;
- `IdentityCoverageTests`;
- `QuotaVisibilityTests`;
- `GrokErrorStateTests`;
- `LedgerFixtureTests` F01–F49;
- `TimeZoneTests`.

**New ones needed per slice:** F-2 (quota missing percent), P10 decision (F12), P15 boundary slot (F22).

## 10. Decisions and open points

**Accepted 2026-10-18:**
- missing is not zero, and a valid zero stays distinct;
- value statuses observed / estimated / unavailable, and actual only with a verified billing source;
- independent qualifiers;
- F-1 → #7, F-2 → #4;
- the F-3 direction;
- Bedrock/Vertex estimates name their price source and are never called charges.

**Open:**
1. The stale threshold, once polling cadence and failure behaviour are fully documented (§3).
2. Exact UI wording for each qualifier.
3. P10 display: a range or "≥ L" (ADR §D4.1).

**Waiting on #10:** P11, P15, status-line and OTel mappings, Bedrock and Enterprise coverage.
