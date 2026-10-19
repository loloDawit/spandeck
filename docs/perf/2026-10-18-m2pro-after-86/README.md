# Results after #86 (PR #90): Apple M2 Pro, 2026-10-18

- **Top level:** run `run86e`, from `scripts/bench.sh --out .build/bench/run86e --idle 60 small medium large` at commit `832a160` with no local changes (see `env.json`). All 12 benchmark processes passed.
- **`ab-vs-main/`:** an interleaved A/B on the same machine and in the same session. `main` (`587f1c3`, before #86) and `new` (`832a160`) alternated, small then medium, two rounds each. Load average 3.1–4.4 throughout.
  - Built with the same flags (`-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`), each from its own worktree; one `PerformanceBenchTests` process per file.
  - The `main` side has no scenarios 9c/9d, which don't exist before #86.
- **`ab-vs-121aebd/`:** the same method on small, `old` (`121aebd`, before the review fixes) against `new` (`832a160`). Load average 4.7–5.0.
- **Compare:** `scripts/bench-ab.py ab-vs-main main new` and `scripts/bench-ab.py ab-vs-121aebd old new`.
- **Later commits:** they changed only comments, the indexing-progress count (once per file, not per line) and how the benchmark drops a heartbeat's last sample. They didn't touch the scan, checkpoint or save paths these figures measure, so the run wasn't repeated.
- **Not committed:** run `run86e-small-recheck` (small at `832a160`, load 5.6), and the full runs on `121aebd`, `83fa19b` and `86236c3`. They're summarized on PR #90.
