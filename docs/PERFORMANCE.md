# Performance baseline (#8)

**Status:** the first baseline, from the reference machine (one Apple M2 Pro). The budgets in §5 are **provisionally accepted** by the owner (2026-10-18): B3 is an accepted priority failure (#86), B9 waits for an allocation profile (#87), and B2 and B11 for better UI measurement (#88). Synthetic data only. No real transcript, credential, provider endpoint, setting or app launch was used, and the personal-account app was never run.

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

**Statistics:** median, p95 (nearest rank: the ⌈0.95·n⌉-th smallest) and worst, checked by `BenchStatsTests` in every `swift test`. The sample count *n* is in each cell. **With n ≤ 19, p95 is the worst sample**, so the cold-start, warm-start, save, full-scan, summary, wake and rebuild p95s (n = 3–10) say no more than their worst. Only the tick scenarios (n = 30) have a p95 below the worst. Datasets are generated once per process, and their generation isn't timed as a scenario.

**Scenarios** (per dataset):

| # | Scenario | Stands for | n |
|---|---|---|---|
| 1 | First scan with no cache, a new `Ledger` each time (it includes the first cache save) | **ledger** cold start (first run). Not an app launch | 5 (small) / 3 |
| 2 | A new `Ledger` on the saved cache, then its first refresh | **ledger** warm start (relaunch, login). Not an app launch | 5 |
| 3 | `refresh` with nothing new | the 10-second usage tick | 30 |
| 4 | 10 new messages (40 lines) appended to the hot file, then `refresh`. One untimed tick first takes the save a new ledger makes on its first change, so the timed ticks contain no save (checked: `samples_with_a_save`) | the tick while a session runs | 30 |
| 4b | `flush()` after a change | the cache save: every 10 min while running, and on quit | 10 |
| 5 | Clock +301 s, then `refresh` | the 5-minute full scan, nothing new | 10 |
| 6 | A new 5-hour window start | summary recomputation alone | 10 |
| 7 | **Simulated** wake: the clock moves 8 h (the machine doesn't sleep), the three newest files grow, then `refresh`. It also saves the cache, as the app's would | the work `didWakeNotification` → `refreshUsage` starts. Not the OS event | 5 |
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

## 4. Results: 2026-10-18, Apple M2 Pro (the reference machine)

**About this run (run 4):**
- Raw results: [`perf/2026-10-18-m2pro/`](perf/2026-10-18-m2pro/), produced by the committed harness (`56f5333`, no local changes) and rendered with `scripts/bench-report.py`.
- Runs 2 and 3 the same day, on earlier versions of the harness, aren't committed. §4.4 gives the range where runs differed by more than 15 %.
- **Load:** other work was running on the machine. The load average was about 3–4.5, and **rose to about 7 during the large set**, so large wall times are inflated (§4.4).

### 4.1 Environment and datasets

**Environment:** model `Mac14,10`, cpu `Apple M2 Pro`, cores `12`, memory_bytes `17179869184`, macos `26.5`, macos_build `25F71`, swift `Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)`, xcode `Xcode 26.6 Build version 17F113`, commit `56f5333e133f87dd191900db0b2578805dac9172`, build `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, power `Now drawing from 'AC Power'`

| Dataset | Transcripts | Messages | Lines | Bytes on disk | Grok turns | Load avg before → after |
|---|---|---|---|---|---|---|
| small | 10 | 2,000 | 8,000 | 10.2 MB | 100 | { 4.53 5.18 4.28 } → { 3.02 4.36 4.08 } |
| medium | 100 | 30,000 | 120,000 | 152.7 MB | 1,000 | { 3.02 4.36 4.08 } → { 2.84 3.64 3.82 } |
| large | 301 | 120,000 | 480,000 | 611.4 MB | 5,000 | { 2.84 3.64 3.82 } → { 4.31 7.15 6.61 } |


### 4.2 Latency

Wall time in ms: median / p95 / worst (n). CPU is the median, in ms. p95 is nearest-rank; with n ≤ 19 it is the worst sample.

| Scenario | small | medium | large |
|---|---|---|---|
| Ledger cold start: first scan, no cache (not app launch) | 290.8 / 314.7 / 314.7 (5); CPU 290.3 | 4,349.2 / 4,386.1 / 4,386.1 (3); CPU 4,325.5 | 32,711.6 / 72,138.8 / 72,138.8 (3); CPU 19,480.7 |
| Ledger warm start: cache load + first refresh (not app launch) | 44.4 / 45.7 / 45.7 (5); CPU 44.2 | 408.8 / 456.0 / 456.0 (5); CPU 408.7 | 1,799.7 / 1,997.4 / 1,997.4 (5); CPU 1,790.4 |
| 10 s tick, nothing new | 0.5 / 0.7 / 0.8 (30); CPU 0.5 | 1.1 / 1.3 / 1.5 (30); CPU 1.1 | 3.0 / 3.4 / 7.4 (30); CPU 3.0 |
| 10 s tick, 10 new messages (no save) | 11.4 / 11.9 / 12.0 (30); CPU 11.4 | 37.1 / 38.0 / 39.0 (30); CPU 37.0 | 56.0 / 59.6 / 61.7 (30); CPU 54.8 |
| Cache save (`flush`) | 28.7 / 32.1 / 32.1 (10); CPU 28.4 | 296.2 / 315.0 / 315.0 (10); CPU 295.0 | 1,385.2 / 1,485.0 / 1,485.0 (10); CPU 1,355.6 |
| 5 min full scan, nothing new | 0.5 / 0.8 / 0.8 (10); CPU 0.6 | 2.1 / 2.7 / 2.7 (10); CPU 2.1 | 6.2 / 7.2 / 7.2 (10); CPU 6.3 |
| Summary only (window change) | 10.6 / 11.3 / 11.3 (10); CPU 10.5 | 35.9 / 39.1 / 39.1 (10); CPU 35.9 | 53.3 / 80.4 / 80.4 (10); CPU 53.1 |
| Simulated wake, clock +8 h (full scan, 3 files grew, cache save) | 45.7 / 54.4 / 54.4 (5); CPU 44.9 | 350.0 / 353.7 / 353.7 (5); CPU 347.5 | 1,428.0 / 1,652.7 / 1,652.7 (5); CPU 1,406.6 |
| Rebuild after Clear cached usage data | 374.9 / 382.1 / 382.1 (5); CPU 372.0 | 4,283.5 / 4,675.9 / 4,675.9 (3); CPU 4,271.3 | 22,305.3 / 23,334.7 / 23,334.7 (3); CPU 18,419.8 |

### 4.3 Memory, I/O, main thread, rendering, idle

| Measure | small | medium | large |
|---|---|---|---|
| Bytes scanned, first scan | 10.2 MB | 152.5 MB | 610.3 MB |
| Cache file | 1.2 MB | 13.1 MB | 47.9 MB |
| Disk written, first scan (median) | 1.2 MB | 13.1 MB | 47.9 MB |
| Incremental tick samples that saved the cache (want 0) | 0 | 0 | 0 |
| First change after a ledger start: wall / written (it saves the cache) | 40.3 ms / 1.2 MB | 319.9 ms / 13.1 MB | 1,671.0 ms / 47.9 MB |
| Disk written, wake (median) | 1.3 MB | 13.3 MB | 48.1 MB |
| Disk written, one cache save (median) | 1.3 MB | 13.2 MB | 48.0 MB |
| Disk read, first scan (median; file cache warm) | 0.0 MB | 0.0 MB | 613.9 MB |
| All-scenario process: footprint peak (incl. generator, several ledgers) | 85.8 MB | 390.2 MB | 949.9 MB |
| 10 refreshes at once (ledger queue) | 17.1 ms | 46.9 ms | 316.5 ms |
| Quit (`flush`) 50 ms into a cold scan: main thread blocked | 314.5 ms | 4,180.2 ms | 19,688.0 ms |
| Hover top consumers, cpu / memory (median) | 0.89 / 0.99 ms | 0.93 / 0.93 ms | 1.58 / 1.56 ms |
| App refreshes dropped while one runs | 10 of 10 | 10 of 10 | 10 of 10 |
| Main-actor lateness during a cold scan, p95 / worst | 1.3 / 1.3 ms | 1.3 / 1.9 ms | 1.3 / 4.6 ms |
| Menu-bar strip render, median / worst | 0.008 / 28.7 ms | 0.009 / 36.0 ms | 0.008 / 49.5 ms |
| Popover full render, median / worst (first) | 27.6 / 102.9 ms | 26.4 / 104.2 ms | 31.4 / 359.3 ms |
| Sampler cpu / memory / gpu / battery (median) | 0.005 / 0.003 / 0.019 / 0.669 ms | 0.006 / 0.003 / 0.021 / 0.647 ms | 0.005 / 0.003 / 0.021 / 0.717 ms |
| Idle at app cadence, CPU share of one core | 0.13% over 60 s | 0.11% over 60 s | 0.17% over 60 s |

One ledger per process (memory runs):

| Dataset | Run | Wall | Footprint before | After the scan | Steady (next tick) | Peak | Max RSS |
|---|---|---|---|---|---|---|---|
| large | cold | 21,775.1 ms | 6.5 MB | 278.7 MB | 278.9 MB | 586.0 MB | 604.8 MB |
| large | warm | 1,868.8 ms | 6.2 MB | 376.4 MB | 376.7 MB | 536.4 MB | 530.5 MB |
| medium | cold | 5,882.1 ms | 6.3 MB | 100.2 MB | 100.4 MB | 167.6 MB | 191.0 MB |
| medium | warm | 496.2 ms | 6.4 MB | 148.5 MB | 148.6 MB | 148.6 MB | 175.5 MB |
| small | cold | 323.5 ms | 6.4 MB | 24.4 MB | 24.5 MB | 24.5 MB | 51.6 MB |
| small | warm | 61.1 ms | 6.4 MB | 17.0 MB | 17.0 MB | 17.0 MB | 44.0 MB |

### 4.4 What the numbers say

- **Idle is cheap.** At the app's cadence with nothing new:
  - 0.11–0.17 % of one core, for every dataset;
  - no disk writes;
  - a 10-second tick costs 0.5–3.0 ms (median) and the hardware probes microseconds; battery is the costliest at about 0.7 ms every 5 s.
- **Background scans don't hold the main thread.**
  - Scanning runs on the ledger's serial queue. During a cold scan, the main actor was never late by more than 4.6 ms.
  - `ProviderServices.refreshUsage` **drops** a refresh requested while one runs (10 of 10 dropped), so ticks can't pile up.
  - The ledger queue itself doesn't coalesce: 10 direct calls run one after another. The app-level guard is the only backpressure.
  - **Not measured on the main thread:** the store publish after a refresh, and the popover update (#88). The popover's *first* full render is 103–359 ms (below) and runs on the main thread.
- **Quit is held for a whole scan.**
  - `applicationWillTerminate` calls `Ledger.flush()`, a `queue.sync` behind any scan in flight.
  - 50 ms into a cold scan, quitting held the main thread **0.3 s (small), 4.2 s (medium) and 19.7 s (large)**.
  - Nothing cancels a scan (#86).
- **New data costs a full summary.**
  - A tick with 10 new messages (no save) costs 11–56 ms (median): p95 59.6 ms and worst 61.7 ms on large.
  - Almost all of it is summary recomputation: 11–53 ms alone, scenario 6. The summary prices every 15-minute slot × model on any change (the #57 note on #8).
- **The first change after a ledger start saves the whole cache.** A ledger that hasn't saved yet saves on its first change, so the first tick with new data after a launch takes 40 ms, 0.32 s or 1.67 s, and writes one cache's worth.
- **The JSON cache dominates warm starts, saves and wake.**

  | Dataset | Cache file | Warm start (decode + refresh) | One save | Simulated wake |
  |---|---|---|---|---|
  | medium | 13 MB | 0.41 s | 0.30 s | 0.35 s |
  | large | 48 MB | 1.8 s | 1.4 s | 1.4 s |

  - A save runs every 10 minutes while data changes, and on quit, **on the ledger queue**, so a tick that lands on a save waits for it.
  - After 8 simulated hours with new data, the wake refresh saves the cache (48 MB written). The full scan and summary are a small part of it; compare scenarios 5 and 6.
- **First scan and rebuild** (a rebuild is a clear, a lost key, or a cache version bump; it costs the same as a first scan):
  - **CPU time is the steady measure:** 17.0–19.5 s on large across runs 2–4, and 4.2–4.3 s on medium. That is about 34–38 MB/s of transcript, excluding the first cache save.
  - **Wall time on large is I/O- and load-sensitive.** The transcripts were read from disk (614 MB). Wall time was 18.4 s (run 2), 24.0 s (run 3) and 32.7 s median, worst 72 s (run 4, load about 7). Under that load, wall-time throughput on large fell to about 20 MB/s.
- **Memory grows with history, and a warm start holds more than a cold scan.**

  | Dataset | Steady after a cold scan | Steady after a warm start | Peak |
  |---|---|---|---|
  | medium | 100 MB, 3.3 KB per message | 149 MB, 5.0 KB per message | cold 168 MB |
  | large | 279 MB, 2.3 KB per message | 377 MB, 3.1 KB per message | cold 586 MB (**2.10×** steady); warm 536 MB |

  - **Across runs 2–4:** warm steady on large was 377–545 MB and on medium 109–151 MB. Cold steady on large was 279–289 MB. Explaining that variance is #87.
  - The cache file is about 400–440 bytes per message.
  - Small is dominated by fixed costs (24 MB cold), so per-message figures there mean nothing.
- **The popover:**
  - Closed: only the strip is drawn, at 8 µs median.
  - Open: a full render (layout and draw) takes 26–31 ms. The first one is 103–359 ms (SwiftUI's first-use cost), one sample per process (#88).
  - An open popover redraws on each store change (every 1 s sample). A full render is an upper bound for one update.
- **Hover:** the top-consumer list takes about 0.9 ms per refresh (1.6 ms under the large set's load).

### 4.5 After #86: non-blocking quit

**Run:**
- `run86e`, on the reference machine (Apple M2 Pro, `Mac14,10`, 12 cores, 16 GB, macOS 26.5 `25F71`, Swift 6.3.3, Xcode 26.6), at commit `832a160` with no local changes.
- Raw results: [`perf/2026-10-18-m2pro-after-86/`](perf/2026-10-18-m2pro-after-86/), whose README gives the provenance. All 12 benchmark processes passed.
- Load average 3.7–10.6, given per dataset in the JSON. Small ran first, under the most load.

**Which numbers are which:**
- Every figure below was **measured** by the benchmark.
- **Simulated:** none of these scenarios is simulated. Simulated wake (§2) is a separate scenario.
- **Not measured:** AppKit's own termination after the reply, and logout or restart (§3).
- The quit runs through `ShutdownCoordinator` and `Ledger.requestStop`, the app's path since #86. The coordinator's 5 s timer was armed in every run, and none fired.

**Main thread and quit time.** 9c quits 50 ms into a cold scan. 9d quits with every operation held and unsaved changes, the longest save a quit can wait for.

| Quit | small | medium | large |
|---|---|---|---|
| **Before #86** (9b, `flush` → `queue.sync`), 50 ms into a cold scan: main thread blocked | 0.42 s | 4.3 s | **18.0 s** |
| **9c**, 50 ms into a cold scan: `begin` on main | 0.074 ms | 0.047 ms | 0.047 ms |
| … heartbeat late, worst (n beats) | 1.05 ms (4) | 1.06 ms (5) | 1.07 ms (8) |
| … cancellation latency (the scan was still running when the quit began: checked) | 17 ms | 24 ms | 42 ms |
| … save / total to the reply | 6 / 23 ms | 6 / 30 ms | 7 / 48 ms |
| **9d**, with the whole cache to save: `begin` on main | 0.043 ms | 0.033 ms | 0.038 ms |
| … heartbeat late, worst (n beats) | 1.15 ms (7) | 1.07 ms (57) | 1.13 ms (233) |
| … save = total to the reply (cache size) | 42 ms (1.4 MB) | 0.34 s (13 MB) | **1.39 s** (48 MB) |
| Outcome, every quit | saved | saved | saved |

Each 9c and 9d value is **one quit per dataset** (n = 1). The heartbeat columns give the samples inside that quit.
- At `832a160` the last sample, the sleep that the end of the quit cancels, was still included; later commits drop it.
- A cancelled sleep is always shorter than a full one, so it can lower the minimum but never raise the worst.
- 9c's quits last only 23–48 ms, so they hold 4–8 beats.
- 9d's large quit holds 233, and is the stronger evidence for the main actor staying responsive.
- `begin` is the synchronous call from `applicationShouldTerminate`. The hop that delivers the reply, AppKit's own run loop while it waits, and the termination itself aren't in these figures.

- **B3 passes.** The main thread is held at most 0.074 ms, against the 1 s budget, and in these quits the main actor was never late by more than 1.15 ms.
- **Total quit time** while AppKit keeps the event loop running was 1.39 s on large with the full 48 MB to save (9d, measured).
  - **The worst case is analysed, not measured.** A quit can also wait for work that has no checkpoint: decoding the cache at the first refresh (about 1.6 s on large, the warm-start figure), a save already under way, or one very long line.
  - The stop's own save then follows only if something is still unsaved. A quit during a periodic save finds it saved, so it doesn't save twice.
  - The worst case on large is therefore about one decode plus one save, about 3 s, still under the 5 s timeout on this machine. A slower disk or a larger cache could reach the timeout. The previous cache then stays valid, and what wasn't saved is read again at the next launch.
- **Before #86** the main thread was blocked for the rest of the scan: 18.0 s on large.

**Scan throughput and accounting cost.**
- **Interleaved A/B** (`ab-vs-main/`, reproduce with `scripts/bench-ab.py <dir> main new`). Pre-#86 `main` (`587f1c3`) and `832a160` alternated, two rounds each, on the same machine and in the same session, at a load average of 3.1–4.4. Commits, order and each run's load are in its `provenance.json`, written from the run log afterwards. Each side's CPU median is averaged over its two rounds. **Two rounds per side** can show no change to within a few per cent; they can't resolve smaller differences.
  - **Within ±4.4 %:** every scenario on small and medium (cold start, rebuild, warm start, save, both ticks, summary and simulated wake), except one.
  - **The exception:** medium's 5-minute full scan with nothing new, −40.5 %. It is a 2–5 ms figure whose `main` side alone varied from 2.2 to 4.9 ms between rounds: noise.
  - **First-scan throughput:** 36.8 → 37.2 MB/s (small) and 36.6 → 37.3 MB/s (medium). The script computes it as the bytes scanned divided by the cold-start CPU minus the first save's CPU, in 10⁶ bytes, the mean over rounds.
- **The review fixes alone** (`ab-vs-121aebd/`, small, `scripts/bench-ab.py <dir> old new`): every scenario −7.2 % to +1.7 %, and the negative end is faster (the no-change tick and simulated wake). Throughput 36.7 → 37.2 MB/s.
- **The final head against the benchmarked commit** (`ab-final-vs-832a160/`, `scripts/bench-ab.py <dir> base final`).
  - `e8d6ec4` and `832a160` alternated, two rounds each, at a load average of 3.0–3.5. Each file carries an `ab` block: commit, whether `Sources`/`Tests` had local changes (none), load, status.
  - The later commits changed the scan loop's progress counting (one set and one lookup per file) and moved `flush` behind `DEBUG`.
  - Every scenario was within −4.6 % to +8.0 %. The +8.0 % is the 0.44 ms no-change tick on small; medium's simulated wake was +6.2 %.
  - Throughput 37.0 → 37.8 MB/s (small) and 38.8 → 38.3 MB/s (medium).
- **Against run 4** (a different time and load), run86e's large set is 4.9–12.8 % *faster* in CPU, 37.2 against 33.7 MB/s, and medium within ±10 %.
  - **Small was slower in run86e:** cold start +13.4 %, warm start +10.7 %, rebuild +5.1 %, 5-minute full scan +17.9 %, no-change tick +30.7 % (a 0.5 ms figure), and throughput 38.8 → 33.7 MB/s.
  - A recheck at a load of 5.6 gave cold start +12.8 %. Both ran under more load than run 4: 8.4–10.6 and 5.6.
  - The interleaved A/Bs, which hold the load equal, found no such slowdown: small within ±4.2 % of `main`, and within ±8 % between the final head and `832a160`. With two rounds each, they rule out a change of this size, not a few per cent.
  - Large has no A/B. Its comparison is across runs only.

**Timeout and failure behaviour** are verified by tests, not by this benchmark:
- `ShutdownCoordinatorTests`:
  - the 5 s timeout replies `timedOut`, and a late result changes nothing;
  - with a 0.2 s timer, the real timer fires;
  - one request gets one reply; a request after the outcome is answered at once.
- `ShutdownTests`:
  - a failed save reports `failed`, keeps the previous cache byte for byte, and leaves no temporary file;
  - a save under way when the quit arrives is waited for on the ledger queue, never on the caller;
  - relaunch matches an uninterrupted scan at every interruption point.

**Checkpoint limits** (also in `Ledger.Checkpoint`): a stop can't interrupt the cache decode at the first refresh, one line however long, mapping a file and hashing its anchor (at most 72 KiB), the hot-file listing between full scans, or a save already under way. The 17–42 ms cancellation latency above is for the synthetic dataset, which has no very long lines.

**Not measured:** AppKit's own termination after the reply, logout or restart, and quitting from the real app. Those need the owner's run in a test account (§3).
- The stop is for the rest of the process. If the system didn't terminate after the reply (not expected once an app agrees), usage would stop updating until a relaunch.
- The app registers one reply per termination and relies on AppKit pairing it with the one pending `.terminateLater`.

## 5. Budgets

### 5.1 Owner decisions (2026-10-18)

- **B1–B11 are provisionally accepted.**
- **B3 is an accepted priority failure.** Tracked in #86 (P1).
- **B9 needs an allocation profile before a final memory budget.** Tracked in #87 (P1, investigation only).
- **B2 and B11 need better UI measurement.** Tracked in #88.
- **Reference machine:** this Apple M2 Pro (`Mac14,10`, 12 cores, 16 GB, macOS 26.5).
- **A regression above 25 % in a median requires investigation, not automatic rejection.**
- **No timing threshold is enforced on shared GitHub Actions runners.** The 3-core `macos-15` runners can't time reliably. CI runs `BenchStatsTests` only, which checks the statistics and the data-folder guard; it times nothing.
- **Rule of use:** rerun `scripts/bench.sh` on the reference machine before merging a change to `Ledger`, the cache, the summary or the samplers, and compare with `perf/`.

### 5.2 Budget table

Each budget is set from the measurement plus headroom, against a user-facing reason. It applies to the large dataset unless stated: 120,000 messages, about 30 days of heavy use.

| # | Budget (provisional) | Measured (run 4) | Status | Why this number |
|---|---|---|---|---|
| B1 | Idle CPU at the app's cadence ≤ **0.5 %** of one core | 0.11–0.17 % | met | a menu-bar monitor must not show up in Activity Monitor; about 3× headroom |
| B2 | Main thread held ≤ **16 ms** while a background refresh or scan runs | ≤ 4.6 ms (cold scan only) | met for scans; **post-refresh publish not measured** (#88) | one 60 Hz frame. The first popover render is a UI action under B11 |
| B3 | Quit holds the main thread ≤ **1 s** | 0.3 / 4.2 / 19.7 s; **since #86: ≤ 0.074 ms** (§4.5) | was an accepted priority failure; **met with #86** (PR #90, pending merge) | a quit that takes seconds looks hung |
| B4 | 10 s tick, nothing new: p95 ≤ **10 ms** | 3.4 ms | met | it runs 360 times an hour |
| B5 | Tick with new data, **excluding cache saves**: p95 ≤ **100 ms** | 59.6 ms; no timed sample saved (checked) | met | runs every 10 s during active use. Saves are B6; the first change after a start (1.67 s, it saves) is reported apart |
| B6 | Cache save ≤ **0.5 s** (medium) / ≤ **2 s** (large) | 0.30 / 1.4 s | met | it blocks the ledger queue: ticks wait behind it |
| B7 | **Ledger** warm start ≤ **1 s** (medium) / ≤ **3 s** (large) | 0.41 / 1.8 s | met (app launch not measured) | totals should appear shortly after login |
| B8 | First scan or rebuild ≥ **20 MB/s** of transcript, excluding the first save | 34–38 MB/s on CPU time; about 20 MB/s wall time on large under a load average of 7 | met on CPU time; **marginal** on wall time under load | 30 days of heavy use indexed in under a minute |
| B9 | Resident memory ≤ **5 KB per logged message** (medium and large), and peak ≤ **2×** steady | 2.3–5.0 KB; cold peak **2.10×** on large; warm varies by run | **provisional**: at the limit (warm medium) and fails on peak. Final budget after #87 | in-memory state is per operation; this keeps 120,000 messages under about 600 MB |
| B10 | Cache file ≤ **500 B per logged message** | 400–440 B | met | the #55 growth (about 2.4×) left little room |
| B11 | Popover full render: median ≤ **50 ms**; first render ≤ **250 ms** | 26–31 ms; first 103–359 ms (one sample per process) | median met; **first render fails** on large; needs repeated measurement (#88) | redrawn while open; the first open should feel immediate |

## 6. Bottlenecks, ranked

1. **Quit waited for an in-flight scan (B3). Addressed by #86 (PR #90, pending merge).**
   - The main thread was held for the rest of the scan: up to 19.7 s on large.
   - Now the scan stops at a checkpoint and saves on the ledger queue while AppKit waits. The main thread is held ≤ 0.074 ms, and quitting takes at most 1.39 s on large (§4.5).
2. **Memory per message, and its warm-start variance (B9, #87).**
   - 279 MB resident after a cold scan on large, and 377–545 MB after a warm start.
   - The cause isn't located yet.
3. **JSON cache encode and decode:** 1.4–1.8 s per save, warm start, simulated wake or first change after a start, on large. It runs on the ledger queue, so ticks wait.
   - This is ADR 0001 D6's revisit trigger 1: "#8 measures encode or decode cost above a budget the owner sets".
   - B6 and B7 are met today, so this is a watch item, not a format change.
4. **A full summary on every change:** 36–53 ms per tick with new data on medium and large. It is the bulk of the active-use tick; B5 is met with about 40 % headroom.
5. **The first popover render on large (B11, #88):** up to 359 ms on the main thread, one sample per process.
6. **First-scan throughput:** CPU-bound at 34–38 MB/s, with wall time on large sensitive to disk reads and load (B8).

**Not bottlenecks:** idle CPU, the no-change tick, full scans with nothing new, the hardware probes, the menu-bar strip and the hover list.

## 7. Follow-up issues

**Created 2026-10-18 with owner approval.** Each is a sub-issue of #8 in M0, workstream Performance. **None is an M0 exit criterion.**
- **#86** *Non-blocking shutdown during an active ledger scan* (P1). Investigate safe cancellation, durable cache state, resumability and no double counting before any fix. "Stop and flush partial state" is not assumed safe.
- **#87** *Profile ledger memory across cold and warm loads* (P1). Investigation only, with an allocation profile on synthetic data.
- **#88** *Complete UI performance measurement*: post-refresh publishing on the main thread, and repeated first popover renders, in safe harnesses.

**Proposed, not created:**
- the summary cost independent of slot count (the #57 note; acceptance: scenario 6 ≤ 15 ms on large, totals identical on every fixture);
- saves off the tick path, a watch item.

**No optimization PR** until the owner decides.

## 8. Offline, sleep and wake, cancellation (summary)

- **Offline:**
  - The usage path makes no network request in any scenario. Every request would have failed; the transports have no responses.
  - Quota polling is opt-in and outside this benchmark (§3).
- **Sleep and wake are simulated:** the clock moves 8 h and the three newest files grow. The machine doesn't sleep, and no `didWakeNotification` fires.
  - The work the wake handler starts is a full scan, a summary and, with new data after more than 10 minutes, a cache save: 0.35 s (medium) and 1.4 s (large), most of it the save.
  - The OS transition and network recovery aren't measured.
- **Cancellation (since #86):**
  - A scan stops at checkpoints: before the scan, every 256 listed entries, between files, every 2048 lines or 4 MB inside a file, and between Grok files.
  - Only quitting requests a stop. A stopped ledger never scans again, and its refreshes publish nothing.
  - `ProviderServices` still drops overlapping usage refreshes, and results that arrive after a consent change.
