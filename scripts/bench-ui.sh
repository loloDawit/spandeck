#!/bin/bash
# #88 UI measurement: PerformanceUIBenchTests, one mode per process, on synthetic data under .build/bench/data-<dataset>.
# No app launch, no window shown on screen, no real transcript, credential, setting or network request.
#
#   scripts/bench-ui.sh [--out DIR] [--runs N] [small|medium|large ...]
#
# Default: all three datasets, 20 runs, results in .build/bench/ui-<UTC time>/. Once: `probe` (what the test process
# provides). Per dataset: gen and cold (PerformanceMemoryBenchTests, to write the dataset and its cache); then N fresh
# processes of `first` for each of `hosting` and `image`, alternated, so a change in machine load falls on both; then
# `publish`, which appends to the dataset, so it runs last. The data folder is deleted afterwards.
# Same build as scripts/bench.sh: release with testing and DEBUG, not the shipped binary.
# Then: scripts/bench-ui-report.py DIR
set -euo pipefail
cd "$(dirname "$0")/.."

out=""
runs=20
sets=()
while [ $# -gt 0 ]; do
    case "$1" in
        --out) out=$2; shift 2 ;;
        --runs) runs=$2; shift 2 ;;
        small|medium|large) sets+=("$1"); shift ;;
        *) echo "usage: scripts/bench-ui.sh [--out DIR] [--runs N] [small|medium|large ...]" >&2; exit 2 ;;
    esac
done
[ ${#sets[@]} -gt 0 ] || sets=(small medium large)
out=${out:-.build/bench/ui-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$out"
# Full test output goes here, not into $out: it contains local paths, and $out may be committed.
logs=.build/bench/logs/$(basename "$out")
mkdir -p "$logs"

flags=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG)
swift build "${flags[@]}" --build-tests

# The environment, as JSON. Only machine and toolchain facts: no user name, host name, path or serial number.
python3 - "$out/env.json" "swift test ${flags[*]}" "$runs" <<'PY'
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
    "build": sys.argv[2], "runs": int(sys.argv[3]),
}
json.dump(env, open(sys.argv[1], "w"), indent=2)
PY

# Runs one process; stops the whole run if it fails, so no result is missing or stale.
run() {
    local log=$1 filter=$2; shift 2
    if ! env "$@" swift test "${flags[@]}" --skip-build --filter "$filter" >"$log" 2>&1; then
        echo "failed: $* (log: $log)" >&2
        grep -E "✘|error" "$log" | head -5 >&2
        exit 1
    fi
}

# Adds the load average before and after the process to its result.
stamp() {
    python3 - "$1" "$2" "$(sysctl -n vm.loadavg)" <<'PY'
import json, sys
p, before, after = sys.argv[1:]
r = json.load(open(p)); r["load_average"] = {"before": before, "after": after}
json.dump(r, open(p, "w"), indent=2, sort_keys=True)
PY
}

run "$logs/probe.log" PerformanceUIBenchTests SPANDECK_BENCH_UI=probe SPANDECK_BENCH_OUT="$out"

for d in "${sets[@]}"; do
    data=$PWD/.build/bench/data-$d
    for mode in gen cold; do
        run "$logs/$d-$mode.log" PerformanceMemoryBenchTests SPANDECK_BENCH_DATASET="$d" SPANDECK_BENCH_MODE="$mode" \
            SPANDECK_BENCH_HOME="$data" SPANDECK_BENCH_OUT="$logs"
    done
    for i in $(seq 1 "$runs"); do
        for v in hosting image; do
            before=$(sysctl -n vm.loadavg)
            run "$logs/$d-first-$v-$i.log" PerformanceUIBenchTests SPANDECK_BENCH_UI=first SPANDECK_BENCH_UI_FIRST="$v" \
                SPANDECK_BENCH_UI_RUN="$i" SPANDECK_BENCH_DATASET="$d" SPANDECK_BENCH_HOME="$data" SPANDECK_BENCH_OUT="$out"
            stamp "$out/$d-ui-first-$v-$i.json" "$before"
        done
    done
    before=$(sysctl -n vm.loadavg)
    run "$logs/$d-publish.log" PerformanceUIBenchTests SPANDECK_BENCH_UI=publish SPANDECK_BENCH_DATASET="$d" \
        SPANDECK_BENCH_HOME="$data" SPANDECK_BENCH_OUT="$out"
    stamp "$out/$d-ui-publish.json" "$before"
    rm -rf "$data"
    echo "$d done (load $(sysctl -n vm.loadavg))"
done
echo "Results: $out (render with scripts/bench-ui-report.py $out)"
