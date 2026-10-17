# Audit 0007 — Privacy verification of local history processing (#5)

**Issue:** #5 (M0, privacy). **Parent:** #2. **Related:** #8, #11. **Code base:** `main` at `226a7d6` (cache version 7, after #55–#58, #57 and #56).
**Question:** can SpanDeck safely process sensitive local Claude Code history in a supervised trial on the owner's main macOS account?
**Short answer:** **not yet: NO-GO until the runtime gate in §7 passes on `226a7d6`.** The code review and the automated canary tests found no transcript content, path or id written to disk, shown in the UI or put in an error message. Two hardening proposals and one storage collision need the owner's decisions; none of them leaks content. §8 lists the gates.

## Evidence labels
Same scheme as [audit 0003](0003-security-inventory.md):

| Label | Meaning |
|---|---|
| **[code]** | Read in the source at `226a7d6`; file:line given |
| **[test]** | Asserted by an automated test in this repository, run locally (`swift test`) |
| **[runtime]** | Observed in the running app on macOS. Runs 1–2 of [audit 0003](0003-runtime-verification.md) are on build `227015c`; nothing in this audit is new runtime evidence |
| **[assumption]** | Not verified; stated so a reviewer can challenge it |

## 1. Field-level inventory

### 1.1 Claude Code transcripts (`~/.claude/projects/**/*.jsonl`, `~/.config/claude/projects/**/*.jsonl`)

| Stage | What | Evidence |
|---|---|---|
| **Listed** | Every `.jsonl` file modified in the last 32 days (paths, sizes, modification and change times). | [code] `Ledger.swift` `scanClaude` (871), `tailHotFiles`, `discoverNewFiles` |
| **Read** | Each file is memory-mapped. Only lines containing a `"usage"` key are parsed. | [code] `readClaudeFile` 999, `ingestLines` 1032, `hasUsageKey` 1052 |
| **Parsed, kept transiently** | The whole line is parsed by `JSONSerialization` into Foundation objects, then dropped after the line. Fields **used:** `type`, `timestamp`, `requestId`, `message.id`, `message.model`, `message.usage`, and in usage the token counters, `cache_creation` tiers and `iterations[].type/model` plus their counters. Everything else in the line (prompts, replies, thinking, tool inputs and results, `cwd`, `gitBranch`, `sessionId`, `uuid`, other usage fields such as `service_tier`) is parsed but never read. | [code] `ingestClaudeLine` (1067), `agg`, `fingerprint` (1244); [test] `PrivacyCanaryTests` |
| **In memory only** | Transcript paths (`hotFiles`, scan candidates, `pendingFiles` keyed by opaque id); the summaries shown. | [code] |
| **Persisted** (`claude-ledger.json`, see §1.5) | See §1.5 for the field list. Keyed: file ids, operation ids, single-id links, unread-line ids, the change stamp and anchor. In the clear: byte offsets and sizes, 15-minute UTC slots, model ids, token counts, identity, flaw and unread counts. | [code] `State` (685); [test] `PrivacyCanaryTests`, `LedgerCacheTests.cacheHoldsNoPathsIdsOrContent` |
| **Shown** | Model ids, token counts, costs, day bars, and the completeness, quantity, identity and cost notes. The notes give counts and fixed wording only. | [code] `PopoverView.swift`; [test] `PrivacyCanaryTests` scans every note, tooltip, cost string and VoiceOver label |
| **Logged** | Nothing. | [code] the only `NSLog` is the login-item error (`PopoverView.swift:1034`) |

### 1.2 Grok sessions (`~/.grok/sessions/*/*/usage.json`)
- **[code] Read:** each file is re-parsed when its modification time changes (`scanGrok` 1379). Fields used: `endedAt`, the token counters, `modelCalls`, `costUsdTicks`, `primaryModelId` (`parseGrokUsage` 1399).
- **[code] In memory only:** paths and turns (`grokFiles`). **Never persisted:** Grok usage has no place in `State`.
- **[test] Shown:** `primaryModelId` verbatim in the model list. `PrivacyCanaryTests` asserts that the Grok model id is in no file.

