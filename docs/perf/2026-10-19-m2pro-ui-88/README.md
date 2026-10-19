# UI measurement (#88): Apple M2 Pro, 2026-10-19

Synthetic data only (the #8 generator; system, limit and plan values from `SnapshotFixture`). No app launch, no window
shown on screen, no real transcript, credential, setting change or network request. Analysis and figures:
`docs/PERFORMANCE.md` §4.7.

## Figures of record: `run1/`
- **Command:** `scripts/bench-ui.sh --runs 20 --out docs/perf/2026-10-19-m2pro-ui` (moved here afterwards), at commit
  `e1f1fcc` with no local changes in `Sources` or `Tests` (`env.json`). All 130 processes passed: `probe`, and
  per dataset `gen`, `cold`, 20 `first` processes for each of `hosting` and `image` (alternated), and `publish`.
- **Build:** `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, as for #8: optimized, but not the shipped
  binary.
- **Render:** `scripts/bench-ui-report.py docs/perf/2026-10-19-m2pro-ui-88/run1` (output in `run1/report.md`).
- **Conditions:** load average 3.3–11.8 before the `first` processes (other work was running), recorded in each file's
  `load_average`. The reference machine wasn't idle.
- **Files:**
  - `ui-probe.json`: what the test process provides (a running main run loop; whether a hosting view updates by itself).
  - `<dataset>-ui-first-<hosting|image>-<n>.json`: one fresh process each. `warm_start` (the first `refreshUsage`, popover
    closed), `first` (the first render, in steps for `hosting`), `reopen_*` and `close_ms` (20 more opens in the same
    process, each a new view tree).
  - `<dataset>-ui-publish.json`: one process per dataset. Per-tick distributions for the refresh-tick series
    (`tick_<closed|open>_<nothing_new|10_new>`, n = 30 each), `sample_tick_open` (n = 60), `sample_tick_open_forced`
    (n = 30), `cold_scan_open`, and the quiet floors.

## Attribution: `profiles/`
- **Command:** a separate `publish` process on small with `SPANDECK_BENCH_TICKS=100` (147.6 s, passed), at the same
  commit, sampled with macOS `sample <pid> <seconds> 1` (1 ms interval) twice: 35 s starting about 52 s in (the
  open-popover refresh ticks) and 22 s starting about 93 s in (the 1 s sample ticks). The windows were placed by elapsed
  time, so each may contain a little of the neighbouring phase.
- **Summaries:** `scripts/bench-ui-sample-report.py <sample file>`, which prints only counts per frame group. The raw
  `sample` reports aren't committed: they hold local paths and are 11 MB.
- The profiled process isn't one of the figures of record. `sample` stops the process 1,000 times a second, which adds
  its own cost, so its shares attribute time and its durations aren't used.
