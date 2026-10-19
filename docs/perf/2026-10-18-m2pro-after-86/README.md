# Results after #86 (PR #90): Apple M2 Pro, 2026-10-18

- **Top level:** run `run86e`, from `scripts/bench.sh --out .build/bench/run86e --idle 60 small medium large` at commit `832a160` with no local changes (see `env.json`). All 12 benchmark processes passed.
- **`ab-vs-main/`:** an interleaved A/B on the same machine and in the same session. `main` (`587f1c3`, before #86) and `new` (`832a160`) alternated, small then medium, two rounds each. Load average 3.1–4.4 throughout.
  - Built with the same flags (`-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG`), each from its own worktree; one `PerformanceBenchTests` process per file.
  - The `main` side has no scenarios 9c/9d, which don't exist before #86.
- **`ab-vs-121aebd/`:** the same method on small, `old` (`121aebd`, before the review fixes) against `new` (`832a160`). Load average 4.7–5.0.
- **`ab-final-vs-832a160/`:** the final head `e8d6ec4` (`final`) against `832a160` (`base`), small and medium, two rounds each, at a load average of 3.0–3.5. Every file carries an `ab` block: commit, local changes in `Sources`/`Tests` (none), load before and after, status, build.
- **Provenance:**
  - `ab-vs-main/` and `ab-vs-121aebd/` have a `provenance.json`, written from the run log afterwards, since their JSON has no `ab` block.
  - Their `new` side is `832a160`; the other sides are `587f1c3` and `121aebd`.
- **Compare:** `scripts/bench-ab.py ab-vs-main main new`, `scripts/bench-ab.py ab-vs-121aebd old new` and `scripts/bench-ab.py ab-final-vs-832a160 base final`.
- **Later commits** (after `832a160`):
  - they changed the scan loop's indexing-progress count (one set and one lookup per file);
  - they moved `Ledger.flush` behind `DEBUG`;
  - they changed how the benchmark drops a heartbeat's last sample;
  - they changed comments.

  `ab-final-vs-832a160/` measures their cost. The full run wasn't repeated, so the top-level figures are `832a160`'s.
- **Heartbeat at `832a160`:** the top-level 9c/9d heartbeat statistics still include the last, cancelled sleep. It is never longer than a full sleep, so it can't raise the worst.
- **`ab-abba-final-vs-main/`:** the primary before/after comparison. The PR's final code `7bec306` (`final`) against `main` `587f1c3` (`main`), small and medium, in ABBA order per dataset (final, main, main, final). Every file carries an `ab` block. Compare with `scripts/bench-ab.py ab-abba-final-vs-main main final`.
- **`recheck-small/`:** run `run86e-small-recheck`, small only at `832a160` (load 5.6), quoted in `PERFORMANCE.md` §4.5.
- **Not committed:** the full runs on `121aebd`, `83fa19b` and `86236c3`, made while the PR was reviewed. They're superseded by run86e, and their quit figures are summarized in the PR #90 description.
