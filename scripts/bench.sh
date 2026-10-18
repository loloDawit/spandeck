#!/bin/bash
# #8 performance baseline: runs PerformanceBenchTests once per synthetic dataset, each in its own process so the
# process-wide memory, CPU and I/O counters belong to one dataset, and records the environment beside the results.
# Synthetic data only, in a temporary sandbox: no real transcript, credential, setting, network request or app launch.
#
#   scripts/bench.sh [--out DIR] [--idle SECONDS] [small|medium|large ...]
#
# Default: all three datasets, no idle run, results in .build/bench/<UTC time>/. `--idle` adds a real-time idle run at
# the app's cadence to each dataset (it takes that long). Then: scripts/bench-report.py DIR
#
# Build: an optimized release configuration with testing enabled and DEBUG defined. The test target can't build
# without DEBUG, since some tests use debug-only code. That is not the shipped binary: debug-only code (the snapshot
# renderer, the hover log) is compiled in but stays off.
set -euo pipefail
cd "$(dirname "$0")/.."

out=""
idle=""
sets=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=$2; shift 2 ;;
        --idle) idle=$2; shift 2 ;;
        small|medium|large) sets+=("$1"); shift ;;
        *) echo "usage: scripts/bench.sh [--out DIR] [--idle SECONDS] [small|medium|large ...]" >&2; exit 2 ;;
    esac
done
[ ${#sets[@]} -gt 0 ] || sets=(small medium large)
out=${out:-.build/bench/$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
# Full test output goes here, not into $out: it contains local paths, and $out may be committed.
logs=.build/bench/logs/$(basename "$out")
mkdir -p "$logs"

# Runs one benchmark process and stops the whole run if it fails, so no result is missing or stale.
run() {
    local log=$1; shift
    if ! env "$@" swift test "${flags[@]}" --skip-build --filter "${FILTER}" >"$log" 2>&1; then
        echo "failed: $* (log: $log)" >&2
        grep -E "✘|error" "$log" | head -5 >&2
        exit 1
    fi
    grep -E "Test run with" "$log" || true
}

flags=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG)
swift build "${flags[@]}" --build-tests

# The environment, as JSON. Only machine and toolchain facts: no user name, host name, path or serial number.
python3 - "$out/env.json" "swift test ${flags[*]}" <<'PY'
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
    "build": sys.argv[2],
}
json.dump(env, open(sys.argv[1], "w"), indent=2)
PY

for d in "${sets[@]}"; do
    load_before=$(sysctl -n vm.loadavg)
    echo "== $d (load $load_before)"
    FILTER=PerformanceBenchTests run "$logs/$d.log" SPANDECK_BENCH_DATASET="$d" SPANDECK_BENCH_OUT="$out" \
        ${idle:+SPANDECK_BENCH_IDLE_SECONDS="$idle"}
    python3 - "$out/$d.json" "$load_before" "$(sysctl -n vm.loadavg)" <<'PY'
import json, sys
p, before, after = sys.argv[1:]
r = json.load(open(p)); r["load_average"] = {"before": before, "after": after}
json.dump(r, open(p, "w"), indent=2, sort_keys=True)
PY
done
# Memory: one ledger per process, on a dataset written by a separate process, so the generator's strings and the other
# scenarios' ledgers aren't in the footprint. The data folder is deleted afterwards.
for d in "${sets[@]}"; do
    data=$PWD/.build/bench/data-$d
    for mode in gen cold warm; do
        FILTER=PerformanceMemoryBenchTests run "$logs/$d-memory-$mode.log" SPANDECK_BENCH_DATASET="$d" \
            SPANDECK_BENCH_MODE="$mode" SPANDECK_BENCH_HOME="$data" SPANDECK_BENCH_OUT="$out"
    done
    rm -rf "$data"
done
echo "Results: $out (render with scripts/bench-report.py $out)"
