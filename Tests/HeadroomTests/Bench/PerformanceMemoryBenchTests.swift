import Darwin
import Foundation
import Testing
@testable import Headroom

/// #8 memory baseline: one ledger per process, so the footprint and its peak are the ledger's, not the generator's or
/// another scenario's. `scripts/bench.sh` runs three processes per dataset, in order, on one data folder under
/// `.build/bench`:
/// - `gen` writes the synthetic dataset;
/// - `cold` runs a first scan with no cache, then saves it;
/// - `warm` runs a launch on that cache.
///
/// #87 adds modes, each one process on a data folder that `gen` and `cold` prepared (`scripts/bench-memory.sh`):
/// - `repeat`: `SPANDECK_BENCH_REPEAT` (default 5) warm loads in a row, each ledger released before the next;
/// - `idle`: one warm load, then `SPANDECK_BENCH_TICKS` (default 30) refreshes with nothing new,
///   `SPANDECK_BENCH_TICK_MS` apart (default 0; the app's cadence is 10,000);
/// - `incremental`: one warm load, then 10, 100 and 1,000 new messages, each followed by a refresh. It appends to the
///   dataset and saves the cache, so it runs last;
/// - `cancel`: a cold scan in its own support folder, stopped as quit does (`requestStop`) `SPANDECK_BENCH_STOP_MS`
///   (default 50) into it; then the ledger is released, and a new one resumes from what the stop saved.
///
/// Every mode records phases: the footprint, its peak, and the allocator's own count of bytes in use and reserved
/// (`malloc_zone_statistics`). At each phase it calls `Bench.hold`, where `scripts/bench-memory-profile.sh` stops the
/// process under lldb to run `heap`, `vmmap` and `footprint`. Near the end of each mode, while its ledger is alive, a
/// diagnostic phase asks the allocator to return the free pages it can (`malloc_zone_pressure_relief`, which the app
/// never calls) and measures again. `cold` and `warm` end with the ledger released.
///
/// Skipped unless `SPANDECK_BENCH_MODE` and `SPANDECK_BENCH_HOME` are set.
@Suite(.serialized, .enabled(if: BenchDataset.memoryMode != nil))
struct PerformanceMemoryBenchTests {
    @Test func memory() async throws {
        let d = try #require(BenchDataset.selected), mode = try #require(BenchDataset.memoryMode)
        let e = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(e["SPANDECK_BENCH_HOME"]))
        let home = root.appendingPathComponent("home"), support = root.appendingPathComponent("support")
        let out = URL(fileURLWithPath: e["SPANDECK_BENCH_OUT"] ?? NSTemporaryDirectory())
        let start = Bench.footprint().now

        // Every mode writes under the folder, and `gen` deletes it first, so only this package's own
        // `.build/bench/data-<letters>` is accepted: not a symlink, and with no `..` or symlinked parent leading elsewhere.
        try #require(BenchDataset.isBenchDataFolder(root), "SPANDECK_BENCH_HOME must be <package>/.build/bench/data-<letters>")
        if mode == "gen" {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try d.write(home: home, now: Date())
            return
        }
        let pricing = Pricing(directory: support, transport: FakeTransport())
        pricing.load()
        var phases: [[String: Any]] = []
        func phase(_ name: String, _ extra: [String: Any] = [:]) {
            Bench.hold(name)
            phases.append(Bench.memory().merging(["phase": name]) { a, _ in a }.merging(extra) { a, _ in a })
        }
        // The diagnostic last phase, taken while the mode's ledger is still alive.
        func relief() {
            let released = malloc_zone_pressure_relief(nil, 0)
            phase("after pressure relief (diagnostic)", ["relief_bytes": released])
        }
        phase("start")
        var report: [String: Any] = ["dataset": d.name, "mode": mode, "footprint_before": start]

