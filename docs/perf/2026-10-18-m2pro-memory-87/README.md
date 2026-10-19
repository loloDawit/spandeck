# Ledger memory profile (#87): Apple M2 Pro, 2026-10-18

Synthetic data only (the #8 generator). No real transcript, credential, setting, network request or app launch. Analysis
and figures: `docs/PERFORMANCE.md` §4.6.

## Figures of record: `run1/`
- **Command:** `scripts/bench-memory.sh --rounds 5 --out .build/bench/mem87-run1`, at commit `4d075f8` with no local
  changes (`env.json`). All 90 processes passed (5 rounds × 3 datasets × 6 modes, plus `gen`).
- **Untraced:** one ledger scenario per process, no debugger or profiler attached.
- **Build:** `swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`, as for #8: optimized, but not the shipped
  binary.
- **Render:** `scripts/bench-memory-report.py docs/perf/2026-10-18-m2pro-memory-87/run1` (output in `run1/report.md`).
- **Conditions:** load average 4.6–9.7 before each process (other work was running), and the system memory pressure
  level was **2 (warning) at every recorded phase**. Free pages were low throughout. The reference machine wasn't idle.
- Each file is `round-<n>/<dataset>-memory-<mode>.json`, with a `phases` list. Each phase has the footprint, its peak,
  `malloc_in_use` (bytes in live blocks), `malloc_allocated` (bytes the zones hold), `malloc_blocks` and
  `pressure_level`. Phases that ran a scan, load or save also have a 20 ms series `[ms, footprint, in use]`.

## Attribution: `profiles/`
- **Command:** `scripts/bench-memory-profile.sh DATASET MODE OUTDIR` (and `--tools LIST` for the tool checks), at the
  commit in `profiles/commit.txt` (its second line counts local changes in `Sources`, `Tests` and `scripts`).
- lldb stops the process at every phase (`Bench.hold`) and runs `heap -s`, `vmmap --summary` and `footprint`. File
  `<n>.<tool>.txt` belongs to phase `n` (0-based) of the JSON beside it. The home folder is replaced by `~`.
- `medium-cold/`, `medium-warm/`, `large-cold/`, `large-warm/`: the per-type breakdown.
- `large-warm-tools-*`: the same warm load with one tool at a time, or none (lldb stops only), to check whether the
  tools change the footprint. At this commit they didn't: 381–384 MB steady in every variant. Earlier exploratory runs
  on an uncommitted harness had shown drops under the tools; they weren't reproduced, so no such effect is claimed.
  Footprint under lldb still varies between runs (§4.6): use these runs for attribution, `run1/` for figures.
- `medium-repeat/`: 5 warm loads in one process, for the heap diff between "released 1" (phase 2) and "released 5"
  (phase 10). It ran after the others, at the same `Sources` and `Tests`, with one uncommitted edit to
  `scripts/bench-memory-report.py`, which doesn't run during profiling.
- `idle-app-cadence-*`: two untraced `idle` runs on large, 13 ticks 10 s apart (`SPANDECK_BENCH_TICKS=13
  SPANDECK_BENCH_TICK_MS=10000`), with the pressure level at every tick.
- Tool versions: `heap`, `vmmap` and `footprint` from macOS 26.5 (25F71); `lldb-2100.0.17.203` from Xcode 26.6 (17F113).

## Cache shape
Counted from freshly built large and medium caches (synthetic) by loading the JSON and counting `files`, `seen`,
`links`, distinct link targets, `slots` and `unread`. The counts are in §4.6. No cache file is committed.
