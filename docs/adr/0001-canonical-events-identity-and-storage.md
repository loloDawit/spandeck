# ADR 0001: Canonical usage events, source adapters, identity and local storage

- **Status:** Partly accepted (design only; no code, schema or dependency change). Refs #9, drafted jointly with #7.
  - **Accepted by the owner on 2026-10-18:** the overall architecture (D2, D3 for the existing adapters, D8), plus D1, D6, P2, P5, P6, P12 and D7.
  - **Revised and awaiting acceptance:** P10 (§D4.1).
  - **Unresolved:** everything marked [blocked #10].
- **Date:** 2026-10-18
- **Companion:** [`METRIC_CONTRACT.md`](../METRIC_CONTRACT.md) (#7) defines what each number means and how its provenance is shown. This ADR defines how records become those numbers.

Each statement below is labelled:
- **[decided]**: already decided by the owner or by merged work; recorded here, not reopened.
- **[proposed]**: this ADR's choice, decidable from evidence in the repo; needs the owner's acceptance.
- **[owner]**: a product decision this ADR can't make.
- **[blocked #10]** / **[blocked #4]**: waits on provider research or the consent spec. No undocumented Claude, OTel, status-line or Bedrock capability is assumed.

## 1. Context: what the code does today

SpanDeck is a single SwiftUI menu-bar process (module `Headroom`, product `SpanDeck`). Usage comes from three places:

| Source | Code | What it yields | Persisted |
|---|---|---|---|
| Claude Code transcripts `~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects/**/*.jsonl` | `Ledger.scanClaude` / `readClaudeFile` / `ingestClaudeLine` | Assistant records with `message.usage`, `message.model`, `message.id`, `requestId`, `timestamp`; `usage.iterations` for sub-calls | Yes: `claude-ledger.json` v7, opaque keyed ids (R8) |
| Grok CLI `~/.grok/sessions/*/*/usage.json` | `Ledger.scanGrok` / `parseGrokUsage` | Per-turn tokens, `costUsdTicks`, `primaryModelId`, `endedAt` | No, re-read each launch |
| Opt-in quota endpoints | `ClaudeLimitsClient` (unofficial `api/oauth/usage`, #15), `GrokClient` (billing, #17) | Percent used, reset time, window kind, plan | No, in memory (`Store`) |

**The ledger is already a reconciler.** Its parts map onto this ADR's components:

| Current structure | Role in this ADR |
|---|---|
| `FileMark` (offset, size, ctime stamp, sampled anchor) | **Source cursor**: where an adapter resumes, and rewrite detection (P13) |
| `Seen` (slot, per-model `parts`, identity kind, flawed) | **Operation**: one model request's reconciled counts |
| `Link` (single id → pair, or `ambiguous`) | **Partial-identity index** (P4) |
| `State.slots` (15-min UTC slot → model → `Agg`) | **Aggregate index**: the query layer reads only this |
| `Unread` | **Unreadable-record register** (P7) |
| `Agg` | **Counter set**, with the P9 cache-write classification |
| `IdentityCoverage`, `DataCompleteness`, `QuantityUncertainty`, `CostEstimate.Coverage`, `PricingInfo.Source` | **Provenance facets** that already exist (see the contract) |
| `GrokTurn` + `uniqueGrokTurns` | **Grok adapter event** and its dedupe rule |
| `ClaudeLimits` / `LimitEntry`, `GrokPlan` | **Quota observations** |
| `Totals`, `UsageSummary`, `UsageSummary.combine` | **Query / analytics layer** |
| `Store`, `PopoverView`, `StatusRenderer`, `Hover` | **Display** |

The fixture register `Tests/HeadroomTests/Fixtures/Ledger/README.md` (P1–P17, F01–F49) is the de facto policy record. This ADR absorbs it (§6) rather than replacing it.

**Not present today:**
- no session, project, agent or tool dimension (subagent transcripts are found only by the `/subagents/` path, and not attributed);
- no status-line or OpenTelemetry code;
- no Bedrock or Vertex source;
- no per-record provenance (source, price revision and coverage are derived at summary time; #7 comment of 2026-10-15).

## 2. Decision drivers
- **Principles from `PRODUCT.md`:**
  - unknown is not zero;
  - one operation, one count;
  - no prompts, code, tool payloads, credentials or private repository names stored by default;
  - read-only observation;
  - a lightweight native app.
- **Constraints from `ARCHITECTURE.md`:**
  - in-process unless measurements or permission boundaries justify a collector;
  - no localhost server where in-process will do;
  - reversible integrations.
- **Merged security and privacy decisions:**
  - opaque HMAC ids under a per-install key (R8);
  - `0700` folder / `0600` files, no symlinks (`PrivateDirectory`);
  - cache and key excluded from backup (#70);
  - model ids validated, rejected ids kept as opaque `unknown#…` keys (#66);
  - separate SpanDeck identity with **no migration from Headroom state** (#11, audit 0008);
  - debug hover log compiled out of release builds (#68).
- **Accepted trade-offs:**
  - a version change discards and rebuilds the cache from transcripts still on disk (P12, owner on #9, 2026-10-16);
  - the fingerprint fallback for id-less records (P4).

## 3. Decisions

### D1. Process architecture: stay a single in-process app [accepted 2026-10-18]
**Choice:** keep one menu-bar process, with adapters, reconciler, store and query layer as in-process components behind protocols (as `Dependencies.swift` already does for Keychain, network, process and login item).

**Alternatives:**

| | In-process (choice) | Local daemon / LaunchAgent | XPC helper inside the app bundle |
|---|---|---|---|
| Install | none | a LaunchAgent plist, i.e. a login-time background process: the startup side effect `CLAUDE.md` forbids without consent and rollback | bundled, launched on demand |
| Collects while the app is closed | no; catches up from transcripts on launch (they persist) | yes | no |
| Permissions | the user's own files only | same files, plus a persistent process to secure | same |
| Faults | a crash takes the UI down, and the transcripts are re-read | separate lifecycle; needs IPC auth and version skew handling | crash isolation for the parser |
| OTel receive | would need a listener (localhost or socket) in the app | natural home for a listener | possible |
| Cost | lowest | highest: signing, notarization of a second executable, upgrades, offboarding | medium |

**Why:**
- Every source used today is a file that persists, so nothing is lost while the app is closed.
- `#8` hasn't measured overhead, so there's no performance case for a collector.
- A daemon adds exactly the startup and privileged-process side effects the threat model gates.

**Revisit triggers:**
1. #10 shows a valuable source that exists only as a live stream (an OTel exporter with no file sink).
2. #8 measures UI stalls from parsing that a queue can't fix.
3. Parser crash isolation becomes a security requirement. That would point to an XPC helper, not a daemon.

### D2. Canonical model: observations → operations → aggregates [accepted with the overall architecture, 2026-10-18]
Three layers, matching what the ledger already does, with the missing dimensions added as **nullable** fields:

1. **Observation:** one record as an adapter read it. It is never persisted raw. Fields:
   - `provider` (`anthropic` | `xai` | later `bedrock`, …);
   - `source` (`claude.jsonl` | `grok.usage-json` | `claude.quota-endpoint` | `grok.billing` | later `claude.statusline`, `claude.otel`);
   - `account?` (an opaque id of the credential or plan scope, when known);
   - `session?`, `agent?` (main | subagent | unknown), `project?` (opaque id only, see D7);
   - `messageID?`, `requestID?`;
   - `model` (validated id or `unknown#…`);
   - `observedAt` (the record's own timestamp) and `readAt`;
   - `counters` (an `Agg`, each counter **absent ≠ 0**);
   - `flags` (flawed, unread kind);
   - `cursor` (adapter-specific, e.g. `FileMark`).
2. **Operation:** one model request, the unit of "one operation, one count":
   - identity key and identity kind (`identified` | `incomplete` | `fingerprinted` | `ambiguous`);
   - home slot (P3);
   - reconciled per-model counters;
   - the set of sources that observed it (new; today implicitly `{claude.jsonl}`);
   - flawed flag.
3. **Aggregate:** per time slot × provider × model (× later account / session / project) counters plus provenance facets. The query layer and UI read only aggregates.

**Quota observations stay a separate kind, not usage** [decided in principle by #7's non-goals]. A percent of a plan window is never added to tokens or dollars, and never derived from them.

**Tool events** [blocked #10]: no current source records tool calls in a form SpanDeck reads. The model reserves `tool?` on an observation and stores counts only, never arguments or results (PRODUCT principle 1).

### D3. Source adapters [accepted for the existing adapters, 2026-10-18; the rest blocked #10]
An adapter has one job: turn bytes into observations with a cursor, without interpreting gaps. Proposed protocol (illustrative; no code in this ADR):

```swift
protocol UsageSourceAdapter {
    var source: SourceID { get }                      // e.g. .claudeJSONL
    func discover(since: Cursor?) -> [SourceUnit]     // files, sessions
    func read(_ unit: SourceUnit, from: Cursor?) -> (observations: [Observation], unread: [UnreadRecord], next: Cursor)
}
```

| Adapter | Status | Notes |
|---|---|---|
| Claude JSONL | exists (inside `Ledger`) | Extract as-is; P1–P17 move with it unchanged |
| Grok `usage.json` | exists (inside `Ledger`) | Fix missing-as-zero first (contract §5 F-1) |
| Claude quota endpoint | exists (`ClaudeLimitsClient`), opt-in, **unofficial** | Quota observations only; missing `percent` must become unavailable (contract §5 F-2) |
| Grok billing | exists (`GrokClient`), opt-in | Quota observations only |
| Claude status line | **[blocked #10, #4]** | Fields, cadence and identity overlap unknown. Installing a status-line command modifies user settings, so it needs #4's consent, preview and rollback contract |
| Claude OpenTelemetry | **[blocked #10, #4]** | Exporter and transport options, identity fields and nested-agent behaviour unverified; enabling it changes Claude settings |
| Bedrock / Vertex | **[blocked #10]** | Model ids already pass validation (`us.anthropic.…-v1:0`, `…@2025…`), but account, billing and actual-cost sources are unknown. No actual-cost source is assumed (contract) |

### D4. Identity and deduplication [P1, P2, P4, P5, P6, P12, P13 decided; P10 revised, gated; P11 blocked]
- **Scope [proposed]:** identity is scoped by `provider`. Claude and Grok operations are never matched to each other. Within a provider, by `account` once accounts are known; until then, one implicit account. This follows the owner's P4 caution against unioning identities across accounts and providers.
- **Within one source** (Claude JSONL): unchanged from the code.
  - P1: (message id, request id).
  - P4: one id alone in its own namespace, joined only to an unambiguous pair; a join is never undone. Neither id: a keyed fingerprint, flagged uncertain.
  - P13: rewrites are read again from the start; identity dedupe prevents double counts.
- **Repeated records of one operation (P2) [decided 2026-10-18]:**
  - Records are cumulative snapshots, so each counter takes its maximum and counts never decrease.
  - Cache writes are one quantity: the larger wins with its classification.
  - `Agg.reconciled` is commutative and associative, so arrival order and file grouping don't matter.
  - Evidence: F01, F02, F43, F44, and #61's re-review.
- **Last line without a newline (P6) [decided 2026-10-18]:** it is counted once its newline is written; until then the file is `pending`, not unread.
- **The record of past usage (P12) [decided 2026-10-18]:**
  - The transcripts on disk are the source for rebuilding the cache.
  - The cache keeps what it already counted, but a rebuild counts only what is still on disk.
  - The history lost when transcripts are gone is documented (`USAGE_CACHE.md`).
- **Same message id under another request id (P5) [decided 2026-10-18]:**
  - Distinct request ids stay separate operations, as today and in ccusage (F06).
  - Identity uncertainty is surfaced where appropriate. Implementation slice: count such pairs as a visible `IdentityCoverage` signal.
  - Revisit if #10 documents request-id semantics.
- **Same pair re-logged under another model (P10) [revised; implementation gated]:** see §D4.1.
- **Iterations semantics (P11) [blocked #10]:** the assumption stays and stays visible (F13).
- **Across sources (JSONL vs status line vs OTel) [blocked #10]:**
  - The rule is fixed now; the field mapping waits.
  - An operation observed by several sources counts once, under the strongest identity available.
  - Counters come from one **primary source per field**, by a fixed precedence written per source pair once #10 documents each source's fields. The other sources only add coverage and freshness.
  - If two sources can't be proven to describe the same operation, they're shown **side by side as separate views, never summed** (PRODUCT principle 3; contract invariant I-7).
  - Overlap examples (§7.4) are *proposed shapes*, not fixtures; #2's overlapping-source criterion stays open, as the owner decided.

### D4.1 P10: one pair, records under more than one model [revised for acceptance; gated]

**Owner direction (2026-10-18):**
- Retain the observations, and mark possible cross-model duplication as uncertain.
- Don't label possibly duplicated tokens as exact.
- Settle the accounting policy before implementing.
- No cache schema change in this PR.

**What the code does today (F12, re-examined):**
- `msg_12a` / `req_12a` is logged as `claude-test-1` [input 100, output 10], and 15 minutes later again as `claude-test-2` [100, 10].
- `count()` finds the pair in `seen`, finds no `claude-test-2` part, and adds the whole second snapshot under `claude-test-2` with 0 calls.
- The operation stays `identified`, so the total (495) carries **no uncertainty signal**: a possible double count is shown as exact. This is the case to fix.
- The fixture's own expected values (385) encode option (a), "the first model wins". That would be a silent policy choice, and this revision doesn't adopt it.
- The fixture stays a CI known issue until the policy is settled; this PR doesn't change it.

**Two hypotheses the records can't tell apart:**

| | H1: one request re-logged | H2: distinct model calls sharing the ids |
|---|---|---|
| Meaning | the same API request written again with another model label | two calls whose records reuse one message id and request id |
| Consistent with | P1 (a pair identifies one request) | a fallback or retry reusing ids (unverified; #10) |
| True tokens | `total(R)`, where `R` = per-field P2 reconciliation of all the pair's records across models | `Σ total(S_m)`, where `S_m` = the P2 reconciliation of the records under model `m` |
| True model | one of the models; which one is unknown | each model, its own `S_m` |

Hints such as identical counters (as in F12), or a later timestamp, suggest H1 but don't prove it. F12 is synthetic, and it's unverified whether Claude Code ever writes this case (fixture note; #10).

**Bounds that are justified, and their assumptions:**
- **A0 (already behind every total):** a model's last logged snapshot is its final count. Without A0, no bound below holds; the true value could exceed every snapshot.
- **A1 (P2's premise):** records never over-report. Each counter in a snapshot is at most the request's final value.
- **Token lower bound** `L = total(R)`: under H1 the truth is `R`; under H2 `Σ S_m ≥ R` field by field. So `L` holds under either hypothesis, given A0 and A1.
- **Token upper bound** `U = Σ_m total(S_m)`: under H2 it is the truth; under H1 the truth `R ≤ Σ S_m`. So `U` holds given A0, and given that no further call shares the pair unseen.
- **Exact part: none.** `L` is a bound, not an exact value. The pair's tokens are reported as **at least `L`, at most `U`**, never as one exact number.
- **Totals that include such pairs:** exact operations add exactly. Pairs add `[L, U]`, so a total is `[E + ΣL, E + ΣU]` with the qualifier *possible cross-model duplicate*.
- **Per-model attribution:** under H1 the pair belongs to one unknown model. A model's justified lower bound from the pair is therefore **0**, and its upper bound is `total(S_m)`. Model rows show `S_m` with the qualifier, never as exact.
- **Cost:** a cost bound is justified only when every model involved is priced and no P9 tier is unresolved or disputed. Then:
  - lower = `min(min_m cost_m(R), Σ_m cost_m(S_m))`;
  - upper = `max(max_m cost_m(R), Σ_m cost_m(S_m))`.

  Under H1 the price of the unknown model applies to `R`; under H2 each model's price applies to its own `S_m`; neither ordering is guaranteed. Otherwise the cost is **provisional** (no bound claimed), as with P9's disputed writes.
- **F12 under this rule:**
  - pair: `L` = 110, `U` = 220;
  - day total: [385, 495], marked *possible cross-model duplicate*;
  - `claude-test-1` and `claude-test-2` rows: each [0, 110] from the pair (`claude-test-2` also has its own exact 55 from `msg_12c`);
  - cost: provisional, since the test models are unpriced.

**Telling a re-log from distinct calls that are legitimately multi-model:** an operation already holds parts for several models when `usage.iterations` lists sub-calls (P11, F13). Those are distinct calls, not P10. The current `Seen.parts` doesn't record which part came from iterations and which from a re-log, so computing `[L, U]` needs a new per-operation marker. **That is a cache schema change, deferred to the gated implementation slice**, not this PR.

**Still to settle before implementing [owner]:**
1. Whether `[L, U]` is shown as a range, or as "≥ L" with a note.
2. The qualifier's wording.
3. Whether #10 evidence (does Claude Code write this case, and why) can retire H1 or H2.

### D5. Time [P3, P14, P16 decided; P15 blocked]
- **Slots [decided, #57]:** 15-minute UTC slots, so every local midnight in every current offset is a slot boundary. Day and week totals are computed from slots in the current `Calendar` at query time, so zone and DST changes need no re-index (F21, F46, F47).
- **Home slot (P3) [decided]:** an operation lives in the slot of its first record read.
- **Retention (P16) [decided]:** 32 days; the 30-day view starts at local midnight 29 days ago.
- **5-hour window start (P15) [blocked #10/#7]:**
  - Today: `resetsAt − 5h`, rounded down to a slot (`main.swift:148`).
  - Proposed contract rule: the window's first slot is shown as **boundary-uncertain** whenever the computed start isn't on a slot boundary, instead of being silently included (F22).
  - The rounding stays until real `resets_at` values are characterised.

### D6. Local storage: keep the JSON v7 cache now, plan SQLite for event-level data [accepted 2026-10-18]

| | Keep JSON v7 (choice now) | SQLite (system `libsqlite3`, no package) | Append-only event log |
|---|---|---|---|
| Fits today's data | yes: 32 days of aggregates plus one `Seen` per operation | yes | yes |
| Partial update | no: whole-file encode, every ≤10 min and on quit; the code calls it "the most expensive step" (unmeasured) | yes | yes (append) |
| Queries by session/project | poor | good | needs an index |
| Privacy controls | exist and tested: `0600`, symlink refusal, backup exclusion on temp-then-rename | must cover `-wal`, `-shm` and `-journal` files too (mode, exclusion, temp handling) | same as JSON |
| Migration | version check, discard, rebuild (accepted) | the same pattern: opaque keyed ids can't be migrated in place | same |
| Dependency | none | system library; a C API wrapper to review | none |

**Why:**
- Nothing measured shows the JSON cache failing.
- SQLite brings sidecar files that each need the R8/#70 protections re-proved.
- Event-level data (sessions, agents, per-source observations) is what would make queries matter, and that is blocked on #10 anyway.

**Revisit triggers:**
1. #8 measures encode or decode cost above a budget the owner sets.
2. Session or project dimensions are approved (D7) and need indexed queries.
3. A second Claude source lands and per-operation source sets make the cache grow beyond a set bound.

**Rules whatever the format [decided/proposed]:**
- no raw paths, ids, prompts or tool data;
- opaque ids under the per-install key;
- owner-only files;
- backup exclusion before a file is in place;
- 32-day retention;
- version change means discard and rebuild;
- *Clear cached usage data* removes every file of the store, sidecars included;
- no automatic migration from Headroom's folder.

### D7. Privacy of new dimensions [decided 2026-10-18]
- **Session and project:** a project is a folder name under `~/.claude/projects/`, derived from a working directory, which is often a private repository name (PRODUCT principle 1).
- **Decision:**
  - Session and project identifiers are **opaque by default**: keyed ids under the per-install key, so totals can be split but not named.
  - Private folder and repository names are **never persisted**.
  - Showing names in memory only (read from the path at display time) would need a separate owner approval and an explicit setting. It isn't part of this decision.
- **Agent:** main vs subagent can be derived from the existing `/subagents/` path layout, with no new data stored. That needs P11-style verification in #10 that subagent records aren't also included in the parent's usage.

### D8. Versioning and migration [accepted with the overall architecture, 2026-10-18]
- **Cache schema:**
  - `State.version` stays the single switch.
  - Any change to identity keys, slot meaning or counted semantics bumps it, which means discard and rebuild (P12 loss documented in `USAGE_CACHE.md`, as for v4→v7).
  - Additive optional fields that older builds ignore safely don't bump it (the #66 precedent).
- **Contract version:**
  - `METRIC_CONTRACT.md` carries its own version.
  - A change to a status's meaning or a null-vs-zero rule bumps it.
  - The UI copy for each status cites that version in tests.
- **Downgrade:** older builds discard a newer cache (existing behaviour, `USAGE_CACHE.md` *Downgrading*).
- **Headroom [decided]:** no migration, no reading of `Application Support/Headroom`.
- **Rollback of any slice:** revert the PR. The next launch rebuilds the cache from transcripts, and no user data outside the cache changes.

## 4. Component boundaries (target, introduced incrementally)

```text
 adapters (JSONL, Grok, quota clients; later status line / OTel)
   │  Observation + Cursor + UnreadRecord        no raw payloads past this line
   ▼
 reconciler (identity, P1–P17, cross-source precedence)
   │  Operation deltas
   ▼
 store (State v7 today: cursors, operations, links, slots, unread)
   │  aggregates + facets
   ▼
 query (Totals / UsageSummary + contract statuses)
   │
   ▼
 display (Store → SwiftUI, StatusRenderer, Hover)
```

**Testability:**
- Each boundary takes injected `now` and `Calendar` (as `Ledger` does) and works on synthetic fixtures.
- The reconciler is a pure function of the observations and the existing state, testable with no filesystem.
- The store is tested with `PrivateDirectory` fakes, as `BackupExclusionTests` and `LedgerCacheTests` do.

## 5. Failure modes

| Failure | Behaviour |
|---|---|
| Transcript deleted or compacted | Already-counted usage stays until it ages out; a rebuild loses it (P12, documented) |
| Rewrite outside sampled windows | Not detected (accepted limit P13); identity dedupe still prevents double counts on a later full re-read |
| Id-less streaming records | May overcount; flagged `fingerprinted` (P4, accepted) |
| Two sources disagree on counters | Primary-source-per-field rule; disagreement surfaced as quantity uncertainty, never averaged or summed |
| Quota fetch fails or the answer changes shape | A missing percent is unavailable, never 0 % (contract F-2). The last-known value may be shown with *stale* and its age only while its own window hasn't reset; after its reset time it is unavailable (contract §3, F-3). Today the menu-bar gauge blanks, while the popover keeps the last limits with their age and no reset check (contract F-3) |
| Cache unwritable / unexcludable | In-memory totals, issue shown (existing R8/#70 behaviour) |
| Clock or zone change | Slots are UTC; views recompute (P14) |

## 6. Policy register disposition

| Policy | Disposition |
|---|---|
| P1, P3, P4, P7, P8, P9, P13, P14, P16, P17 | decided / implemented; carried unchanged |
| P2, P5, P6, P12 | decided 2026-10-18 (§D4); P5's visible signal is an implementation slice |
| P10 | revised (§D4.1); implementation gated until the accounting policy is settled |
| P11, P15 | blocked on #10 (§D4, §D5) |

## 7. Synthetic examples (from existing fixtures)

### 7.1 Streaming growth: F01
Three records for `req_01` / `msg_01`, with output 50 → 80 → 120 and cache read 0 → 0 → 30.
- **Operation:** `identified`; home slot 2026-03-10T16:00Z; `claude-test-1`: input 100, output 120, cacheRead 30 → **250 tokens, counted once**.

### 7.2 Missing ids: F04
- `msg_04a` with no request id, three snapshots → one `incomplete` operation, 100 + 120 = **220**.
- `req_04b` with no message id, two snapshots → one `incomplete` operation, 5 + 20 = **25**.
- Neither id → one `fingerprinted` operation, **10**.
- **Total:** 255, with `IdentityCoverage{incomplete: 2, fingerprinted: 1}`. The UI says "Usage may be approximate: some records lack identifiers" (#55).

### 7.3 Re-log under another model: F12 (P10)
`req_12a` / `msg_12a` is logged as `claude-test-1` (110), then again as `claude-test-2` (110).
- **Today:** 220 counted for the pair, shown as exact. The day total is 495.
- **Revised rule (§D4.1):** the pair is at least 110, at most 220, with no exact part. The day total is [385, 495], marked *possible cross-model duplicate*.

### 7.4 Overlapping sources: *proposed shape only* [blocked #10]
- **Inputs:** a JSONL observation `{provider: anthropic, source: claude.jsonl, messageID: m, requestID: r, counters: …}`, and a hypothetical second observation of the same operation from another Claude source.
- **If that source carries both ids:** one operation, `sources: {claude.jsonl, X}`, counters from the per-field primary.
- **If it carries neither:** two separate views, never summed.
- No field names of X are assumed.

## 8. Implementation slices (each a small PR, after acceptance)
1. **Contract fixes, no schema change:** missing-as-zero in Grok local usage and in quota parsing (contract F-1, F-2), with fixtures. Folded into existing issues where they fit.
2. **P10, gated:** only once §D4.1's open points are settled. It needs a per-operation marker that separates re-logs from iteration parts, which is a cache version bump (discard and rebuild, P12).
3. **P15 boundary-uncertain window slot** (after #10 characterises `resets_at`).
4. **Extract adapters behind `UsageSourceAdapter`** with no behaviour change (fixtures F01–F49 identical before and after).
5. **Add `source` and the provider-scoped key to operations:** additive, then a version bump if keys change.
5a. **P5 signal:** count message ids seen under more than one request id as a visible identity qualifier.
6. **First new adapter** (status line or OTel, per #10's "smallest adapter" decision), behind #4's consent and rollback contract.
7. **Storage:** re-evaluate D6 with #8 data before slice 6 lands event-level data.

## 9. Decisions and open questions

**Accepted 2026-10-18:** D1, D6, P2, P5, P6, P12, D7. Unchanged: no Headroom migration, and the existing privacy safeguards.

**Open (owner):**
1. P10 (§D4.1): range vs "≥ L" display, the qualifier's wording, and acceptance of the bounds and their assumptions A0 and A1.
2. Contract wording and the stale threshold (`METRIC_CONTRACT.md` §3, §10).

**Unresolved, waiting on #10:**
- P11: `usage.iterations` semantics.
- P15: 5-hour window boundaries.
- Status-line and OpenTelemetry identity and field mappings.
- Bedrock and Enterprise observability coverage.

The overlapping-source fixture requirement (#2) stays open.
