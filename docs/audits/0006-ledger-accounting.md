# Ledger accounting correctness (#6)

**Issue:** #6 (M0, research). **Parent:** #2. **Code base:** `main` at `98c3ac3`, plus the test seam described in §6.
**Fixtures:** [`Tests/HeadroomTests/Fixtures/Ledger`](../../Tests/HeadroomTests/Fixtures/Ledger/README.md). **Tests:** `Tests/HeadroomTests/LedgerFixtureTests.swift`.
**Follow-ups:** #55, #56, #57, #58. Open policy questions are posted on #7, #9, #10 and #58.
**Update:** #55 was fixed in #60 (§8). #58 was fixed in #61 (§9), including P9 as [decided on #58](https://github.com/loloDawit/spandeck/issues/58#issuecomment-6226520316). Sections 1–7 describe the ledger before those fixes, as audited.

This report covers Claude transcript accounting in `Ledger.swift`: identity, deduplication, incremental reading, the cache and time buckets. Grok usage files are covered only where R7 already tested them. Pricing values and pricing integrity are out of scope (#7, #11).

Evidence labels:
- **[code]**: read in the source.
- **[test]**: shown by a test, local `swift test` only.
- **[assumption]**: believed, not verified.

No real transcripts, accounts or network access were used. CI was not run.

## 1. Summary

| | Count | Fixtures |
|---|---|---|
| Behaves as expected | 16 fixtures | F01–F03, F06–F09, F11, F13, F14, F17–F20, F23, F24 (F02 and F06 assume a policy still open) |
| Confirmed defects | 4 issues, 6 fixtures | #55 (F04, F05, F15), #56 (F16), #57 (F21), #58 (F10) |
| Behavior differs from a proposed policy | 2 | F12 (#9), F22 (#7) |

- **Most important finding (#55):** records that lack a message id or a request id are counted again every time they are read. That includes streaming re-logs, re-reads after a rewrite, and restored files. The result also depends on refresh timing, so the same files can produce 590 or 810 tokens (F15).
- **What passed:** for records that have both ids, the totals were correct in these scenarios, and identical in all three refresh modes (tailing, full scans and relaunches):
  - streaming growth;
  - files duplicated across resumes, forks and subagents;
  - partial lines, compaction, rotation and deletion;
  - both DST transitions;
  - an unsaved cache after a crash.
- **Consistent but wrong:** an in-place overwrite (#56) gives the same wrong total in every mode. Consistency across modes doesn't prove correctness.
- **Modes don't always agree:** F15 (records without ids, deleted and restored) deliberately records different totals per mode: 590 when only tailing, 810 after a full scan or a relaunch. The expected result, 370, is the same in every mode (#55).
- **Not yet trustworthy for analytics:**
  - totals that include records without ids (#55);
  - transcripts overwritten in place (#56);
  - daily totals in half-hour time zones (#57);
  - totals that silently skipped unreadable records (#58).

## 2. How the ledger works

### 2.1 Streaming counters
- **[code]** `Ledger.swift:692-713`. A record is an `assistant` line with `message.usage` and a parseable `timestamp`. Its identity is `HMAC(message.id, requestId)`.
- **[code]** On a repeat, only the field-wise growth over what was stored is added: `Agg.growth`, clamped at 0, at `Ledger.swift:22`. It is added to the hour of the identity's first record, and the stored snapshot becomes the field-wise maximum (`Agg.maxed`).
- **[code]** So, per identity, every field counts its largest value; totals never go down, and record order doesn't change them.
- **[test]** F01, F02 and F03. The hour attribution in F03 and F23 depends on which record is read first, which is file order.
- **[assumption]** Claude Code's repeated records are cumulative snapshots of one response. The field-wise maximum is a policy (P2), not a documented contract.
- **[code]** Sub-calls under `usage.iterations` with a different model and a type other than `message` become extra parts under their own model, with one call each (`Ledger.swift:685-690`).
- **[test]** F13.
- **[assumption]** The top-level usage excludes those sub-calls (P11). This is unverified against Claude Code.

### 2.2 Deduplication of messages and requests
- **[code]** The dedupe map `seen` is global across files, so resumed sessions, forks and subagent transcripts count each identity once.
- **[test]** F07 (9 records → 4 operations) and `LedgerCacheTests.distinctInputsStayDistinct`.
- **[code]** With either id missing, the record is added in full and nothing is remembered (`Ledger.swift:692-696`).
- **[test]** F04 and F15 (#55).
- **[code]** An empty string is accepted as an id.
- **[test]** F05: all records with `""` ids collapse into one operation (#55).
- **[code]** The same message id under another request id is another operation.
- **[test]** F06. This matches ccusage, but it is a policy (P5).
- **[code]** A re-log of one identity under another model adds that model's full counts, with no extra call.
- **[test]** F12, with a baseline. Whether Claude Code ever writes this is unknown (P10, #9).

### 2.3 Partial JSONL records
- **[code]** `ingestClaudeFile` (`Ledger.swift:653`) parses only newline-terminated lines and stops its offset after the last newline. A partial last line is read once it is complete.
- **[test]** F08 and `LedgerCacheTests.partialAndRewrittenFiles`. A final line that never gets a newline is never counted (P6, policy).
- **[code]** Lines are pre-filtered by the exact bytes `"usage":{` (`Ledger.swift:662`). A valid record written as `"usage": {` is skipped.
- **[test]** F10 (#58). **[assumption]** Claude Code writes compact JSON.
- **[code]** The following records are dropped and the offset moves past them, so they are never retried: malformed JSON, invalid UTF-8, a timestamp without a zone, and a missing timestamp. The ledger keeps no count of unread records.
- **[test]** F09 and F23 (#58).
- **[code]** Counters are read with `NSNumber.intValue`, defaulting to 0 (`Util.swift:147`):
  - a missing or non-numeric counter becomes 0;
  - a JSON boolean becomes 0 or 1;
  - a negative counter is accepted.
- **[test]** F10, where the month total is −839 (#58). Booleans and strings were not separately tested.

### 2.4 Incremental file offsets
- **[code]** The cache stores one byte offset per file id (`FileMark`).
- **[code]** A **full scan** (`scanClaude`, `Ledger.swift:569`) works as follows:
  - it runs on launch and then at least 5 minutes apart;
  - it reads files whose size differs from the offset and that were modified in the last 32 days;
  - it restarts at 0 when the file is shorter;
  - it forgets the offsets of files that disappeared, or whose modification time is now older than 32 days. Such a file is read from 0 if it is touched again; dedupe keys stop records with ids from being counted twice.
- **[code]** Between full scans, `discoverNewFiles` and `tailHotFiles` (`Ledger.swift:614-646`):
  - read files modified in the last 2 hours, one level deep in project folders, plus `subagents/`;
  - do not forget missing files.
- **[test]** F14 (compaction), F17 (rotation) and F18 (deletion and restore) agree across all modes.
- **Gap:**
  - a same-size overwrite is never re-read;
  - a larger in-place overwrite resumes at the old offset, inside the new content.
- **[test]** F16 (#56).
- **[test]** Records without ids show that tail and full-scan modes can disagree, because only a full scan forgets the offset of a deleted file (F15).
- **[test]** `unsavedProgressIsNotCountedTwice`. The cache is saved on a ledger's first refresh, at most every 10 minutes after that, and on quit. A ledger restarted from an older cache re-reads from that cache's offsets and reaches the same totals. Offsets, hours and dedupe keys are saved as one snapshot.

### 2.5 Hourly and daily totals
- **[code]** Tokens are stored per whole UTC hour (`Int(epoch / 3600)`, `Ledger.swift:682`) and per model.
- **[code]** `summarize` (`Ledger.swift:810`) assigns each hour to the local day containing the **start** of that hour (`Ledger.swift:825`). Today, the last 7 days and the last 30 days are calendar days in the current time zone, read on every summary.
- **[test]** F19 and F20: both DST transitions in Los Angeles are correct, including the 23-hour and 25-hour days.
- **[test]** F21: wrong in half-hour and 45-minute zones (#57).
- **[code]** The 5-hour window rounds its start down to the hour (`Ledger.swift:815`), so it can include up to 59 minutes before the window start.
- **[test]** F22. It is exact only if the provider's reset time is on the hour, which is unverified (#7).
- **[code]** Hours and dedupe keys older than 32 days are dropped. The display covers 30 days.
- **[test]** F24, including the exact edges.

### 2.6 Unknown models, missing ids and cost coverage
- **[code]** A missing model is stored as `"unknown"`. `<synthetic>` records are ignored.
- **[test]** F09.
- **[code]** Cost coverage (R7) is complete, partial or unavailable. A model without a price is unknown, never $0.
- **[test]** F09, F11 ($0.001366 known at Haiku 4.5 list prices, worked out by hand), F12, F13 and `CostCompletenessTests`.
- **Gap:** identity coverage has nothing comparable. A total that includes records without ids, or that skipped unreadable records, looks exactly like a precise total (#55, #58).

## 3. Fixture matrix

The rows are those of #6. "All modes" means tail, full scan, relaunch and rebuild.

| #6 row | Fixtures | Result |
|---|---|---|
| Repeated streaming updates, growing and non-monotonic counters | F01, F02, F03, F13 | Pass (F02 assumes policy P2) |
| Missing request ids; stable and unstable message ids; ambiguous identity | F04, F05, F06, F15 | **Defect #55**; F06 assumes policy P5 |
| Duplicates across files, forks, resumes, overlapping sources | F07 | Pass (Claude only; Claude + Grok overlap is not deduplicated by design, R7) |
| Partial JSONL line, later completion | F08 | Pass |
| Invalid UTF-8 and malformed records | F09, F10 | Not counted, as expected; **defect #58**: no trace, negative and spaced records |
| Truncation, overwrite, rotation, deletion | F14, F15, F16, F17, F18 | Truncation, rotation and deletion pass for records with ids; **defect #56** (overwrite); **#55** (records without ids) |
| Cache reload, reindexing, version migration | Every fixture's relaunch and rebuild runs; `unsavedProgressIsNotCountedTwice`; existing `LedgerCacheTests` | Pass (version 3 → 4, foreign-key and corrupt-cache handling are covered by `legacyCacheReplaced`, `cacheWithOtherKeyRebuilt`, `unusableCacheRebuilt` and `CostCompletenessTests.ledgerCacheCompatible`) |
| Time zone and DST boundaries, shifted timestamps | F19, F20, F21, F23 | DST passes; **defect #57** (half-hour zones) |
| Model changes and iterations | F12, F13 | F13 passes; F12 differs from policy P10 (#9) |
| Input, output, cache-read, 5m and 1h write breakdowns | F10, F11 | F11 passes (P9 for inconsistent breakdowns); **#58** (breakdown without total) |
| Hourly and daily totals, 30-day window, 5-hour window | F03, F19–F22, F24 | Pass except #57 and F22 (#7) |

## 4. Findings

### Confirmed incorrect (filed)

| Id | Issue | What happens | Fixtures | Impact |
|---|---|---|---|---|
| L1 | #55 | Records without a message id or request id are added every time they're read. Empty-string ids merge different operations | F04 (600 vs 255), F05 (170 vs 320), F15 (590 or 810 vs 370) | Inflation, and an undercount in the empty-id case; depends on refresh timing. **Fixed by #55 (§8)** |
| L2 | #56 | An in-place overwrite of the same or larger size is taken for an append | F16 (480 vs 714) | Undercount; probably rare with Claude Code |
| L3 | #57 | Usage is assigned to local days by whole UTC hours | F21 (today 4 vs 6) | Wrong day, every day, for half-hour zones |
| L4 | #58 | Negative counters are subtracted; a breakdown without a flat total is dropped; `"usage": {` is skipped; unreadable records leave no trace | F10 (−839 vs 494), F09 | Wrong totals on unusual input; incomplete totals look complete. **Fixed by #58 (§9)** |

### Ambiguous, needs a policy decision

| Policy | Question | Fixtures | Tracked |
|---|---|---|---|
| P2 | Field-wise maximum of repeated records, or the last record? | F02 | #9 |
| P5 | Is the same message id under two request ids one operation or two? | F06 | #9 |
| P6 | Count a complete JSON object that has no final newline? | F08 | #9 |
| P9 | Which side wins when a cache breakdown and its total disagree? | F11, F42 | **Decided on #58**, implemented in #61 (§9) |
| P10 | A re-log under another model: double count (today) or one operation? | F12 | #9 |
| P11 | Do top-level usage counts exclude `iterations` sub-calls? | F13 | #10 (needs a real Claude Code sample) |
| P12 | After a rebuild, history only on disk is lost (F14: 710 → 340). Acceptable, or should the cache be the record? | F14, F15, F16 | #9 |
| P15 | Is the 5-hour window start always on the hour? | F22 | #7 |

### Missing test coverage (not added here)
- **Real Claude Code record shapes.** The fixtures use the fields the ledger reads, as believed. A redacted, consented sample would confirm the identity, `iterations` and streaming assumptions (#10).
- **Large files and many files.** These are left to #8. The fixtures prove correctness, not speed.
- **Booleans and strings as counters.** Read as 1 or 0 before #58; now covered by F36 (§9).
- **Grok `usage.json`.** Only the R7 cost tests cover it. Its content-based dedupe key is noted on #7.
- **Claude + Grok overlap.** By design they are summed as separate providers. No source overlap test exists.
- **Concurrent writers.** A file appended to while it is being read was not simulated.
- **A new file in an existing project folder whose modification time didn't change.** The fixtures pin all times, so the tail discovery heuristic itself isn't exercised against real filesystem times.

## 5. Recommended fixes, by impact
1. **#55, identity of records without ids.** Most likely to inflate real totals, and it makes results depend on timing. It needs the identity policy from #9 (P4) and a cache version bump.
2. **#58, record validation and an "unread records" count.** Cheap. It turns silent gaps into visible coverage, in line with #7's "missing is not zero".
3. **#57, day attribution.** Correct for most zones, but wrong every day for affected users. Finer buckets change the cache format, so do it together with #55's version bump.
4. **#56, overwrite detection.** Undercount only, and probably rare. It needs file identity or a fingerprint, measured against #8.

None of these changes is made in this PR.

## 6. Test seam
`LedgerFixtureTests` needs a fixed clock and calendar, plus the hour buckets. This PR therefore changes `Ledger.swift` in one place, with no behavior change:
- `init` takes `now` and `calendar`. They default to the real clock and to `Calendar.current`, read on every use as before.
- `claudeHourlyUsage(completion:)` reads the buckets on the ledger queue. The app doesn't call it.

Everything else is test-only:
- `Package.swift` declares `Fixtures` as a resource of the test target;
- `TestClock` gains a start date;
- the fixtures and the suite.

The tests await completion handlers and never block a thread or sleep (cf. #46).

## 7. Commands and results
On Apple Silicon, macOS 26.5, Xcode 26.6, all local:

| Command | Result |
|---|---|
| `swift build` | OK, 0 warnings |
| `swift test` | 191 tests in 17 suites pass, with 39 known issues (the expected results of §4), 1.2 s |
| `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --no-parallel` (CI's mode) | 4 of 5 runs: 191 pass, 39 known issues, about 6.2 s. 1 run: `GrokConsentTests.consentWithdrawnDuringKeyReadSendsNothing(reenable: true)` failed (a Grok request was sent). That test's fake blocks on a semaphore for up to 2 s, the pattern tracked in #46. It is unrelated to the ledger and is noted there |

**Not run:**
- hosted CI;
- other macOS versions or Intel;
- the app itself.

A known issue that stops failing makes its test fail. That signals the fixture should be updated when a fix lands.

## 8. Update: the #55 fix
**Branch:** `fix/55-missing-id-dedupe`, implementing the [P4 decision on #9](https://github.com/loloDawit/spandeck/issues/9#issuecomment-6220268374). **Status:** merged in #60.

### 8.1 What changed
- **[code]** An id that is missing, empty, blank or not a string is absent. Record identity, in order:
  1. both ids: the pair, as before;
  2. one id: that id in its own namespace. A record joins the one pair that carries its id, and a new pair takes over the partial groups it completes. When two pairs carry the id, the record is counted on its own as ambiguous;
  3. neither: a keyed fingerprint of timestamp, model and counters.
- **[code]** Every identity group is counted by kind per hour: identified, incomplete, fingerprinted, ambiguous. A group is one logged message with its streamed copies, not a call (F13: 2 operations, 1 group). The fingerprint uses the parsed instant and counter values, not their spelling. The counts reach `Totals.identity`, and the Token usage card shows *"Usage may be approximate: some records lack identifiers."* when any logged message in the 30 days isn't identified by both ids. This is separate from cost coverage (R7).
- **[code]** The cache is now version 5, and a version 4 cache is deleted and re-indexed (`docs/USAGE_CACHE.md`).
- **[test]** F04, F05 and F15 now pass in all modes and on rebuild, with no baseline: 255, 320, and 370 (rebuild 220). The modes now agree on F15.
- **[test]** New fixtures:
  - F25: one id first, then the pair;
  - F26: pair first, then partials in another file;
  - F27: two pairs sharing one id;
  - F28: conflict after a join;
  - F29: both partials, then the pair;
  - F30: empty, blank and non-string ids;
  - F31: no-id replay across files and relaunches;
  - F32: identical fingerprints;
  - F33: no-id streaming;
  - F34: one no-id record written with different time zones and number spellings;
  - F35: F28's records read in two other orders.
- **[test]** The other 24 fixtures are unchanged, except that F13 now also asserts its identity count.

### 8.2 Limits that remain (accepted on #9, shown as uncertainty)
- **Records without ids:**
  - a streamed message with no ids overcounts, since each snapshot has its own fingerprint (F33);
  - two distinct logged messages with identical records count once (F32).
- **Arrival order:** a join is never undone. If a second pair with the same id arrives after the join, later records with only that id are counted on their own (F28). The result is deterministic for a given read order, but another order can give a different total. F35 pins this: F28's four records give 660 when the pairs come first and 650 when a partial joins before the conflicting pair, against 660 in F28's order. The two pairs stay separate in every order, and every order is marked uncertain. F28 and F35 keep each scenario in one file so the order is fixed. F26 and F29 are worked out so that either file order gives the same total, but their rebuild checks only the order the file system returns.
- **Scope:** identity covers every Claude transcript under the scanned roots. There is no account scope, as before. Grok turns are not covered by identity coverage.
- **Lost history:** a one-time re-index loses usage whose transcripts are gone.

### 8.3 Cost (synthetic, see #8)
The measurements used a debug build on an Apple M2 Pro, with three cases running concurrently, so only the relative numbers matter. The data was 50,000 logged messages (identity groups), each with two streamed snapshots, spread over 100 files.

| | Before (`main`) | After |
|---|---|---|
| Cache size per logged message | 147–163 bytes (records without ids weren't stored at all) | 377–380 bytes |
| First index (100,000 lines) | 11.8–16.9 s | 15.9–19.8 s |
| Relaunch, cache load only | 0.30–0.42 s | 0.79–1.24 s |

Lookups are dictionary operations per record, with no scan of past identities.

## 9. Update: the #58 fix
**Branch:** `fix/58-ledger-input-validation`, implementing the contract proposed on [#58](https://github.com/loloDawit/spandeck/issues/58#issuecomment-6225591077). **Status:** in review, not merged. A follow-up on the same PR implements the [P9 decision](https://github.com/loloDawit/spandeck/issues/58#issuecomment-6226520316) and makes overflow recoverable (§9.4).

### 9.1 What changed
- **[code]** Counters (P8): a counter is valid when it is a non-negative integral number below 2^53. Absent and `null` report nothing. Anything else is left out, never read as 0 or another number:
  - a negative, a fraction, a string, a boolean, an object or an array;
  - a number too large, or not finite.

  The record's valid counters still count, and its identity group is marked *flawed* for good, through streamed growth and #55 joins. Iterations follow the same rules; a non-object element no longer drops every iteration.
- **[code]** Overflow: sums saturate, and a held sum is flagged and rebuilt rather than subtracted from (§9.4). Before, a counter of `1e30` made the test process trap (SIGTRAP), so a crafted transcript could crash the app.
- **[code]** Cache-write breakdown: used when the flat total is absent, `null` or invalid. Mismatches follow P9 (§9.4).
- **[code]** Pre-filter: the quoted key `"usage"`, then optional spaces, tabs or CR, then `:`. Before, it needed the exact bytes `"usage":{`. It can't match `\"usage\"` inside text or `"usage"` as a value.
- **[code]** Data completeness (P7), a new `DataCompleteness` on every total, separate from identity, cost coverage and cache issues:
  - **unread records, by kind:** `malformed` (not a JSON object, or invalid UTF-8) and `undated` (no usable timestamp) have no period and are reported with every period; `invalidUsage` (usage isn't an object) is dated;
  - **flawed groups,** in their hour;
  - **pending files,** whose last line is still being written; not a warning.

  Unread lines are kept as `HMAC(key, "unread" | line bytes)` with a kind and an hour, never their text. So a rescan, a truncating rewrite, a rename or a copy reports them once, and they stay reported after deletion, like counted usage (P12).
- **[code]** The Token usage card shows *"Some usage records couldn't be read. Totals may be incomplete."* with a detail, as a tooltip and for VoiceOver. The identity note (#55) sits under it, in one small list of one-line notes.
- **[code]** The cache is now version 6. A version 5 cache is deleted and re-indexed (`docs/USAGE_CACHE.md`).
- **[test]** F10 now passes in every mode and on rebuild, with no baseline: 494 tokens, 1 flawed. F09 now asserts 2 malformed and 2 undated, F08 1 pending, and F23 2 undated. The other fixtures are unchanged, and every fixture now also asserts completeness: nothing unread unless stated.
- **[test]** New fixtures:
  - F36: invalid counters;
  - F37: cache-write sources;
  - F38: JSON whitespace, key order and ignored records;
  - F39: unread records through rewrite, rename, copy and deletion;
  - F40: appended unread records, also used for the crash-before-save test;
  - F41: flaws through streaming and #55 joins.

  Unit tests cover counter values, the pre-filter, periods, retention, saturation, the note copy, and the cache's contents and migration.
- **[test]** Against `main`'s ledger:
  - F10 gives −839, not 494;
  - F37 gives 162, not 631;
  - F38 gives 44, not 165;
  - F41 subtracts its negatives;
  - F36 traps.

  Twelve mutations of the fix (exact needle, negatives valid, no breakdown fallback, unread not deduplicated, flaws not sticky, flaws lost in an uncount or a join, pending never cleared, unread not pruned, timestamps checked before ignoring, no saturation, strict iterations) each fail at least one test.

### 9.2 Limits that remain
- **Field-wise growth across tiers (P2):** a streamed message whose cache writes move between fields, for example from disputed to resolved tiers, keeps each field's maximum, so its cache writes can be overcounted. The same was already true between the 5-minute and 1-hour fields.
- **Unread counts are distinct lines:** identical broken lines, in one file or several, count once. The note says so.
- **Grok** usage files aren't validated: their counters are read as before and could still overflow. Grok is out of #58's scope.
- **A line cut off before its `"usage"` key** looks like any other line and isn't reported.
- **A broken line rewritten with different bytes** is reported again, until the old entry ages out (the F33 analogue).
- **A file that can't be read at all** (permissions, I/O) is still not reported. That is file-level, not record-level, and may belong to #7.
- **Partial counts:** an undated record whose message also has a valid copy is reported as unread although the message counted. A flawed group stays flawed even if a later copy has every counter valid. Both err towards saying less is known.
- **Absent counters** report nothing and aren't flaws. Claude Code omits cache counters routinely, so "missing" here means "not reported", not "unknown".
- **Pending files** aren't shown. A transcript whose writer crashed mid-line stays pending forever, which is P6.

### 9.3 Cost (synthetic, see #8)
Debug build, Apple M2 Pro, one run at a time. The data is 30,000 logged messages in 100 files: 120,000 lines and 151 MB. Each message has a ~1 KB user prompt, two streamed assistant snapshots, and a ~3 KB tool result quoting `\"usage\"` escaped. Every 50th message is written `"usage": {`.

| | Before (`main`), 3 runs | After, 3 runs |
|---|---|---|
| First index | 6.26–8.11 s | 6.77–8.85 s |
| Tail, 900 lines appended to a hot file | 0.037–0.043 s | 0.040 s |
| Relaunch (load and first refresh) | 0.355–0.376 s | 0.334–0.362 s |
| Cache size | 11.21 MB | 11.43 MB (+2.0%: the 600 spaced messages are now counted) |
| Tokens | 21,256,200 | 21,629,700 (+373,500, exactly the spaced messages) |
| Pre-filter alone over 147 MB, 3 rounds | 0.123–0.125 s | 0.133–0.134 s, the same 60,000 lines matched |

The index time ranges overlap. The pre-filter adds about 0.01 s per 150 MB and parses no extra lines of this mix. Per-message cache size is unchanged, since a group without a flaw stores no flag.

### 9.4 Follow-up: P9 and recoverable overflow
- **[code] P9:**
  - **Sources agree:** the breakdown's tiers are used.
  - **Otherwise, with a valid flat total:** the flat total is the quantity and its tier is *unresolved*. Its cost is a *minimum* at the cheaper tier's rate. That is a lower bound, assuming the flat total is right, and is kept apart from known cost, so the model's cost is partial.
  - **Breakdown above the flat total** (an explicit flat 0 included): the excess is counted *provisionally*, as `disputed`. It is unpriced and claims no bound.
  - **Invalid or unreadable breakdown:** an invalid tier never counts as matching, and an unreadable breakdown leaves the tier unresolved.
  - **Unchanged:** a flat total with no breakdown is still 5-minute writes.
  - **Without a price,** everything is unknown, as before.

  Both new quantities are optional fields of each hour's and each operation's counts. So they follow growth, #55 merges, relaunches and rebuilds by the same path as tokens.
- **[code] Four independent dimensions on every total:**

  | Dimension | Field | What it says |
  |---|---|---|
  | Identity | `identity` | How the records were told apart (#55) |
  | Completeness | `completeness` | Records that couldn't be read (above) |
  | Token quantity | `quantity` | Provisional (`disputedTokens`) or held (`saturated`) counts |
  | Price coverage | `cost` | Exact `known`, `minimum` for unresolved tiers, and unknown tokens: `unknownTokens` without a price, `disputedTokens` in conflict |

  - **Card:** one line per dimension that applies. *"Some token counts are provisional. Totals may be over- or understated."* sits between the completeness and identity notes.
  - **Costs:** `≥` amounts add the minimum to the known part. The cost note names "cache writes of uncertain tier or amount" apart from "no price". §9.5 narrows `≥` to totals without disputed tokens.
- **[code] Recoverable overflow:**
  - `CostEstimate` sums saturate.
  - A sum held at `Int.max` sets `quantity.saturated`. The flag is derived from the stored buckets, so it survives a relaunch.
  - When a #55 merge takes back an operation from a held bucket, `uncount` rebuilds the bucket from the operations still in `seen`, which always sum to it, instead of subtracting from a value that lost its true amount.
- **[test]**
  - **F11:** still 1817 tokens. 300 tokens are tier-unresolved. The known cost is $0.000991, plus a $0.000375 minimum: together the former $0.001366, now a lower bound. Haiku is partial.
  - **F42 (new):** both mismatch directions, an explicit flat 0, an absent flat total, an invalid tier and an unpriced model, through streamed growth and a #55 join.
  - **F36, F37:** an invalid or unreadable breakdown now leaves its flat total tier-unresolved. Their token totals are unchanged.
  - **Always checked:** every fixture checks `tiers` and `quantity`.
  - **Unit tests:** held buckets over two models and two hours, a held sum followed by a #55 merge (exact again afterwards), and the cost and note semantics.
- **[test] Against the old behaviour:**
  - plain `CostEstimate` sums trap;
  - the old `uncount` fails the merge test;
  - the old P9 rule fails F11, F37 and F42.

  Six more mutations each fail a test: the minimum taken as known, disputed tokens dropped, an invalid tier matching, `subtract` ignoring tiers, disputes not summarized, and a minimum at the 1-hour rate.

### 9.5 Follow-up: streamed reclassification, invalid tiers and provisional costs
The owner's re-review of `e48ab95` found three P9 gaps; the corrections follow the policy approved on #61.
- **[code] One cache-write quantity per operation.** `Agg.growth`/`maxed` took the maximum of each cache-write field apart, so a record whose cache writes moved from tiered to tier-unresolved counted them twice (flat 100: 50+50 then 30+30 gave 200). `Agg.reconciled` replaces both:
  - other counters keep their largest value (P2);
  - the larger cache-write quantity wins with its classification, so a reclassification alone adds nothing;
  - at equal quantity the less certain wins (disputed > tier-unresolved > tiered), and two tier splits that disagree leave the whole quantity tier-unresolved instead of pricing whichever arrived first;
  - the rule is commutative and associative, so arrival order, rescans and #55 merges reach the same operation, cost coverage included.

  `count` adds the signed difference to the bucket. It can't take a bucket below 0, because a bucket is the sum of its operations' parts and each part's counters are non-negative. A held (`Int.max`) bucket is rebuilt from `seen` instead of reduced, through the helper `uncount` now shares.
- **[code] Invalid tier without a flat total.** The valid tiers still count but are tier-unresolved (a minimum), and the message is flagged. Before, `{5m: "x", 1h: 25}` priced 25 exact 1-hour writes, and the cost read as complete.
- **[code] Provisional costs.** A total with disputed tokens has no defensible lower bound: the flat totals behind its minimum are themselves in conflict. It is shown as `~$x`, rounded rather than truncated and kept to one significant digit below a cent (F42 reads `~$0.0008`, not `<$0.01`). Its detail starts "Provisional estimate, not a lower bound", and calls the minimum "$y more … if the logged cache-write totals are right". The chart marks such days "~" instead of "?". VoiceOver reads "about $x, provisional" and "at least $x", not the symbols, for tiles, provider rows, the 5-hour window, models and chart marks. The cost legend and the pricing rule define `~`. `≥` stays for tier-unresolved minimums alone (F11).
- **[test]**
  - **F43, F44 (new):** the same streamed records in opposite orders. They cover:
    - tiered ↔ tier-unresolved, tiered ↔ disputed and tier-unresolved ↔ disputed;
    - two splits of one quantity;
    - growth across a class change (disputed 300 → tiered 350 adds 50);
    - an invalid tier priced with and without a flat total;
    - a #55 join of partials with different classes.

    Both end on identical expectations (tokens, tiers, known and minimum cost, coverage, quantity, flaws, identity) in tail, full-scan, relaunch and rebuild modes.
  - **Unit tests:**
    - every order and grouping of six records reconciles to one result;
    - each transition both ways;
    - a reclassification inside a bucket held at `Int.max` followed by a #55 join, which is exact again afterwards;
    - the visible and spoken cost strings, the legend and the chart marks.
  - **F11, F37, F42:** unchanged and passing.
- **[test] Against the old behaviour:** six mutations, each caught:
  - field-wise max of cache writes;
  - an invalid tier priced without a flat total;
  - `≥` while disputed;
  - a held bucket reduced instead of rebuilt;
  - the first tier split kept;
  - the first record kept at equal quantity.

### 9.6 Follow-up: disputed tokens of unpriced models
The re-review of `5f48f65` found that a model without a price returned all of its tokens as unknown. Its disputed tokens were lost to cost coverage, so a priced model without a conflict next to an unpriced one with a conflict showed `≥`. The quantity note said the counts were provisional at the same time.
- **[code]** Without a price, `Pricing.estimate` returns `unknownTokens = total − disputed` and `disputedTokens = disputed`. Each token is counted once, including when all of them are disputed. A subset field, `unpricedDisputedTokens`, keeps such a model listed under "no price".
  - The combined cost is provisional (`~`), with matching chart marks and VoiceOver wording.
  - The model's own cost stays `n/a`, read aloud as "cost not available".
- **[test]**
  - **F45 (new):** a priced Haiku record without a conflict, an unpriced model with flat 100 against a 300 breakdown, then an unpriced model whose tokens are all disputed. It runs in every indexing mode.
  - **`QuantityTests.unpricedConflictStaysProvisional`:** through a real ledger, it checks each model's unknown + disputed total, `~` against `≥`, the detail, the chart day, the spoken costs, the "no price" listing and the conflict-only `n/a`.
- **[test] Against the old behaviour:** three mutations are each caught: the old return, disputed tokens also counted as unknown, and the old "no price" filter.

## 10. #57: local days in fractional-offset time zones
**Branch:** `fix/57-fractional-offset-days`, from `main` at `219f58d`. Design posted on [#57](https://github.com/loloDawit/spandeck/issues/57#issuecomment-6230245734) before any code.

### 10.1 Cause
- **[code]** Every record went into `Int(epoch / 3600)`, a whole UTC hour. `summarize` put each hour on the local day containing its *start*.
- **[code]** In +05:30, local midnight is 18:30Z, inside the 18:00Z bucket, which starts at 23:30 IST the day before. Up to 30 minutes of usage after midnight (45 in +05:45) landed on the previous day. It left "today" and shifted the 7-day and 30-day edges.
- **[code]** The same placement applied to identity (#55) and completeness (#58) per hour, and to Grok turns.
- **[test]** F21 reproduced on `main`: Mar 9 = 3 and Mar 10 = 4, against 1 and 6; today 4 against 6. Whole-hour zones and DST (F19, F20) were right, because their midnights fall on hour boundaries.

### 10.2 Fix: 15-minute UTC slots
- **[code]** `Ledger.slotSeconds = 900`, with `slot(of:)` and `start(of:)` used at every site: ingest, unread records, pruning, Grok turns, and all three placements in `summarize` (tokens, identity, completeness).
- **[code]** Every current IANA offset is a multiple of 15 minutes, so every local midnight is a slot boundary and a slot lies in exactly one local day in any zone, DST included (Lord Howe's 30-minute shift too).
- **Rejected alternative:** exact per-record timestamps. `summarize` would have to walk every operation, and identity, completeness and unread records would need the same change, for the same result in every zone in use.
- **Limit:** an offset that isn't a multiple of 15 minutes would misattribute again. None is in use, and historical LMT offsets are outside the 32-day window.
- **[code] Time-zone changes:** days are still computed at summary time from UTC slots, so nothing cached depends on the zone. The summary memo key now includes the zone identifier, because two zones can share today's midnight and differ on earlier days (UTC and London after summer time).
  - The ledger takes its calendar as a closure, so a test can change the zone while it runs.
  - Whether macOS updates `Calendar.current` in a running app after a system change is the system's behavior. It belongs to runtime QA.
- **[code] Window (P15, #7):** the start is rounded down to 15 minutes instead of an hour. F22's expected value, 6, now holds and its baseline is removed. The fixture stays `ambiguous` under #7: the window is exact only when the provider's reset falls on a quarter hour.
- **[code] Retention (P16)** prunes by slot. F24 is unchanged.
- **[code] Cache version 7:**
  - the stored `hours`/`hour` fields are renamed `slots`/`slot`;
  - a version 6 cache can't be split at a midnight inside an hour, so it is deleted and the transcripts re-indexed, never reinterpreted;
  - usage whose transcripts were deleted is lost at the upgrade, as at v5 and v6;
  - older builds re-index a v7 cache the same way.

  `docs/USAGE_CACHE.md` has the upgrade and downgrade notes.
- **[code]** `claudeHourlyUsage` (fixtures and audits only) sums slots into UTC hours, so every existing fixture's `hours` expectation is unchanged.

### 10.3 Tests
- **[test] F21:** passes without its baseline and is now classified `pass`. **F22:** passes without its baseline.
- **[test] F46 (new), Asia/Kathmandu, +05:45:**
  - records one second before and at local midnight, including at the 7-day and 30-day starts;
  - a streamed update and a partial-then-pair join (#55);
  - a P9 conflict, so tiers, quantity, known and minimum cost and coverage are checked.
- **[test] F47 (new), America/St_Johns, −03:30 to −02:30 across DST:**
  - midnights before, during and after the 23-hour day;
  - a streamed update and a request-only partial joined by its pair;
  - a P9 minimum.
- **[test] Modes:** F46 and F47 run in tail, full-scan, relaunch and rebuild modes.
- **[test] `TimeZoneTests`:**
  - a zone change while running: fails without the zone in the memo key;
  - a zone change across a relaunch: Kolkata, then Kathmandu over one cache;
  - Lord Howe's 30-minute DST shift: midnights at 13:00Z and 13:30Z, a 24.5-hour day;
  - Grok turns in +05:30.
- **[test] `LedgerCacheTests.olderCacheReplaced(6)`:** a v6 cache is replaced and nothing from it survives. The other cache tests expect version 7.
- **[test] Unchanged:** F19, F20, F23 and F24. Each test above failed before the fix; each fixture failed on its days, today and window.