### 1.3 Credentials (consent-gated, default off)
- **[code]** The Claude Code OAuth token is read from the Keychain (`/usr/bin/security`) only with `claude.limits.enabled`. The Grok key is read from `~/.grok/auth.json`, and `grok models` run, only with `grok.enabled`. Both are off by default (`Store.swift` `Prefs`), held in memory, and sent only to their provider's endpoint over ephemeral `URLSession`s (`Dependencies.swift:108–122`).
- **[runtime]** Run 2 on `227015c`. None of these files has changed since (`git log 227015c..226a7d6`).
- Audited in detail in [0003-security-inventory.md](0003-security-inventory.md); not re-audited here.
- **[test]** `PrivacyCanaryTests` puts a key canary in `~/.grok/auth.json`. It reaches no file and no shown string; the ledger never reads it.

### 1.4 Preferences (`~/Library/Preferences/dev.headroom.Headroom.plist`)
- **[code] Keys:**
  - display: `show.cpu`, `show.gpu`, `show.mem`, `show.battery`, `show.claude`, `show.grok`, `interval`;
  - keep awake: `awake.agents`, `awake.display`;
  - consent: `claude.limits.enabled`, `grok.enabled`;
  - `usage.metric` (Cost/Tokens);
  - `debugHover` (read only, never written by the app).
- None is derived from a transcript (`Store.swift` `Prefs`, `PopoverView.swift:626, 935–943`).

### 1.5 Application Support (`~/Library/Application Support/Headroom/`)
| File | Contents | Mode | Evidence |
|---|---|---|---|
| (folder) | — | `0700`, checked before every write, never followed through a symlink | [code] `PrivateStorage.swift:36–55`; [test] `LedgerCacheTests` |
| `claude-ledger.json` | `version` 7; `keyCheck`; `files` (keyed id → offset, **size**, keyed `stamp`, keyed `anchor`); `seen` (keyed op id → slot, per-model counts, identity kind, flaw flag); `links` (keyed id → keyed id + slot); `slots` (slot → **model id** → counts, including P9 tiers); `identity`, `flawed` (slot → counts); `unread` (keyed line id → kind + slot) | `0600` | [code] `State`; [test] `PrivacyCanaryTests` |
| `claude-ledger.key` | 32 random bytes | `0600` | [code] |
| `.claude-ledger.json.tmp-<uuid>` | only during a save | created `0600` | [code] `PrivateStorage.swift:71–76` |
| `pricing-source.json` | the public LiteLLM price file, only after the user downloads it | default umask (typically `0644`), inside the `0700` folder | [code] `Ledger.swift:502–503` |
| `pricing.json` | legacy price file from Headroom | unchanged | [code] |

### 1.6 Other write paths
- **`~/Library/Logs/Headroom-hover.log`:** only when the hidden preference `debugHover` is set, in **release builds too**. It holds timestamps, mouse coordinates, panel frames and which hover panel is shown. No transcript data, nothing about other processes. It is created under the default umask, never pruned, and not removed by *Clear cached usage data*. [code] `Hover.swift:39–48`. **Finding P2.**
- **`--snapshot <folder>`:** debug builds only, from a synthetic store. [code] `Snapshot.swift`; [test] `SnapshotTests`; [runtime] V17–V18 of run 1.
- **macOS-managed:** a per-user Metal shader cache and, for any app, Saved Application State. [runtime] V8 of run 1. No URL cache: the sessions are ephemeral.
- **The UI also shows other processes' names** in the top-consumer hovers (`Consumers.swift`, `proc_name`/`proc_pidpath`). Memory and display only, never written.

## 2. `USAGE_CACHE.md` checked against the code

