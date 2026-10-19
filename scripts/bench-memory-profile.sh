#!/bin/bash
# #87: attributes one memory scenario. Runs PerformanceMemoryBenchTests in one mode under lldb, which stops at every
# phase (`Bench.hold`) and runs heap(1), vmmap(1) --summary and footprint(1) against the process before it goes on.
# Synthetic data only. The data folder must be prepared first (gen, then cold, as scripts/bench-memory.sh does).
#
#   scripts/bench-memory-profile.sh [--tools "heap vmmap footprint"] DATASET MODE OUTDIR
#
# --tools picks which of the three run at each phase (default all three), to check whether a tool changes what it
# measures: `heap` and `vmmap` inspect the allocator's zones, `footprint` only asks the kernel.
# Writes OUTDIR/<n>.{heap,vmmap,footprint}.txt for the n-th phase (0-based, the order of `phases` in the mode's JSON,
# which is written to OUTDIR too), with the home folder replaced by ~. Under lldb the process is slower, and stopped
# while the tools run: use these for attribution, and scripts/bench-memory.sh for the figures of record.
set -euo pipefail
cd "$(dirname "$0")/.."
tools="heap vmmap footprint"
[ "${1:-}" = --tools ] && { tools=$2; shift 2; }
[ $# -eq 3 ] || { echo "usage: scripts/bench-memory-profile.sh [--tools LIST] DATASET MODE OUTDIR" >&2; exit 2; }
d=$1 mode=$2 snaps=$(mkdir -p "$3" && cd "$3" && pwd)
data=$PWD/.build/bench/data-$d
[ -d "$data/home" ] || { echo "no dataset at $data: run gen and cold first" >&2; exit 1; }

flags=(-c release -Xswiftc -enable-testing -Xswiftc -DDEBUG)
swift build "${flags[@]}" --build-tests >/dev/null
bin=$(swift build "${flags[@]}" --show-bin-path)/HeadroomPackageTests.xctest/Contents/MacOS/HeadroomPackageTests
dev=$(xcode-select -p)
helper=$(xcrun --find swift | sed 's#/bin/swift$##')/libexec/swift/pm/swiftpm-testing-helper
platform=$dev/Platforms/MacOSX.platform/Developer

# Runs the three tools against the process lldb is debugging (its only child), numbering each phase.
snap=$(mktemp -t spandeck-snap)
cat >"$snap" <<EOF
#!/bin/bash
n=\$(ls "$snaps"/*.txt 2>/dev/null | sed 's#.*/##; s#\\..*##' | sort -u | wc -l | tr -d ' ')
p=\$(pgrep -n -f "swiftpm-testing-helper --test-bundle-path $bin")
for t in $tools; do
    case \$t in heap) a=-s ;; vmmap) a=--summary ;; *) a= ;; esac
    \$t \$a "\$p" 2>&1 | sed "s#$HOME#~#g" >"$snaps/\$n.\$t.txt"
done
EOF
chmod +x "$snap"

lldb -b \
    -o "settings set target.env-vars DYLD_FRAMEWORK_PATH=$platform/Library/Frameworks DYLD_LIBRARY_PATH=$platform/usr/lib SPANDECK_BENCH_DATASET=$d SPANDECK_BENCH_MODE=$mode SPANDECK_BENCH_HOME=$data SPANDECK_BENCH_OUT=$snaps" \
    -o "breakpoint set -s HeadroomPackageTests -r 'Bench\.hold'" \
    -o "breakpoint command add -o 'platform shell $snap' 1" \
    -o "breakpoint modify --auto-continue true 1" \
    -o run \
    -- "$helper" --test-bundle-path "$bin" --filter PerformanceMemoryBenchTests "$bin" --testing-library swift-testing \
    >"$snaps/lldb.log" 2>&1
rm -f "$snap"
sed -i '' "s#$HOME#~#g" "$snaps/lldb.log"
grep -q "Test run with 1 test in 1 suite passed" "$snaps/lldb.log" || { echo "run failed: $snaps/lldb.log" >&2; exit 1; }
echo "$(ls "$snaps"/*.txt | sed 's#.*/##; s#\..*##' | sort -u | wc -l | tr -d ' ') phases in $snaps"
