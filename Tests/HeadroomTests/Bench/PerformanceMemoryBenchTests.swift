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
        let ledger = Ledger(home: home, appSupport: support, pricing: pricing)
        let sample = await Bench.measure {
            await withCheckedContinuation { c in
                ledger.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in c.resume() })
            }
        }
        ledger.flush()
        let after = Bench.footprint()
        // A second, no-change refresh: the steady state the app sits in between ticks.
        await withCheckedContinuation { c in
            ledger.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in c.resume() })
        }
        let steady = Bench.footprint()
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        let report: [String: Any] = [
            "dataset": d.name, "mode": mode, "wall_s": sample.wall, "cpu_s": sample.cpu,
            "footprint_before": start, "footprint_after_scan": after.now, "footprint_steady": steady.now,
            "footprint_peak": steady.peak, "max_rss": Int(ru.ru_maxrss),
        ]
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("\(d.name)-memory-\(mode).json"))
    }
}