| Statement | Code | Holds? |
|---|---|---|
| Folder `0700`, checked and tightened before every write; parents never changed | `PrivateStorage.prepare` 36–55 | **Yes** [code, test] |
| Files `0600`; temp file created `0600` with `O_CREAT\|O_EXCL\|O_NOFOLLOW`, then renamed | `PrivateStorage.write` 71–76 | **Yes** [code, test] |
| Files read without following symlinks | `PrivateStorage.read` 55–67 | **Yes** [code, test] |
| Unsafe folder: nothing written anywhere, totals in memory, reason in Settings | `Ledger.saveCache`, `LedgerCacheIssue` | **Yes** [test: `failedTighteningWritesNothing`, `PrivacyCanaryTests.unsecuredFolderWritesNothingAndSaysNothingSensitive`] |
| No paths, ids or content stored; unread lines as an id and a kind only | `fileID` 779, `unread` 1216 | **Yes** [test] |
| Only lines with a `"usage"` key are parsed; the line is parsed whole, nothing else kept | `hasUsageKey`, `ingestClaudeLine` | **Yes** [code, test] |
| "Grok session files are read every refresh and never cached" | `scanGrok` 1379 | **Inaccurate:** they're listed every refresh and re-read **when modified**. Never cached: yes. **Corrected in this PR.** |
| "Nothing from transcripts is logged: the app's only `NSLog` reports a login-item error" | `PopoverView.swift:1034` | **Yes**, but incomplete: the hover debug log (§1.6) is another write. **Added in this PR.** |
| `files` row (offset, size, stamp, anchor) and #56 detection rules | `FileMark` 656, `readClaudeFile` | **Yes** [test: `RewriteTests`] |
| Time buckets in the clear, 15-minute slots | `State.slots`, `slot(of:)` | **Yes** [code] |
| Pruned after 32 days at each full scan; unread lines without a date 32 days after found | `scanClaude` pruning, `retentionDays` 704 | **Yes** [code; test: F24] |
| Saved at most every 10 minutes and on quit | `refresh` (`> 600`), `main.swift:61–62` | **Yes** [code] |
| Versions 3–6 deleted and re-indexed, never mixed | `loadCache` 1524 | **Yes** [test: `olderCacheReplaced`, `legacyCacheReplaced`, `PrivacyCanaryTests.oldCachesAreReplaced`] |
| Clear deletes cache, key and temp files; not transcripts, prices, credentials or consent | `clearCache` 833 | **Yes** [test; runtime V13 on `227015c`] |
| Opaque id limits (key beside the cache; guesses confirmable with the key) | — | **Yes**, as documented; unchanged |

## 3. Privacy verification matrix

