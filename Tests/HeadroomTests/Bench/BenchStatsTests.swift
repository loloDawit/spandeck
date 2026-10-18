import Foundation
import Testing
@testable import Headroom

/// The benchmark's statistics and its data-folder guard. These always run (no environment needed), so CI checks them.
struct BenchStatsTests {
    @Test func medianP95Worst() {
        #expect(Bench.stats([]).isEmpty)
        let one = Bench.stats([4])
        #expect(one["median"] == 4 && one["p95"] == 4 && one["max"] == 4 && one["n"] == 1)
        let odd = Bench.stats([5, 1, 3])
        #expect(odd["median"] == 3 && odd["p95"] == 5 && odd["max"] == 5 && odd["min"] == 1) // n ≤ 19: p95 is the worst
        #expect(Bench.stats([4, 1, 3, 2])["median"] == 2.5)
        let thirty = Bench.stats((1...30).map(Double.init))
        #expect(thirty["p95"] == 29 && thirty["max"] == 30 && thirty["median"] == 15.5) // ⌈28.5⌉ = 29th smallest
        let twenty = Bench.stats((1...20).map(Double.init))
        #expect(twenty["p95"] == 19) // the first n where p95 isn't the worst
        #expect(Bench.stats((1...19).map(Double.init))["p95"] == 19)
    }

    @Test func dataFolderGuard() throws {
        let root = BenchDataset.benchRoot
        #expect(BenchDataset.isBenchDataFolder(root.appendingPathComponent("data-small")))
        for bad in ["data-", "data-Small", "data-../x", "data-a1", "other"] {
            #expect(!BenchDataset.isBenchDataFolder(root.appendingPathComponent(bad)), "\(bad)")
        }
        #expect(!BenchDataset.isBenchDataFolder(root.appendingPathComponent("../data-small")))
        // `..` that still lands in the bench folder is the same folder, so it's accepted.
        #expect(BenchDataset.isBenchDataFolder(root.appendingPathComponent("data-a/../data-b")))
        #expect(!BenchDataset.isBenchDataFolder(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("data-small")))
        #expect(!BenchDataset.isBenchDataFolder(URL(fileURLWithPath: "/tmp/x/.build/bench/data-small")))

        // A symlink named like a data folder is refused, even though its parent is right.
        let box = try Sandbox()
        let link = root.appendingPathComponent("data-linktest")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.root)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(!BenchDataset.isBenchDataFolder(link))
    }
}
