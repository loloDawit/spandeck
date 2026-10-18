# Performance baseline (#8)

**Status:** the first baseline, from one Mac. It's a measurement, not a budget: the budgets in §5 are proposals for the owner. Synthetic data only. No real transcript, credential, provider endpoint, setting or app launch was used, and the personal-account app was never run.

## 1. How to reproduce

```bash
scripts/bench.sh [--out DIR] [--idle SECONDS] [small|medium|large ...]   # default: all three, no idle run
scripts/bench-report.py DIR                                              # the tables in §4
```

**What it does:**
- Builds the test target in an optimized release configuration (`-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`).
- Runs `PerformanceBenchTests` once per dataset, **each in its own process**, so the process-wide counters belong to one dataset.
- Then runs `PerformanceMemoryBenchTests` three times per dataset (`gen`, `cold`, `warm`), one ledger per process, for clean memory figures.
- Writes `env.json` and one JSON file per dataset and memory run to `DIR` (default `.build/bench/<UTC time>/`).
- Both suites are skipped unless their environment variables are set, so `swift test` and CI never run them.

**Build caveat:** the shipped app is built by `build.sh` (universal, release). The test target can't build in release without `DEBUG` (some tests use debug-only code), so the benchmark binary has debug-only code compiled in. That code is the snapshot renderer and the hover log, both off unless asked for. The measured code paths are optimized like release, but this is **not the shipped binary**.

**Environment recorded** in `env.json`: macOS version and build, architecture, CPU, core counts, memory, model, Swift and Xcode versions, the commit and whether `Sources`/`Tests` had local changes, the power source, and the load average before and after each dataset. No user name, host name, path or serial number is recorded.

## 2. What is measured, and how

All scenarios drive the real code (`Ledger`, `ProviderServices`, `StatusRenderer`, `PopoverView`, `SystemSampler`, `ConsumerSampler`) inside a `Sandbox`:
- a temporary home and Application Support folder;
- `FakeTransport` with no responses, so any request would fail. None is made.

The ledger's clock is injected (`BenchClock`) to force a 5-minute full scan, an 8-hour sleep or a new day without waiting.

**Tools and counters:**