| # | Check | Code | Automated test | Runtime | Gap |
|---|---|---|---|---|---|
| C1 | No transcript content, path, id, branch, session, tool or credential canary in any file the app writes: index, append, rewrite, relaunch, clear | ✔ | ✔ `PrivacyCanaryTests.indexAppendRewriteRelaunchAndClear` (all files under the sandbox outside the fixtures, raw and JSON-escaped) | ✔ V10 on `227015c`, schema 4 only | Run 3 on v7 |
| C2 | Malformed, invalid-UTF-8, undated, invalid-usage and cut-off lines leave only counts | ✔ | ✔ same test (completeness counts asserted; no canary) | ✘ | Run 3 (`privacy` fixture) |
| C3 | Old caches with raw paths, ids or planted content are deleted, not carried over | ✔ | ✔ `oldCachesAreReplaced(3, 6)`, `olderCacheReplaced(4, 5, 6)`, `legacyCacheReplaced` | ✘ | Run 3 (optional: plant a v6 file) |
| C4 | Unsecured cache folder: nothing written, reason names no path | ✔ | ✔ `unsecuredFolderWritesNothingAndSaysNothingSensitive`, `failureTextsNameNoPath` | ✘ | — |
| C5 | Shown strings (notes, tooltips, cost text, VoiceOver, chart labels, cache issue) carry no canary | ✔ | ✔ `PrivacyCanaryTests` | ✔ V11 on `227015c` | Run 3 screenshots |
| C6 | Permitted metadata only: model ids (Claude in the cache and the UI, Grok in the UI only), counts, slots | ✔ | ✔ asserted present, and only there | ✔ V10 (model canary) | — |
| C7 | Model ids stored verbatim, any length | ✔ | ✔ `modelIdIsKeptAsWritten` records it | — | Owner decision (P1) |
| C8 | Leak detection works | — | ✔ three planted leaks (raw path ids, unread line text, branch appended to the model) each fail the suite | — | — |
| C9 | Cache and key `0600`, folder `0700`, temp files cleaned | ✔ | ✔ `LedgerCacheTests` | ✔ V8, V12 on `227015c` | Run 3 |
| C10 | Credentials and network off by default; consent persists | ✔ | ✔ `GrokConsentTests`, `QuotaVisibilityTests`, default-launch tests | ✔ V2–V4, V14 (run 2, kernel-reported forks) | Smoke check in Run 3. Code unchanged since `227015c` |
| C11 | No transcript data in logs | ✔ | — | ✔ run 1 log stream | Run 3 log capture |
| C12 | Snapshot is synthetic, debug only | ✔ | ✔ `SnapshotTests` (no live environment is built, so nothing is scanned or read; the fixture holds nothing about the machine or user) | ✔ V17–V18 | — |
| C13 | Clear removes cache and key, makes a new key, keeps transcripts | ✔ | ✔ | ✔ V13 on `227015c` | Run 3 |
| C14 | Crash reports and Spotlight hold no transcript data | — | — | — | **Not verified** [assumption: crash reports carry backtraces, not heap; Spotlight isn't asked to index the cache] |
| C15 | No side effects of upstream Headroom on the same account | — | — | — | **Owner check** (P3) |

## 4. Storage, retention, backup and deletion

- **Location and identity:** everything lives under names inherited from Headroom:
  - the `dev.headroom.Headroom` preferences domain and bundle id;
  - `~/Library/Application Support/Headroom/` and `claude-ledger.json`;
  - `~/Library/Logs/Headroom-hover.log`.

  They are kept for compatibility (`RELEASE_SIGNING.md` step 1). **Finding P3:** upstream Headroom on the same account would use the same folder, file and preferences.
- **Retention:**
  - Transcripts older than 32 days are skipped.
  - Buckets, operation ids, links and unread entries older than 32 days are pruned at each full scan (every 5 minutes while running).
  - Usage already counted stays counted after its transcript is deleted (P12), for up to 32 days. That is deliberate, and it means a deleted session's token counts and model ids stay in the cache until they age out or the cache is cleared.
- **Backups:**
  - [code] Nothing excludes the cache or its key from backups (no `isExcludedFromBackup`). Time Machine backs up `~/Library/Application Support` by default [assumption: standard macOS behavior, not tested here].
  - A backup therefore holds the cache **and** its key, so anyone with the backup can test guesses against the keyed ids (already in `USAGE_CACHE.md`).
  - The cache can be rebuilt from transcripts, so excluding it would lose nothing but deleted-session history. **Finding P4.**
- **Deletion:**
  - *Clear cached usage data* unlinks the cache, key and temp files and makes a new key; transcripts aren't touched.
  - **It is not secure erasure.** APFS copy-on-write, local and Time Machine snapshots and backups can keep earlier versions of the files. macOS gives an app no guarantee here, and SpanDeck claims none.
  - To remove everything SpanDeck writes, a user would delete:
    - the `Headroom` Application Support folder;
    - the preferences plist (`defaults delete dev.headroom.Headroom`);
    - `~/Library/Logs/Headroom-hover.log`, if it exists;
    - the app's Saved Application State and Metal cache (macOS-managed).
- **Failure behavior:** if the folder isn't safe (a symlink, owned by someone else, or can't be made `0700`), nothing is written there or anywhere else. Totals stay in memory, and Settings shows a fixed reason with at most a `strerror` text, never a path. [test: C4]

## 5. Findings

No **verified defect** exposes transcript content, paths or ids. All checks in §3 marked ✔ for code and tests passed.

