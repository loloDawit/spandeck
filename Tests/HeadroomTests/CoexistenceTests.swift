import CryptoKit
import Foundation
import Testing
@testable import Headroom

/// #11: SpanDeck and upstream Headroom on one account. Headroom's state (its Application Support folder with a cache,
/// key and price files, and its hover log) is seeded with fixed bytes; SpanDeck indexes, relaunches, clears, fails to
/// save and rebuilds in its own folder, and every Headroom file keeps its bytes, mode and dates. SpanDeck never reads
/// Headroom's cache either: the seeded one holds usage SpanDeck must not count.
struct CoexistenceTests {
    private static func line(_ n: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req_\#(n)","message":{"id":"msg_\#(n)","model":"claude-test-1","usage":{"input_tokens":100,"output_tokens":50}}}"#
    }

    /// Path → (sha256, mode, modification date) of every file under `root`.
    private static func fingerprint(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in en {
            let a = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (a[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let date = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let sum = (a[.type] as? FileAttributeType) == .typeDirectory ? "dir"
                : SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            out[String(url.path.dropFirst(root.path.count))] = "\(sum) \(String(mode, radix: 8)) \(date)"
        }
        return out
    }

    @Test func headroomStateIsNeverTouched() async throws {
        let box = try Sandbox()
        let base = box.home.appendingPathComponent("Library/Application Support")
        let legacy = base.appendingPathComponent("Headroom")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        // A Headroom cache under the same file name SpanDeck uses, with 999,999 tokens SpanDeck must not count.
        try Data(#"{"version":7,"keyCheck":"0","files":{},"seen":{},"links":{},"slots":{"1":{"claude-test-1":{"input":999999,"output":0,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":1}}},"identity":{},"flawed":{},"unread":{}}"#.utf8)
            .write(to: legacy.appendingPathComponent(Ledger.cacheName))
        try Data(repeating: 7, count: 32).write(to: legacy.appendingPathComponent(Ledger.keyName))
        try Data("legacy prices".utf8).write(to: legacy.appendingPathComponent("pricing-source.json"))
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("pricing.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: legacy.path)
        let logs = box.home.appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("legacy hover log\n".utf8).write(to: logs.appendingPathComponent("Headroom-hover.log"))
        let before = try Self.fingerprint(legacy).merging(try Self.fingerprint(logs)) { a, _ in a }

        try box.write(".claude/projects/-p/s1.jsonl", [Self.line("A"), Self.line("B")].joined(separator: "\n") + "\n")
        let support = AppIdentity.applicationSupport(in: base)
        #expect(support.lastPathComponent == "SpanDeck" && support.path != legacy.path)
        try PrivateDirectory(url: support).prepare()
        let pricing = Pricing(directory: support, transport: FakeTransport())
        pricing.load()
        let ledger = Ledger(home: box.home, appSupport: support, pricing: pricing)
        #expect(await refreshLedger(ledger).claude.month.tokens == 300) // the transcripts, not Headroom's cache
        ledger.flush()
        let relaunched = Ledger(home: box.home, appSupport: support, pricing: pricing)
        #expect(await refreshLedger(relaunched).claude.month.tokens == 300)
        // Clear removes SpanDeck's cache and key only.
        let cleared = await withCheckedContinuation { c in relaunched.clearCache { c.resume(returning: $0) } }
        #expect(cleared == nil)
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent(Ledger.cacheName).path))
        #expect(await refreshLedger(relaunched).claude.month.tokens == 300)
        relaunched.flush()
        // A SpanDeck folder that can't be saved to: still nothing written to Headroom's.
        var blocked = PrivateDirectory(url: support)
        blocked.setMode = { _, _ in -1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: support.path)
        let failing = Ledger(home: box.home, appSupport: support, pricing: pricing, storage: blocked)
        #expect(await refreshLedger(failing).claude.month.tokens == 300)
        failing.flush()
        #expect(failing.cacheIssue == .notSaved(.permissions))

        let after = try Self.fingerprint(legacy).merging(try Self.fingerprint(logs)) { a, _ in a }
        #expect(after == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path) == ["Headroom-hover.log"])
    }
}
