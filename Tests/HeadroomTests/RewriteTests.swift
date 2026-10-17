import Foundation
import Testing
@testable import Headroom

/// #56: a transcript rewritten in place (same inode, same or larger size) is read again from the start, while an
/// unchanged one isn't read at all and an append reads only its new bytes. F16 and F48 cover the totals in every
/// indexing mode; these tests check what is read, through `claudeReadStats`.
struct RewriteTests {
    private struct Rig {
        let box: Sandbox
        let pricing: Pricing
        init() throws {
            box = try Sandbox()
            pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
        }
        func ledger() -> Ledger { Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing) }
        var file: URL { box.home.appendingPathComponent(".claude/projects/-p/s1.jsonl") }
        var cacheURL: URL { box.appSupport.appendingPathComponent(Ledger.cacheName) }
        /// Writes in place (same inode), like an editor saving or a sync tool, not a rename.
        func write(_ lines: [String]) throws {
            if !FileManager.default.fileExists(atPath: file.path) {
                try box.write(".claude/projects/-p/s1.jsonl", "")
            }
            let h = try FileHandle(forWritingTo: file)
            try h.truncate(atOffset: 0)
            try h.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            try h.close()
        }
        func append(_ lines: [String]) throws -> Int {
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            try h.write(contentsOf: data)
            try h.close()
            return data.count
        }
        var inode: UInt64 { (try? FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0 }
    }

    /// 150 tokens; ids of a fixed length so rewrites can keep the byte size.
    private static func line(_ n: String, pad: Int = 0) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req_\#(n)","message":{"id":"msg_\#(n)","model":"claude-test-1","content":"\#(String(repeating: "x", count: pad))","usage":{"input_tokens":100,"output_tokens":50}}}"#
    }

    private static func stats(_ l: Ledger) async -> (bytes: Int, restarts: Int) {
        await withCheckedContinuation { c in l.claudeReadStats { c.resume(returning: $0) } }
    }

    private static func tokens(_ l: Ledger) async -> Int { await refreshLedger(l).claude.month.tokens }

    /// 100 lines, about 25 KiB: larger than both anchor windows.
    private static let large = (0..<100).map { line(String(format: "L%03d", $0), pad: 80) }

    @Test func unchangedFileIsNotReadAgain() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let first = rig.ledger()
        #expect(await Self.tokens(first) == 15000)
        first.flush()

        let second = rig.ledger() // a relaunch: its first refresh is a full scan
        #expect(await Self.tokens(second) == 15000)
        #expect(await Self.stats(second) == (0, 0))

        // Metadata only (the change time moves, the content doesn't): checked, not read.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: rig.file.path)
        #expect(await Self.tokens(second) == 15000)
        #expect(await Self.stats(second) == (0, 0))
    }

    @Test func appendReadsOnlyNewBytes() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 15000)
        let before = await Self.stats(ledger)
        let added = try rig.append([Self.line("N001"), Self.line("N002")])
        #expect(await Self.tokens(ledger) == 15300)
        let after = await Self.stats(ledger)
        #expect(after.bytes - before.bytes == added && after.restarts == 0)
    }

    /// The same inode and byte size, different content: read again from the start. The old record stays counted
    /// (P12) and the new one is counted once.
    @Test func sameSizeRewriteIsRead() async throws {
        let rig = try Rig()
        try rig.write([Self.line("AAAA")])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        let inode = rig.inode, size = try Data(contentsOf: rig.file).count
        try rig.write([Self.line("BBBB")])
        let newSize = try Data(contentsOf: rig.file).count
        #expect(rig.inode == inode && newSize == size)
        #expect(await Self.tokens(ledger) == 300)
        #expect(await Self.stats(ledger).restarts == 1)
        // Read again from the start once only.
        #expect(await Self.tokens(ledger) == 300)
        #expect(await Self.stats(ledger).restarts == 1)
        ledger.flush()
        #expect(await Self.tokens(rig.ledger()) == 300)
    }

    /// Larger, with a different start: read from the start, so nothing before the old offset is skipped.
    @Test func largerRewriteIsReadFromTheStart() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 15000)
        try rig.write([Self.line("NEW1", pad: 500)] + Self.large.dropFirst() + [Self.line("NEW2")])
        #expect(await Self.tokens(ledger) == 15300)
        #expect(await Self.stats(ledger).restarts == 1)
    }

    /// Rewritten with the same content plus more: the bytes before the old offset match, so reading resumes there.
    @Test func rewriteWithSamePrefixResumes() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 15000)
        let before = await Self.stats(ledger)
        try rig.write(Self.large + [Self.line("MORE")])
        #expect(await Self.tokens(ledger) == 15150)
        let after = await Self.stats(ledger)
        #expect(after.restarts == 0 && after.bytes - before.bytes == Self.line("MORE").utf8.count + 1)
    }

    /// A known limit (option (a) on #56): a same-size edit confined to the middle of a file larger than both anchor
    /// windows, with its first 4 KiB and the 4 KiB before the offset intact, isn't detected. Recorded so that changing
    /// this is a deliberate decision.
    @Test func sameSizeEditInTheMiddleIsALimit() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 15000)
        var edited = Self.large
        edited[50] = Self.line("M050", pad: 80)
        try rig.write(edited)
        #expect(await Self.tokens(ledger) == 15000)
        #expect(await Self.stats(ledger).restarts == 0)
    }

    /// A cache saved before #56 has offsets but no anchors: the first check adopts them without reading any line, and
    /// rewrites are detected from then on. No migration: the cache stays version 7.
    @Test func cacheWithoutAnchorsIsAdopted() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let first = rig.ledger()
        #expect(await Self.tokens(first) == 15000)
        first.flush()
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rig.cacheURL)) as? [String: Any])
        #expect(json["version"] as? Int == 7)
        var files = try #require(json["files"] as? [String: [String: Any]])
        let hex32 = try Regex("^[0-9a-f]{32}$")
        for (id, mark) in files {
            #expect((mark["anchor"] as? String)?.wholeMatch(of: hex32) != nil && (mark["stamp"] as? String)?.wholeMatch(of: hex32) != nil)
            files[id] = ["offset": mark["offset"]!] // as written before #56
        }
        json["files"] = files
        try JSONSerialization.data(withJSONObject: json).write(to: rig.cacheURL)

        let second = rig.ledger()
        #expect(await Self.tokens(second) == 15000)
        #expect(await Self.stats(second) == (0, 0))
        second.flush()
        let adopted = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rig.cacheURL)) as? [String: Any])
        for mark in (adopted["files"] as? [String: [String: Any]] ?? [:]).values {
            #expect(mark["anchor"] is String && mark["stamp"] is String)
        }
        // From now on a same-size rewrite is detected.
        var rewritten = Self.large
        rewritten[0] = Self.line("Z000", pad: 80)
        try rig.write(rewritten)
        #expect(await Self.tokens(second) == 15150)
        #expect(await Self.stats(second).restarts == 1)
    }
}