| ID | Kind | Severity | Source | Reproduction | Exposure | Likelihood | Recommendation |
|---|---|---|---|---|---|---|---|
| **P1** | Accepted limitation, with a hardening proposal | Low | `Ledger.swift:1075` (`model`), `State.slots`; Grok `parseGrokUsage` | `PrivacyCanaryTests.modelIdIsKeptAsWritten`: a 2,000-character model id with spaces and slashes is stored and shown verbatim | Whatever a record's `model` field holds is persisted in the clear (Claude) and shown (Claude, Grok) | Low: Claude Code writes model ids there. A corrupted or crafted transcript would be needed | **Owner decision:** bound model ids (for example ≤ 100 characters of `[A-Za-z0-9._:@/-]`) and count anything else as `unknown`. Not implemented here |
| **P2** | Hygiene | Low | `Hover.swift:39–48` | `defaults write dev.headroom.Headroom debugHover -bool true`, then hover the menu bar | UI geometry and timestamps only; the file is world-readable under the default umask, never pruned, and not removed by Clear | Needs a hidden preference | **Owner decision:** compile the hover log out of release builds, or document it. Not implemented here |
| **P3** | Collision verified by code; upstream behavior an [assumption] | Medium for the trial | `Resources/Info.plist:12`, `Util.swift:148` (`Application Support/Headroom`), `Ledger.cacheName` | Install upstream Headroom on the same account | **Verified:** both apps would use the same Application Support folder, `claude-ledger.json` and `dev.headroom.Headroom` preferences domain. SpanDeck deletes any cache that isn't its own version at load and re-indexes. **[assumption]**, upstream's current code not read: upstream writes its own cache there, a version 3 cache with raw paths and ids in the version SpanDeck forked from, so the two apps would keep replacing each other's file and upstream's would hold paths and ids | Only if upstream Headroom is installed on the trial account | **Trial gate:** confirm no Headroom install or `dev.headroom.Headroom` domain on the main account. Identity change to [#11](https://github.com/loloDawit/spandeck/issues/11) (comment, no new issue) |
| **P4** | Accepted limitation, with a hardening proposal | Low | no `isExcludedFromBackup` | — | Backups hold the cache and its key | Depends on the user's backups | **Owner decision:** mark the cache and key excluded from backup. Not implemented here |
| P5 | Accepted limitation | — | Clear | — | Old file versions in snapshots and backups | — | Documented (§4); no secure-erase claim |
| P6 | Accepted limitation | — | in-memory parsing | — | Whole lines are parsed into memory transiently; paths are held in memory | — | Inherent to reading transcripts. Crash-report content not verified (C14) |
| P7 | Documentation defect | — | `USAGE_CACHE.md` | §2 | — | — | **Fixed in this PR:** Grok re-read rule, hover log |

No new issue is filed: no verified defect qualifies. P3 goes to #11 as a comment. P1, P2 and P4 are proposals for the owner.

## 6. Synthetic canary tests (`Tests/HeadroomTests/PrivacyCanaryTests.swift`)

**Canaries:**
- prompts, replies and thinking;
- code;
- credential-shaped strings (`sk-ant-CANARY…`, `AKIACANARY…`, `ghp_CANARY…`, `xai-CANARY…`), all obviously fake;
- a repository and user name in the project folder and `cwd`;
- `gitBranch`, `sessionId`, `uuid` and `parentUuid`;
- message and request ids;
- tool inputs and results (`tool_use.input`, `tool_result`, `toolUseResult`);
- summary and system records;
- a non-counter usage field (`service_tier`) and an `iterations` field;
- malformed, invalid-UTF-8, undated, invalid-usage and cut-off lines;
- a subagent file;
- Grok project and session folder names, a Grok prompt field, and a Grok CLI key.

**Permitted:** the Claude model id (asserted present in the cache and the model list) and the Grok model id (asserted present in the UI, absent from every file). Counts and times are also permitted.

**Scanned:** every file under the sandbox outside the fixtures, as raw bytes and JSON-escaped, plus every shown string: notes and their details, the cost note, cost text, details and VoiceOver labels for each period and the window, chart family labels, model rows, and the cache issue.

**Scenarios:**
- cold index;
- append (tail path);
- an in-place rewrite (#56 restart path);
- relaunch;
- clear and rebuild;
- planted v3 (raw paths, ids) and v6 caches;
- a cache folder that can't be secured;
- every failure text.

**Leak detection:** the suite fails when a leak is planted: raw paths as file ids, an unread line's text as its key, or the git branch appended to the model.

## 7. Runtime verification (Run 3: pending, owner)

Nothing here was run on macOS by Claude. The runtime evidence above is from runs 1–2 on `227015c`.

The credential, network, consent, storage and snapshot sources are unchanged since then, but the ledger and the UI aren't: cache v4 → v7, unread records, slots, anchors and new notes.

**Run 3**, in the `spandecktest` account, on the build staged from `226a7d6` or this PR's head. Following [0003-runtime-verification.md §5](0003-runtime-verification.md):

0. The `privacy` command exists only on this branch until it is merged. The script runs from the checkout, so check out `audit/5-privacy-verification` (or merge it) before `stage`.
1. `stage` (in the build account), then `preflight`.
2. `fixtures 0`, `identity`, `completeness` and **`privacy`** (new: secret, code, tool, thinking and branch canaries, a malformed line and a cut-off last line).
3. `capture before` → `launch 180 main` → `capture main`. The canary search now covers every kind but the model.
4. Quit, `launch 120 relaunch`, `capture relaunch`. Clear cached usage data in Settings, then `capture after-clear`.
5. `snapshot`, `summary`.

**Rows to re-observe in full:**
- **V8** files written;
- **V10** cache: version 7, all ids 32-hex, `files` marks with a stamp and anchor, no `/`, no canary of any kind except the model;
- **V11** display: notes, `~`/`≥`, and no canary in any screenshot;
- **V12** temp files;
- **V13** clear.

**Smoke check only:**
- V1, V4 (network), V5 and V7 (preferences);
- V2, V3 and V9 with the fork monitor.

**Expected results** are recorded by the script lines of `fixtures`, `completeness` and `privacy`. With all three applied: 87 more `claude-sonnet-4-5` tokens than `fixtures` alone, and a completeness detail reading "4 records couldn't be read … 2 aren't valid JSON …". The exact text is in the `privacy` record, derived through the ledger and `CompletenessText`. A file still being written isn't reported in the note.

**Stop conditions:** any canary other than the model in any file the app writes, or in a screenshot → **stop and file a P0**.

## 8. GO / NO-GO for a supervised personal-account trial

**Recommendation: NO-GO today.** It becomes a **conditional GO** once every open gate below is closed.

**Satisfied:**
- ✔ Field-level inventory of what is read, kept in memory, written and shown, with each `USAGE_CACHE.md` statement checked against code (§1–§2); two corrections made.
- ✔ Automated canary suite over every sensitive field kind and every lifecycle scenario, including migration, clear and permission failure. No leak; planted leaks are caught (§6).
- ✔ Cache, key and folder permissions; no paths or ids at rest; failure texts carry no path.
- ✔ Credentials, network and login item off by default, and consent persistence: runtime-verified on `227015c`, code unchanged since.

**Open (must close before a GO):**
1. **Run 3** on `226a7d6` or this PR's head passes §7, including the new `privacy` fixture and screenshots.
2. **P3:** the owner confirms the main account has no Headroom install, no `~/Library/Application Support/Headroom/` and no `dev.headroom.Headroom` preferences domain. If it has any of them, decide what to do with that data first.
3. The owner **accepts or schedules P1, P2 and P4** (none blocks by itself).
4. The owner **accepts the residual limits:**
   - the key sits beside the cache, including in backups;
   - model ids and 15-minute activity per model are in the clear;
   - no secure erase;
   - crash-report and Spotlight content are unverified.

**Trial conditions** (once GO):
- Both consent switches stay off.
- No `debugHover`.
- Inspect the cache with `runtime-verify.sh inspect_cache` (counts and ids only) after the first index.
- If anything unexpected appears: stop the app and *Clear cached usage data*.