| Counter | Source | Notes |
|---|---|---|
| Wall time | `DispatchTime` (monotonic) | |
| CPU time | `getrusage(RUSAGE_SELF)` user + system | process-wide |
| Memory | `task_info(TASK_VM_INFO)`: `phys_footprint` (Activity Monitor's *Memory*) and its peak; `ru_maxrss` | process-wide; the peak only rises, hence one ledger per process in §4.3 |
| Disk I/O | `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_diskio_bytesread` / `byteswritten` | reads served from the file cache count as 0 |
| Bytes scanned | `Ledger.claudeReadStats` | what the ledger read, cache-served or not |
| Main-thread hold | a main-actor heartbeat every 5 ms during a cold scan; lateness = observed − 5 ms | |
| Rendering | `StatusRenderer.render` (menu-bar strip) and `ImageRenderer` on `PopoverView` | an `ImageRenderer` pass is a full layout and draw, an upper bound on what an open popover redraws per update |

**Statistics:** median, p95 (nearest rank) and worst. The sample count *n* is in each cell. Datasets are generated once per process, and their generation isn't timed as a scenario.

**Scenarios** (per dataset):

| # | Scenario | Stands for | n |
|---|---|---|---|
| 1 | First scan with no cache, a new `Ledger` each time | cold launch, first run | 5 (small) / 3 |
| 2 | A new `Ledger` on the saved cache, then its first refresh | warm launch: relaunch, login | 5 |
| 3 | `refresh` with nothing new | the 10-second usage tick | 30 |
| 4 | 10 new messages (30 lines) appended to the hot file, then `refresh` | the tick while a session runs | 30 |
| 4b | `flush()` after a change | the cache save: every 10 min while running, and on quit | 10 |
| 5 | Clock +301 s, then `refresh` | the 5-minute full scan, nothing new | 10 |
| 6 | A new 5-hour window start | summary recomputation alone | 10 |
| 7 | Clock +8 h, 3 files grown, then `refresh` | wake from sleep (`didWakeNotification` → `refreshUsage`) | 5 |
| 8 | *Clear cached usage data*, then `refresh` | cache rebuild: also what a version bump costs | 5 (small) / 3 |
| 9 | 10 `refresh` calls at once on the ledger | backpressure at the ledger queue | 1 |
| 9b | `flush()` 50 ms into a cold scan | quit during a scan (`applicationWillTerminate`) | 1 |
| 10 | `ProviderServices.refreshUsage` cold scan with a main-actor heartbeat, and 10 more requests while it runs | main-thread hold; the app-level guard | 1 scan |
| 11 | Menu-bar strip and popover renders | popover closed (strip only) vs open | 200 / 20 |
| 12 | `SystemSampler` probes; hover `ConsumerSampler.top` | 1 s hardware sampling; hover panel | 100 / 20 |
| 13 | 60 s at the app's cadence (1 s samples and strip, 10 s usage refresh, nothing new) against a 60 s sleep-only control | idle CPU | 1 |

**Datasets:**
- **Shape of each logged message:** a ~1 KB prompt, two streamed assistant snapshots and a ~3 KB tool result quoting `\"usage\"`, like the #58 mix on #8.
- **Identity and spread:** 1 % of records have no `requestId`. Messages are spread evenly over 29 days and four models (every 15-minute slot active, the bucket worst case from #57).
- **Hot files:** each file's modification time is its last message's, so only the newest file is hot.
- **Grok:** usage files scaled with the set.

## 3. What isn't measured, and why

- **Disk-cold scans:**
  - "Cold launch" means no SpanDeck cache. The OS file cache still holds the transcripts, because purging it needs root.
  - Run 1 of scenario 1 is closest to a fresh read, since the data was just written.
  - A real first launch on a spinning or busy disk will be slower.
- **The real app process:**
  - `NSApplication` start-up, status-item creation, login-item checks, and timers firing on a real run loop aren't included. Launching the app isn't allowed here (owner rule).
  - Scenario 2 covers the ledger's part of a launch; the rest is unmeasured.
- **Real sleep and wake:** the machine wasn't slept. Scenario 7 models the work the wake handler starts, not the OS transition or network recovery.
- **Network and offline:** every scenario is offline by construction, since nothing in the usage path makes a request. Quota polling (opt-in, one request a minute) is not timed: its latency depends on a provider endpoint the owner doesn't allow tests to reach.
- **Energy:** no `powermetrics` (it needs root) and no energy-impact sampling. CPU time is the proxy.
- **Long runs:** the longest run is about 2 minutes per dataset. Memory growth over days isn't measured.
- **Other hardware:** one Apple M2 Pro. CI runners (3-core `macos-15`) are too noisy for timing, so no budget is enforced there (§5).

## 4. Results: 2026-10-18, Apple M2 Pro

**About this run:**
- Raw results: [`perf/2026-10-18-m2pro/`](perf/2026-10-18-m2pro/), rendered with `scripts/bench-report.py`. A first run (same machine, same day, before the quit and hover scenarios were added) agreed within 13 % on every shared median of 40 ms or more (the largest gap: medium warm launch, 463 → 405 ms). Sub-millisecond scenarios differed by up to 19 % (0.61 → 0.50 ms).
- `commit` is the base: the harness was uncommitted at run time and is committed unchanged in this PR, hence `dirty`.
- **Load:** other work was running on the machine (load average about 3 on 12 cores, shown per dataset). Treat single-digit-millisecond differences as noise.

### 4.1 Environment and datasets

**Environment:** model `Mac14,10`, cpu `Apple M2 Pro`, cores `12`, memory_bytes `17179869184`, macos `26.5`, macos_build `25F71`, swift `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`, xcode `Xcode 26.6 Build version 17F113`, commit `f63fd169a2edcdf72778f095ac6d94e8ebb517aa`, build `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, power `Now drawing from 'AC Power'`

| Dataset | Transcripts | Messages | Lines | Bytes on disk | Grok turns | Load avg before → after |
|---|---|---|---|---|---|---|
| small | 10 | 2,000 | 8,000 | 10.2 MB | 100 | { 4.31 4.18 3.86 } → { 2.97 3.57 3.65 } |
| medium | 100 | 30,000 | 120,000 | 152.7 MB | 1,000 | { 2.97 3.57 3.65 } → { 3.28 3.36 3.54 } |
| large | 301 | 120,000 | 479,600 | 610.8 MB | 5,000 | { 3.28 3.36 3.54 } → { 2.63 3.34 3.48 } |


### 4.2 Latency

Wall time in ms: median / p95 / worst (n). CPU is the median, in ms.

| Scenario | small | medium | large |
|---|---|---|---|
| Cold launch: first scan, no cache | 293.6 / 335.2 / 335.2 (5); CPU 292.9 | 4196.1 / 4226.7 / 4226.7 (3); CPU 4182.3 | 18,388 / 19,044 / 19,044 (3); CPU 17,005 |
| Warm launch: cache load + first refresh | 44.4 / 45.0 / 45.0 (5); CPU 44.3 | 404.9 / 433.9 / 433.9 (5); CPU 404.7 | 1523.7 / 1589.0 / 1589.0 (5); CPU 1520.3 |
| 10 s tick, nothing new | 0.4 / 0.5 / 0.7 (30); CPU 0.5 | 1.1 / 1.2 / 1.7 (30); CPU 1.1 | 2.5 / 3.4 / 3.7 (30); CPU 2.6 |
| 10 s tick, 10 new messages | 11.0 / 12.6 / 36.2 (30); CPU 11.0 | 36.6 / 43.2 / 322.6 (30); CPU 36.6 | 49.3 / 54.5 / 1259.1 (30); CPU 48.9 |
| Cache save (`flush`) | 27.7 / 30.9 / 30.9 (10); CPU 27.5 | 294.2 / 325.0 / 325.0 (10); CPU 290.3 | 1167.4 / 1206.8 / 1206.8 (10); CPU 1143.5 |
| 5 min full scan, nothing new | 0.5 / 0.7 / 0.7 (10); CPU 0.5 | 2.1 / 2.5 / 2.5 (10); CPU 2.1 | 5.6 / 6.9 / 6.9 (10); CPU 5.6 |
| Summary only (window change) | 10.3 / 11.2 / 11.2 (10); CPU 10.2 | 35.5 / 41.3 / 41.3 (10); CPU 35.5 | 47.1 / 48.3 / 48.3 (10); CPU 47.1 |
| Wake after 8 h (full scan, 3 files grew) | 48.0 / 64.3 / 64.3 (5); CPU 43.0 | 320.8 / 357.5 / 357.5 (5); CPU 319.5 | 1271.0 / 1296.4 / 1296.4 (5); CPU 1239.1 |
| Rebuild after Clear cached usage data | 354.1 / 367.6 / 367.6 (5); CPU 353.4 | 4284.8 / 4606.4 / 4606.4 (3); CPU 4276.5 | 18,264 / 18,696 / 18,696 (3); CPU 16,970 |

### 4.3 Memory, I/O, main thread, rendering, idle

| Measure | small | medium | large |
|---|---|---|---|
| Bytes scanned, first scan | 10.2 MB | 152.5 MB | 609.8 MB |
| Cache file | 1.2 MB | 13.1 MB | 47.9 MB |
| Disk written, first scan (median) | 1.2 MB | 13.1 MB | 47.9 MB |
| Disk written, one cache save (median) | 1.3 MB | 13.2 MB | 48.0 MB |
| Disk read, first scan (median; file cache warm) | 0.0 MB | 0.0 MB | 611.8 MB |
| All-scenario process: footprint peak (incl. generator, several ledgers) | 65.2 MB | 237.4 MB | 950.6 MB |
| 10 refreshes at once (ledger queue) | 14.3 ms | 48.3 ms | 61.1 ms |
| Quit (`flush`) 50 ms into a cold scan: main thread blocked | 311.5 ms | 4211.5 ms | 18,038 ms |
| Hover top consumers, cpu / memory (median) | 0.91 / 0.97 ms | 0.80 / 0.84 ms | 0.89 / 0.94 ms |
| App refreshes dropped while one runs | 10 of 10 | 10 of 10 | 10 of 10 |
| Main-actor lateness during a cold scan, p95 / worst | 1.3 / 1.3 ms | 1.3 / 1.4 ms | 2.6 / 3.4 ms |
| Menu-bar strip render, median / worst | 0.008 / 35.5 ms | 0.009 / 25.8 ms | 0.008 / 72.2 ms |
| Popover full render, median / worst (first) | 26.8 / 82.1 ms | 25.1 / 94.4 ms | 25.3 / 301.0 ms |
| Sampler cpu / memory / gpu / battery (median) | 0.005 / 0.003 / 0.020 / 0.665 ms | 0.005 / 0.003 / 0.019 / 0.649 ms | 0.005 / 0.003 / 0.020 / 0.657 ms |
| Idle at app cadence, CPU share of one core | 0.14% over 60 s | 0.12% over 60 s | 0.15% over 60 s |

One ledger per process (memory runs):

| Dataset | Run | Wall | Footprint before | After the scan | Steady (next tick) | Peak | Max RSS |
|---|---|---|---|---|---|---|---|
| large | cold | 19,572 ms | 6.5 MB | 289.1 MB | 289.4 MB | 587.4 MB | 607.6 MB |
| large | warm | 1657.1 ms | 6.4 MB | 379.3 MB | 379.6 MB | 379.6 MB | 406.3 MB |
| medium | cold | 4391.2 ms | 6.3 MB | 103.0 MB | 103.1 MB | 164.6 MB | 189.7 MB |
| medium | warm | 465.2 ms | 6.4 MB | 108.5 MB | 108.6 MB | 108.6 MB | 135.5 MB |
| small | cold | 315.9 ms | 6.6 MB | 24.9 MB | 25.0 MB | 25.0 MB | 52.0 MB |
| small | warm | 56.0 ms | 6.4 MB | 16.7 MB | 16.7 MB | 16.7 MB | 43.6 MB |

### 4.4 What the numbers say

- **Idle is cheap.** At the app's cadence with nothing new:
  - 0.12–0.15 % of one core, the same for every dataset;
  - no disk writes;
  - a 10-second tick costs 0.4–2.5 ms (median) and the hardware probes microseconds; battery is the costliest at about 0.66 ms every 5 s.
- **The main thread isn't held during scans.**
  - Scanning runs on the ledger's serial queue. The main actor was never late by more than 3.4 ms during an 18-second cold scan.
  - `ProviderServices.refreshUsage` **drops** a refresh requested while one runs (10 of 10 dropped), so ticks can't pile up.
  - The ledger queue itself doesn't coalesce: 10 direct calls run one after another. The app-level guard is the only backpressure.
- **Quit is held for a whole scan.**
  - `applicationWillTerminate` calls `Ledger.flush()`, a `queue.sync` behind any scan in flight.
  - 50 ms into a cold scan, quitting held the main thread **0.3 s (small), 4.2 s (medium) and 18 s (large)**.
  - Nothing cancels a scan.
- **New data costs a full summary.**
  - A tick with 10 new messages costs 11–49 ms, almost all of it summary recomputation: 10–47 ms alone, scenario 6.
  - The summary prices every 15-minute slot × model on any change (the #57 note on #8).
- **The JSON cache dominates launch and saves.**

  | Dataset | Cache file | Warm launch (decode + refresh) | One save |
  |---|---|---|---|
  | medium | 13 MB | 0.40 s | 0.29 s |
  | large | 48 MB | 1.5 s | 1.2 s |

  - A save runs every 10 minutes while data changes, and on quit, **on the ledger queue**. A tick that lands on a save waits for it: that's every dataset's worst incremental tick, which wrote one cache's worth (36 ms, 0.32 s and 1.26 s).
- **First scan and rebuild are CPU-bound** at about 33 MB/s of transcript (18 s for 610 MB). A rebuild (clear, lost key, or a cache version bump) costs the same as a first scan.
- **Memory grows with history: about 3.3 KB resident per logged message.**
  - One ledger holds 25 MB (small), 103 MB (medium) and 289 MB (large) after a cold scan.
  - A warm launch on large settles **higher**, at 380 MB, than a cold scan does; decoding the cache costs more than building the state.
  - The cold scan's peak on large is 587 MB.
  - The cache file is about 400–440 bytes per message.
- **The popover:**
  - Closed: only the strip is drawn, at 8 µs median.
  - Open: a full render (layout and draw) takes about 25 ms. The first one is 82–301 ms, which is SwiftUI's first-use cost.
  - This is an upper bound for one update. An open popover redraws on each store change (every 1 s sample).
- **Hover:** the top-consumer list takes about 0.9 ms per refresh.

## 5. Proposed budgets (for the owner's decision)

**How the budgets were set:**
- Each is set from the measurement plus headroom, against a user-facing reason.
- Each applies to the large dataset unless stated: 120,000 messages, about 30 days of heavy use.
- They're **not enforced in CI**: a 3-core shared runner can't time reliably.
- **Proposed rule:** rerun `scripts/bench.sh` on the reference Mac before merging a change to `Ledger`, the cache, the summary or the samplers. Flag a breach, or a regression above 25 % in a median.

| # | Budget | Measured | Why this number |
|---|---|---|---|
| B1 | Idle CPU at the app's cadence ≤ **0.5 %** of one core | 0.12–0.15 % | a menu-bar monitor must not show up in Activity Monitor; about 3× headroom |
| B2 | Main thread held ≤ **16 ms** during any refresh, scan or save | ≤ 3.4 ms | one 60 Hz frame: no visible hitch |
| B3 | Quit holds the main thread ≤ **1 s** | **0.3 / 4.2 / 18 s: fails at medium and large** | a quit that takes seconds looks hung |
| B4 | 10 s tick, nothing new: p95 ≤ **10 ms** | 3.4 ms | it runs 360 times an hour |
| B5 | Tick with new data, without a save: p95 ≤ **100 ms** | 54.5 ms | runs every 10 s during active use |
| B6 | Cache save ≤ **0.5 s** (medium) / ≤ **2 s** (large) | 0.29 / 1.2 s | it blocks the ledger queue: ticks wait behind it |
| B7 | Warm launch, ledger part, ≤ **1 s** (medium) / ≤ **3 s** (large) | 0.40 / 1.5 s | totals should appear shortly after login |
| B8 | First scan or rebuild ≥ **20 MB/s** of transcript | about 33 MB/s | 30 days of heavy use indexed in under a minute |
| B9 | Resident memory ≤ **5 KB per logged message**, and peak ≤ 2× steady | about 3.3 KB; cold peak 2.0× on large | the in-memory state is per operation; keeps 120,000 messages under about 600 MB |
| B10 | Cache file ≤ **500 B per logged message** | 400–440 B | the #55 growth (about 2.4×) left little room |
| B11 | Popover full render: median ≤ **50 ms** | about 25 ms | redrawn while open, on each store change |

**B3 fails today.** B9's ceiling is generous on purpose: the absolute figure (290–380 MB for 30 heavy days) is the real concern, and §6 ranks it second.

## 6. Bottlenecks, ranked

1. **Quit waits for a scan in flight (B3 fails).**
   - The main thread is held for the rest of the scan: up to 18 s on large.
   - It is worst on the first launch, after a clear, and after a version bump, which is exactly when a user is most likely to quit an app that looks busy.
   - [code] `main.swift` `applicationWillTerminate` → `Ledger.flush()` → `queue.sync`.
2. **Memory per message.**
   - 290–380 MB resident on large, and higher after a warm launch than after a cold scan.
   - The cause isn't located yet: `Seen` per operation, links, slot maps or decoder overhead. It needs an allocation profile (Instruments) on the synthetic set before any change.
3. **JSON cache encode and decode:** 1.2–1.5 s per save or launch on large, run on the ledger queue, so ticks wait.
   - This is ADR 0001 D6's revisit trigger 1: "#8 measures encode or decode cost above a budget the owner sets".
   - **Proposed budget:** B6 and B7. Both are met today, so this is a watch item, not a format change.
4. **A full summary on every change:** 35–47 ms per tick with new data on medium and large. It is the bulk of the active-use tick, but within B5.
5. **First-scan throughput:** about 33 MB/s, CPU-bound, single queue. It meets B8.

**Not bottlenecks:** idle CPU, the no-change tick, full scans with nothing new, the hardware probes, the menu-bar strip, the hover list, and wake (a full scan plus summary: 0.3 s medium, 1.3 s large).

## 7. Proposed follow-up issues (none created; owner approval first)

Each has its own failing benchmark scenario to show the change.

1. **Quit must not wait for an in-flight scan.** Let a scan stop between files or lines when quit begins, and save what's counted. **Acceptance:** scenario 9b ≤ 1 s on large, the cache stays consistent, and the next launch resumes from saved marks (no double count, F-fixtures unchanged).
2. **Profile and explain ledger memory.** An allocation profile of the large set (cold and warm), and a breakdown per structure. **No code change** until the owner picks a target. **Acceptance:** a documented breakdown, and a B9 decision.
3. **Summary cost independent of slot count** (the #57 note). Sum per local day × model × window before pricing. **Acceptance:** scenario 6 ≤ 15 ms on large, and totals identical on every fixture.
4. **Saves off the tick path, or cheaper** (watch item, after 1–2). Only if B6 or B7 is breached, or a save is shown to delay ticks for users.

**Not proposed:** no change to scanning (it meets B8), idle work or rendering.

## 8. Offline, sleep and wake, cancellation (summary)

- **Offline:**
  - The usage path makes no network request in any scenario. Every request would have failed; the transports have no responses.
  - Quota polling is opt-in and outside this benchmark (§3).
- **Sleep and wake:**
  - Modelled (clock +8 h, files grown): the wake refresh is a full scan plus a summary, 0.3 s (medium) and 1.3 s (large).
  - The OS transition and network recovery aren't measured.
- **Cancellation:**
  - Ledger scans can't be cancelled.
  - `ProviderServices` drops overlapping usage refreshes, and drops results that arrive after a consent change (existing tests).
  - The quit path is the one place a long scan reaches the main thread (§6.1).
