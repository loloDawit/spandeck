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
| 1 | First scan with no cache, a new `Ledger` each time (it includes the first cache save) | cold launch, first run | 5 (small) / 3 |
| 2 | A new `Ledger` on the saved cache, then its first refresh | warm launch: relaunch, login | 5 |
| 3 | `refresh` with nothing new | the 10-second usage tick | 30 |
| 4 | 10 new messages (40 lines) appended to the hot file, then `refresh` | the tick while a session runs | 30 |
| 4b | `flush()` after a change | the cache save: every 10 min while running, and on quit | 10 |
| 5 | Clock +301 s, then `refresh` | the 5-minute full scan, nothing new | 10 |
| 6 | A new 5-hour window start | summary recomputation alone | 10 |
| 7 | Clock +8 h, the three newest files grown, then `refresh` (it also saves the cache, as the app's would) | wake from sleep (`didWakeNotification` → `refreshUsage`) | 5 |
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

**About this run (run 3):**
- Raw results: [`perf/2026-10-18-m2pro/`](perf/2026-10-18-m2pro/), produced by the committed harness (`a824c88`, no local changes) and rendered with `scripts/bench-report.py`.
- Two earlier runs the same day, on a harness the review of #85 corrected, are not committed. Where they differ by more than about 15 %, the range is given in §4.4.
- **Load:** other work was running on the machine (load average about 3.5 on 12 cores, shown per dataset). Treat single-digit-millisecond differences as noise.

### 4.1 Environment and datasets

**Environment:** model `Mac14,10`, cpu `Apple M2 Pro`, cores `12`, memory_bytes `17179869184`, macos `26.5`, macos_build `25F71`, swift `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`, xcode `Xcode 26.6 Build version 17F113`, commit `a824c88406536791a00ad7577669941a3750bd8c`, build `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, power `Now drawing from 'AC Power'`

| Dataset | Transcripts | Messages | Lines | Bytes on disk | Grok turns | Load avg before → after |
|---|---|---|---|---|---|---|
| small | 10 | 2,000 | 8,000 | 10.2 MB | 100 | { 3.56 3.39 3.45 } → { 3.11 3.38 3.44 } |
| medium | 100 | 30,000 | 120,000 | 152.7 MB | 1,000 | { 3.11 3.38 3.44 } → { 3.29 3.43 3.45 } |
| large | 301 | 120,000 | 480,000 | 611.4 MB | 5,000 | { 3.29 3.43 3.45 } → { 3.75 3.72 3.67 } |


### 4.2 Latency

Wall time in ms: median / p95 / worst (n). CPU is the median, in ms.

| Scenario | small | medium | large |
|---|---|---|---|
| Cold launch: first scan, no cache | 313.5 / 355.3 / 355.3 (5); CPU 311.2 | 4,206.6 / 4,262.7 / 4,262.7 (3); CPU 4,196.9 | 24,046.2 / 26,680.0 / 26,680.0 (3); CPU 18,554.5 |
| Warm launch: cache load + first refresh | 47.4 / 48.5 / 48.5 (5); CPU 47.2 | 403.6 / 435.6 / 435.6 (5); CPU 403.5 | 1,799.8 / 1,901.7 / 1,901.7 (5); CPU 1,783.7 |
| 10 s tick, nothing new | 0.4 / 0.6 / 0.7 (30); CPU 0.4 | 1.1 / 1.3 / 1.6 (30); CPU 1.2 | 2.7 / 3.4 / 5.9 (30); CPU 2.8 |
| 10 s tick, 10 new messages | 12.0 / 13.0 / 72.2 (30); CPU 12.0 | 36.8 / 38.1 / 341.6 (30); CPU 36.8 | 54.0 / 86.1 / 1,333.3 (30); CPU 52.4 |
| Cache save (`flush`) | 27.7 / 31.6 / 31.6 (10); CPU 27.4 | 289.4 / 312.6 / 312.6 (10); CPU 288.0 | 1,233.3 / 1,328.0 / 1,328.0 (10); CPU 1,222.8 |
| 5 min full scan, nothing new | 0.5 / 0.7 / 0.7 (10); CPU 0.5 | 2.1 / 2.5 / 2.5 (10); CPU 2.1 | 6.5 / 7.2 / 7.2 (10); CPU 6.5 |
| Summary only (window change) | 9.7 / 9.8 / 9.8 (10); CPU 9.7 | 35.3 / 35.7 / 35.7 (10); CPU 35.3 | 50.7 / 55.5 / 55.5 (10); CPU 50.7 |
| Wake after 8 h (full scan, 3 files grew, cache save) | 42.1 / 46.7 / 46.7 (5); CPU 41.7 | 321.2 / 337.7 / 337.7 (5); CPU 319.6 | 1,307.9 / 1,398.9 / 1,398.9 (5); CPU 1,272.1 |
| Rebuild after Clear cached usage data | 357.9 / 365.4 / 365.4 (5); CPU 357.1 | 4,306.6 / 4,597.2 / 4,597.2 (3); CPU 4,289.5 | 19,006.1 / 26,600.7 / 26,600.7 (3); CPU 17,646.2 |

### 4.3 Memory, I/O, main thread, rendering, idle

| Measure | small | medium | large |
|---|---|---|---|
| Bytes scanned, first scan | 10.2 MB | 152.5 MB | 610.3 MB |
| Cache file | 1.2 MB | 13.1 MB | 47.9 MB |
| Disk written, first scan (median) | 1.2 MB | 13.1 MB | 47.9 MB |
| Disk written, wake (median) | 1.3 MB | 13.3 MB | 48.1 MB |
| Disk written, one cache save (median) | 1.3 MB | 13.2 MB | 48.0 MB |
| Disk read, first scan (median; file cache warm) | 0.0 MB | 0.0 MB | 612.2 MB |
| All-scenario process: footprint peak (incl. generator, several ledgers) | 72.7 MB | 238.8 MB | 948.9 MB |
| 10 refreshes at once (ledger queue) | 15.2 ms | 43.9 ms | 64.7 ms |
| Quit (`flush`) 50 ms into a cold scan: main thread blocked | 323.9 ms | 4,158.9 ms | 18,233.8 ms |
| Hover top consumers, cpu / memory (median) | 0.81 / 0.87 ms | 0.83 / 0.87 ms | 0.80 / 0.87 ms |
| App refreshes dropped while one runs | 10 of 10 | 10 of 10 | 10 of 10 |
| Main-actor lateness during a cold scan, p95 / worst | 1.3 / 1.4 ms | 1.3 / 2.6 ms | 1.3 / 2.2 ms |
| Menu-bar strip render, median / worst | 0.008 / 43.3 ms | 0.008 / 52.6 ms | 0.008 / 73.8 ms |
| Popover full render, median / worst (first) | 26.4 / 106.5 ms | 25.3 / 93.9 ms | 27.9 / 419.1 ms |
| Sampler cpu / memory / gpu / battery (median) | 0.005 / 0.003 / 0.019 / 0.649 ms | 0.005 / 0.003 / 0.019 / 0.651 ms | 0.005 / 0.003 / 0.020 / 0.655 ms |
| Idle at app cadence, CPU share of one core | 0.13% over 60 s | 0.11% over 60 s | 0.13% over 60 s |

One ledger per process (memory runs):

| Dataset | Run | Wall | Footprint before | After the scan | Steady (next tick) | Peak | Max RSS |
|---|---|---|---|---|---|---|---|
| large | cold | 21,591.8 ms | 6.5 MB | 281.4 MB | 281.5 MB | 585.9 MB | 609.2 MB |
| large | warm | 1,893.2 ms | 6.3 MB | 544.8 MB | 545.0 MB | 545.0 MB | 571.8 MB |
| medium | cold | 5,933.6 ms | 6.4 MB | 100.7 MB | 100.8 MB | 165.5 MB | 187.6 MB |
| medium | warm | 598.7 ms | 6.5 MB | 150.6 MB | 150.6 MB | 150.6 MB | 168.6 MB |
| small | cold | 342.9 ms | 6.5 MB | 24.9 MB | 24.9 MB | 24.9 MB | 52.0 MB |
| small | warm | 62.4 ms | 6.4 MB | 16.5 MB | 16.6 MB | 16.6 MB | 43.5 MB |

### 4.4 What the numbers say

- **Idle is cheap.** At the app's cadence with nothing new:
  - 0.11–0.13 % of one core, for every dataset;
  - no disk writes;
  - a 10-second tick costs 0.4–2.7 ms (median) and the hardware probes microseconds; battery is the costliest at about 0.65 ms every 5 s.
- **Background scans don't hold the main thread.**
  - Scanning runs on the ledger's serial queue. During a cold scan, the main actor was never late by more than 2.6 ms.
  - `ProviderServices.refreshUsage` **drops** a refresh requested while one runs (10 of 10 dropped), so ticks can't pile up.
  - The ledger queue itself doesn't coalesce: 10 direct calls run one after another. The app-level guard is the only backpressure.
  - **Not measured on the main thread:** the store publish after a refresh, and the popover update. The popover's *first* full render is 94–419 ms (below) and runs on the main thread.
- **Quit is held for a whole scan.**
  - `applicationWillTerminate` calls `Ledger.flush()`, a `queue.sync` behind any scan in flight.
  - 50 ms into a cold scan, quitting held the main thread **0.3 s (small), 4.2 s (medium) and 18 s (large)**.
  - Nothing cancels a scan.
- **New data costs a full summary.**
  - A tick with 10 new messages costs 12–54 ms (median), almost all of it summary recomputation: 10–51 ms alone, scenario 6.
  - The summary prices every 15-minute slot × model on any change (the #57 note on #8).
- **The JSON cache dominates launch, saves and wake.**

  | Dataset | Cache file | Warm launch (decode + refresh) | One save |
  |---|---|---|---|
  | medium | 13 MB | 0.40 s | 0.29 s |
  | large | 48 MB | 1.8 s | 1.2 s |

  - A save runs every 10 minutes while data changes, and on quit, **on the ledger queue**, so a tick that lands on a save waits for it.
  - That is every dataset's worst incremental tick: it wrote one cache's worth (72 ms, 0.34 s and 1.33 s).
  - **Wake** (1.3 s on large) is mostly that save. After 8 hours with new data, the wake refresh saves the cache (48 MB written). The full scan and summary are a small part of it; compare scenarios 5 and 6.
- **First scan and rebuild:**
  - **CPU-bound** on small and medium: about 36–39 MB/s of transcript, excluding the first cache save that the first refresh includes.
  - **I/O-sensitive** on large: 24.0 s of wall time for 18.6 s of CPU in this run, with the 610 MB read from disk (612 MB of disk reads). An earlier run, with the files still cached, took 18.4 s.
  - **Range: 18–24 s**, about 27–35 MB/s.
  - A rebuild (clear, lost key, or a cache version bump) costs the same as a first scan.
- **Memory grows with history, and a warm launch holds more than a cold scan.**

  | Dataset | Steady after a cold scan | Steady after a warm launch (this run) |
  |---|---|---|
  | medium | 101 MB, 3.4 KB per message | 151 MB, 5.0 KB per message |
  | large | 281 MB, 2.3 KB per message | 545 MB, 4.5 KB per message |

  - **Warm memory varied between runs:** 109–151 MB on medium, 380–545 MB on large. Cold memory was steady (281–289 MB on large).
  - The cold scan's peak on large is 586 MB, 2.08× its steady state.
  - The cache file is about 400–440 bytes per message.
  - Small is dominated by fixed costs (25 MB cold), so per-message figures there mean nothing.
- **The popover:**
  - Closed: only the strip is drawn, at 8 µs median.
  - Open: a full render (layout and draw) takes about 26 ms. The first one takes 94–419 ms, which is SwiftUI's first-use cost.
  - An open popover redraws on each store change (every 1 s sample). A full render is an upper bound for one update.
- **Hover:** the top-consumer list takes about 0.85 ms per refresh.

## 5. Proposed budgets (for the owner's decision)

**How the budgets were set:**
- Each is set from the measurement plus headroom, against a user-facing reason.
- Each applies to the large dataset unless stated: 120,000 messages, about 30 days of heavy use.
- They're **not enforced in CI**: a 3-core shared runner can't time reliably.
- **Proposed rule:** rerun `scripts/bench.sh` on the reference Mac before merging a change to `Ledger`, the cache, the summary or the samplers. Flag a breach, or a regression above 25 % in a median.

| # | Budget | Measured (run 3) | Status | Why this number |
|---|---|---|---|---|
| B1 | Idle CPU at the app's cadence ≤ **0.5 %** of one core | 0.11–0.13 % | met | a menu-bar monitor must not show up in Activity Monitor; about 4× headroom |
| B2 | Main thread held ≤ **16 ms** while a background refresh or scan runs | ≤ 2.6 ms (cold scan only) | met for scans; **not measured** for the post-refresh publish and popover update | one 60 Hz frame. The first popover render is a UI action under B11, not B2 |
| B3 | Quit holds the main thread ≤ **1 s** | 0.3 / 4.2 / 18 s | **fails** at medium and large | a quit that takes seconds looks hung |
| B4 | 10 s tick, nothing new: p95 ≤ **10 ms** | 3.4 ms | met | it runs 360 times an hour |
| B5 | Tick with new data, without a save: p95 ≤ **100 ms** | 86 ms | met, narrowly | runs every 10 s during active use |
| B6 | Cache save ≤ **0.5 s** (medium) / ≤ **2 s** (large) | 0.29 / 1.2 s | met | it blocks the ledger queue: ticks wait behind it |
| B7 | Warm launch, ledger part, ≤ **1 s** (medium) / ≤ **3 s** (large) | 0.40 / 1.8 s | met | totals should appear shortly after login |
| B8 | First scan or rebuild ≥ **20 MB/s** of transcript, excluding the first save | 27–39 MB/s | met | 30 days of heavy use indexed in under a minute |
| B9 | Resident memory ≤ **5 KB per logged message** (medium and large), and peak ≤ **2×** steady | 2.3–5.0 KB; cold peak **2.08×** on large; warm varies by run | **at the limit** (warm medium 5.0 KB) and **fails** on peak | in-memory state is per operation; this keeps 120,000 messages under about 600 MB |
| B10 | Cache file ≤ **500 B per logged message** | 400–440 B | met | the #55 growth (about 2.4×) left little room |
| B11 | Popover full render: median ≤ **50 ms**; first render ≤ **250 ms** | 26 ms; first 94–419 ms | median met; **first render fails** on large | redrawn while open; the first open should feel immediate |

## 6. Bottlenecks, ranked

1. **Quit waits for an in-flight scan (B3 fails).**
   - The main thread is held for the rest of the scan: up to 18 s on large.
   - It is worst on the first launch, after a clear, and after a version bump, which is exactly when a user is most likely to quit an app that looks busy.
   - [code] `main.swift` `applicationWillTerminate` → `Ledger.flush()` → `queue.sync`.
2. **Memory per message, and its warm-launch variance (B9).**
   - 281 MB resident after a cold scan on large, and 380–545 MB after a warm launch.
   - The cause isn't located yet: `Seen` per operation, links, slot maps, decoder overhead, or allocator behaviour after decoding a 48 MB JSON. It needs an allocation profile (Instruments) on the synthetic set before any change.
3. **JSON cache encode and decode:** 1.2–1.8 s per save, warm launch or wake on large, run on the ledger queue, so ticks wait.
   - This is ADR 0001 D6's revisit trigger 1: "#8 measures encode or decode cost above a budget the owner sets".
   - **Proposed budget:** B6 and B7. Both are met today, so this is a watch item, not a format change.
4. **A full summary on every change:** 35–51 ms per tick with new data on medium and large. It is the bulk of the active-use tick, and leaves B5 with little headroom.
5. **The first popover render on large (B11):** up to 419 ms on the main thread. It has been measured once per process, so it's noisy, and it needs confirming in the real app.
6. **First-scan throughput:** 27–39 MB/s, CPU-bound and I/O-sensitive on large. It meets B8.

**Not bottlenecks:** idle CPU, the no-change tick, full scans with nothing new, the hardware probes, the menu-bar strip and the hover list.

## 7. Proposed follow-up issues (none created; owner approval first)

Each has its own failing benchmark scenario to show the change.

1. **Quit must not wait for an in-flight scan.** Let a scan stop between files or lines when quit begins, and save what's counted. **Acceptance:** scenario 9b ≤ 1 s on large, the cache stays consistent, and the next launch resumes from saved marks (no double count, F-fixtures unchanged).
2. **Profile and explain ledger memory.** An allocation profile of the large set (cold and warm), a breakdown per structure, and why warm varies by run. **No code change** until the owner picks a target. **Acceptance:** a documented breakdown, and a B9 decision.
3. **Summary cost independent of slot count** (the #57 note). Sum per local day × model × window before pricing. **Acceptance:** scenario 6 ≤ 15 ms on large, and totals identical on every fixture.
4. **Saves off the tick path, or cheaper** (watch item, after 1–3). Only if B6 or B7 is breached, or a save is shown to delay ticks for users.
5. **The benchmark itself** (small):
   - a main-thread heartbeat around the post-refresh publish with an open popover (B2's gap);
   - several popover first renders, each in a fresh process (B11's noise).

**Not proposed:** no change to scanning (it meets B8) or idle work.

## 8. Offline, sleep and wake, cancellation (summary)

- **Offline:**
  - The usage path makes no network request in any scenario. Every request would have failed; the transports have no responses.
  - Quota polling is opt-in and outside this benchmark (§3).
- **Sleep and wake:**
  - Modelled (clock +8 h, the three newest files grown): the wake refresh is a full scan, a summary and, with new data after more than 10 minutes, a cache save. That's 0.3 s (medium) and 1.3 s (large), most of it the save.
  - The OS transition and network recovery aren't measured.
- **Cancellation:**
  - Ledger scans can't be cancelled.
  - `ProviderServices` drops overlapping usage refreshes, and drops results that arrive after a consent change (existing tests).
  - The quit path is the one place a long scan reaches the main thread (§6.1).
