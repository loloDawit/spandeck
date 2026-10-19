#!/bin/bash
# #87 memory profile: PerformanceMemoryBenchTests, one ledger scenario per process, repeated, on synthetic data.
# Synthetic data only, under .build/bench/data-<dataset>: no real transcript, credential, setting, network request or
# app launch.
#
#   scripts/bench-memory.sh [--out DIR] [--rounds N] [small|medium|large ...]
#
# Default: all three datasets, 3 rounds, results in .build/bench/mem-<UTC time>/round-<n>/. Each round, per dataset:
# gen (writes the dataset), cold, warm, repeat, idle (30 ticks back to back), cancel, then incremental (it appends to
# the dataset, so it runs last; the next round's gen writes it again). Same build as scripts/bench.sh: release with testing and DEBUG, not the
# shipped binary. Untraced: these are the figures of record. scripts/bench-memory-profile.sh attributes them.
set -euo pipefail
cd "$(dirname "$0")/.."

out=""
rounds=3
sets=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=$2; shift 2 ;;
        --rounds) rounds=$2; shift 2 ;;
        small|medium|large) sets+=("$1"); shift ;;
        *) echo "usage: scripts/bench-memory.sh [--out DIR] [--rounds N] [small|medium|large ...]" >&2; exit 2 ;;
    esac
done
[ ${#sets[@]} -gt 0 ] || sets=(small medium large)
out=${out:-.build/bench/mem-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
# Full test output goes here, not into $out: it contains local paths, and $out may be committed.
logs=.build/bench/logs/$(basename "$out")
mkdir -p "$logs"

flags=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG)
swift build "${flags[@]}" --build-tests

# The environment, as JSON. Only machine and toolchain facts: no user name, host name, path or serial number.
python3 - "$out/env.json" "swift test ${flags[*]}" "$rounds" <<'PY'
import json, platform, subprocess, sys
def run(*a):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception: return ""
env = {
    "macos": run("sw_vers", "-productVersion"), "macos_build": run("sw_vers", "-buildVersion"),
    "arch": platform.machine(), "cpu": run("sysctl", "-n", "machdep.cpu.brand_string"),
    "cores": run("sysctl", "-n", "hw.ncpu"), "perf_cores": run("sysctl", "-n", "hw.perflevel0.physicalcpu"),
    "memory_bytes": run("sysctl", "-n", "hw.memsize"), "model": run("sysctl", "-n", "hw.model"),
    "swift": run("swift", "--version").splitlines()[0] if run("swift", "--version") else "",
    "xcode": " ".join(run("xcodebuild", "-version").splitlines()[:2]),
    "commit": run("git", "rev-parse", "HEAD"), "dirty": bool(run("git", "status", "--porcelain", "--", "Sources", "Tests")),
    "power": run("pmset", "-g", "batt").splitlines()[0] if run("pmset", "-g", "batt") else "",
    "build": sys.argv[2], "rounds": int(sys.argv[3]),
}
json.dump(env, open(sys.argv[1], "w"), indent=2)
PY

for r in $(seq 1 "$rounds"); do
    dir=$out/round-$r
    mkdir -p "$dir"
    for d in "${sets[@]}"; do
        data=$PWD/.build/bench/data-$d
        # cancel stops about halfway through the cold scan (#85 cold wall times: 0.3 s, 4.3 s, 22–33 s).
        case $d in small) stop=150 ;; medium) stop=2000 ;; large) stop=10000 ;; esac
        for mode in gen cold warm repeat idle cancel incremental; do
            log=$logs/$r-$d-$mode.log
            before=$(sysctl -n vm.loadavg)
            if ! env SPANDECK_BENCH_DATASET="$d" SPANDECK_BENCH_MODE="$mode" SPANDECK_BENCH_HOME="$data" \
                SPANDECK_BENCH_STOP_MS="$stop" SPANDECK_BENCH_OUT="$dir" \
                swift test "${flags[@]}" --skip-build --filter PerformanceMemoryBenchTests >"$log" 2>&1; then
                echo "failed: round $r $d $mode (log: $log)" >&2
                grep -E "✘|error" "$log" | head -5 >&2
                exit 1
            fi
            [ "$mode" = gen ] && continue
            python3 - "$dir/$d-memory-$mode.json" "$before" "$(sysctl -n vm.loadavg)" <<'PY'
import json, sys
p, before, after = sys.argv[1:]
r = json.load(open(p)); r["load_average"] = {"before": before, "after": after}
json.dump(r, open(p, "w"), indent=2, sort_keys=True)
PY
        done
        echo "round $r $d done (load $(sysctl -n vm.loadavg))"
    done
done
echo "Results: $out (render with scripts/bench-memory-report.py $out)"