        switch mode {
        case "cold", "warm":
            var timed: Bench.Sample?, after = (now: UInt64(0), peak: UInt64(0)), steady = after
            await {
                let ledger = Ledger(home: home, appSupport: support, pricing: pricing)
                let sampler = MemorySampler()
                timed = await Bench.measure { await Self.refresh(ledger) }
                phase("scanned", sampler.stop())
                ledger.flush()
                after = Bench.footprint()
                phase("saved")
                // A second, no-change refresh: the steady state the app sits in between ticks.
                await Self.refresh(ledger)
                steady = Bench.footprint()
                phase("steady")
                relief()
            }()
            phase("released")
            let sample = timed!
            var ru = rusage()
            getrusage(RUSAGE_SELF, &ru)
            report.merge(["wall_s": sample.wall, "cpu_s": sample.cpu, "footprint_after_scan": after.now,
                          "footprint_steady": steady.now, "footprint_peak": steady.peak,
                          "max_rss": Int(ru.ru_maxrss)]) { a, _ in a }
        case "repeat":
            let n = Int(e["SPANDECK_BENCH_REPEAT"] ?? "") ?? 5
            for i in 0..<n {
                // The ledger's scope ends with each iteration, so it is released before the next one loads.
                try await {
                    let ledger = Ledger(home: home, appSupport: support, pricing: pricing)
                    await Self.refresh(ledger)
                    phase("loaded \(i + 1)")
                    try #require(!ledger.isStopping)
                }()
                phase("released \(i + 1)")
            }
            relief()
        case "idle":
            let ledger = Ledger(home: home, appSupport: support, pricing: pricing)
            await Self.refresh(ledger)
            phase("loaded")
            let ticks = Int(e["SPANDECK_BENCH_TICKS"] ?? "") ?? 30
            let gap = UInt64(Int(e["SPANDECK_BENCH_TICK_MS"] ?? "") ?? 0)
            var each: [UInt64] = [], levels: [Int] = []
            for _ in 0..<ticks {
                if gap > 0 { try await Task.sleep(nanoseconds: gap * 1_000_000) }
                await Self.refresh(ledger)
                each.append(Bench.footprint().now)
                levels.append(Bench.pressureLevel())
            }
            phase("ticks \(ticks)", ["footprint_each_tick": each, "pressure_each_tick": levels, "tick_ms": gap])
            relief()
        case "incremental":
            let ledger = Ledger(home: home, appSupport: support, pricing: pricing)
            await Self.refresh(ledger)
            phase("loaded")
            var seq = 0
            for count in [10, 100, 1_000] {
                try BenchDataset.append(home: home, count: count, now: Date(), seq: &seq)
                let sampler = MemorySampler()
                let s = await Bench.measure { await Self.refresh(ledger) }
                phase("appended \(count)", sampler.stop().merging(["wall_s": s.wall, "written_bytes": s.written]) { a, _ in a })
            }
            relief()
        case "cancel":
            let fresh = root.appendingPathComponent("support-cancel")
            try? FileManager.default.removeItem(at: fresh)
            try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
            let delay = Int(e["SPANDECK_BENCH_STOP_MS"] ?? "") ?? 50
            var result: LedgerStopResult?
            try await {
                let ledger = Ledger(home: home, appSupport: fresh, pricing: pricing)
                async let scan: Void = Self.refresh(ledger)
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                result = await withCheckedContinuation { c in ledger.requestStop { c.resume(returning: $0) } }
                await scan
                phase("stopped", ["stop_ms": delay, "result": "\(result!)"])
            }()
            phase("released")
            let resumed = Ledger(home: home, appSupport: fresh, pricing: pricing)
            let sampler = MemorySampler()
            await Self.refresh(resumed)
            phase("resumed", sampler.stop())
            relief()
            withExtendedLifetime(resumed) {}
        default:
            Issue.record("unknown mode \(mode)")
        }

        report["phases"] = phases
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("\(d.name)-memory-\(mode).json"))
    }

    private static func refresh(_ ledger: Ledger) async {
        await withCheckedContinuation { c in
            ledger.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in c.resume() })
        }
    }
}

/// Samples the footprint and the allocator's bytes in use every 20 ms on its own thread, from creation until `stop`,
/// so a phase can say where its peak was: the series is [milliseconds since start, footprint, in use].
final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [[UInt64]] = []
    private var running = true
    private let t0 = DispatchTime.now().uptimeNanoseconds

    init() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                var s = malloc_statistics_t()
                malloc_zone_statistics(nil, &s)
                let row = [(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000, Bench.footprint().now, UInt64(s.size_in_use)]
                lock.withLock { samples.append(row) }
                usleep(20_000)
            }
        }
    }

    /// Stops sampling; returns the series and the largest in-use and footprint values in it.
    func stop() -> [String: Any] {
        let rows = lock.withLock { running = false; return samples }
        return ["series_ms_footprint_in_use": rows, "series_max_footprint": rows.map { $0[1] }.max() ?? 0,
                "series_max_in_use": rows.map { $0[2] }.max() ?? 0]
    }
}

extension Bench {
    /// The footprint, its peak, and the allocator's own figures for every zone: bytes in live blocks (`malloc_in_use`),
    /// bytes the zones hold from the system (`malloc_allocated`), and live blocks. Footprint minus in-use is what
    /// isn't a live allocation: free pages the allocator kept, page rounding, stacks, and other dirty memory. Also the
    /// system's memory pressure level (1 normal, 2 warning, 4 critical), which decides when free pages are taken back.
    static func memory() -> [String: Any] {
        var s = malloc_statistics_t()
        malloc_zone_statistics(nil, &s)
        let f = footprint()
        return ["footprint": f.now, "footprint_peak": f.peak, "malloc_in_use": s.size_in_use,
                "malloc_allocated": s.size_allocated, "malloc_blocks": s.blocks_in_use, "pressure_level": pressureLevel()]
    }

    static func pressureLevel() -> Int {
        var level: Int32 = 0, size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? Int(level) : 0
    }

    /// Where `scripts/bench-memory-profile.sh` stops the process (an lldb breakpoint on this function). Does nothing
    /// else; kept out of line and unoptimized so the call stays in a release build.
    @inline(never) @_optimize(none)
    static func hold(_ phase: String) { _ = phase }
}
