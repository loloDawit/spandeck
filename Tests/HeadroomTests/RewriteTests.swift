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

        // Metadata only (the change time moves, the size and content don't): by the #56 policy a same-size change
        // is read again from the start once, which counts nothing twice.
        let size = try Data(contentsOf: rig.file).count
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-30)], ofItemAtPath: rig.file.path)
        #expect(await Self.tokens(second) == 15000)
        #expect(await Self.stats(second) == (size, 1))
        #expect(await Self.tokens(second) == 15000)
        #expect(await Self.stats(second) == (size, 1)) // once
        // And not again after a relaunch: the restart was saved with the new stamp.
        second.flush()
        let third = rig.ledger()
        #expect(await Self.tokens(third) == 15000)
        #expect(await Self.stats(third) == (0, 0))
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

    /// A same-size edit in the middle of a large file, where no anchor window changes, is read again from the start
    /// (#56 policy, after review of `1a7669c`): the change time moved and the size didn't.
    @Test func sameSizeEditInTheMiddleIsRead() async throws {
        let rig = try Rig()
        try rig.write(Self.large)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 15000)
        var edited = Self.large
        edited[50] = Self.line("M050", pad: 80)
        try rig.write(edited)
        #expect(await Self.tokens(ledger) == 15150)
        #expect(await Self.stats(ledger).restarts == 1)
    }

    // MARK: Large files, sampled anchors

    /// About 150 KiB: large enough that 16 sampled 4 KiB windows leave gaps between them.
    private static let huge = (0..<600).map { line(String(format: "%04d", $0), pad: 80) }

    /// Byte ranges of each line (newline excluded) and the offset just past the last newline.
    private static func layout(_ lines: [String]) -> (ranges: [Range<Int>], end: Int) {
        var at = 0, out: [Range<Int>] = []
        for l in lines { let n = l.utf8.count; out.append(at..<(at + n)); at += n + 1 }
        return (out, at)
    }

    /// A line in the middle that no anchor window touches, and one inside a sampled window (neither the first nor
    /// the last), for a file read up to `end`.
    private static func lines(of lines: [String], outsideAndInside end: Int) -> (outside: Int?, inside: Int?) {
        let windows = Ledger.anchorRanges(upTo: end), ranges = layout(lines).ranges
        let middle = windows.dropFirst().dropLast()
        let outside = ranges.indices.dropFirst(2).dropLast(2).first { i in !windows.contains { $0.overlaps(ranges[i]) } }
        let inside = ranges.indices.dropFirst(2).dropLast(2).first { i in
            middle.contains { $0.contains(ranges[i].lowerBound) && $0.contains(ranges[i].upperBound - 1) }
            && !windows.first!.overlaps(ranges[i]) && !windows.last!.overlaps(ranges[i])
        }
        return (outside, inside)
    }

    /// The file ends with an incomplete line, so its saved offset is short of its size. A same-size rewrite outside
    /// every anchor window is still read again: the size compared is the one observed last time, not the offset.
    @Test func sameSizeRewriteWithIncompleteLastLine() async throws {
        let rig = try Rig()
        let partial = #"{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"usage":{"input_tok"#
        try rig.write(Self.huge)
        var text = try Data(contentsOf: rig.file)
        text.append(Data(partial.utf8)) // no newline after it
        try text.write(to: rig.file)
        let ledger = rig.ledger()
        let first = await refreshLedger(ledger).claude
        #expect(first.month.tokens == 90000 && first.month.completeness.pending == 1)

        let end = Self.layout(Self.huge).end
        let i = try #require(Self.lines(of: Self.huge, outsideAndInside: end).outside)
        var edited = Self.huge
        edited[i] = Self.line(String(format: "E%03d", i % 1000), pad: 80)
        let h = try FileHandle(forWritingTo: rig.file)
        try h.write(contentsOf: Data((edited.joined(separator: "\n") + "\n" + partial).utf8)) // in place, same size
        try h.close()
        #expect(await Self.tokens(ledger) == 90150)
        #expect(await Self.stats(ledger).restarts == 1)
    }

    /// Larger, with an edit inside a sampled window in the middle: detected by the anchor.
    @Test func largerRewriteInsideASampleIsRead() async throws {
        let rig = try Rig()
        try rig.write(Self.huge)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 90000)
        let i = try #require(Self.lines(of: Self.huge, outsideAndInside: Self.layout(Self.huge).end).inside)
        var edited = Self.huge
        edited[i] = Self.line(String(format: "I%03d", i % 1000), pad: 80)
        try rig.write(edited + [Self.line("TAIL")])
        #expect(await Self.tokens(ledger) == 90300)
        #expect(await Self.stats(ledger).restarts == 1)
    }

    /// The accepted exception (#56 policy): a larger rewrite that changes only bytes outside every anchor window
    /// (head, tail and the 16 samples) isn't detected; only the appended part is read. Deterministic, recorded so that
    /// changing it is a decision.
    @Test func largerRewriteOutsideTheSamplesIsALimit() async throws {
        let rig = try Rig()
        try rig.write(Self.huge)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 90000)
        let i = try #require(Self.lines(of: Self.huge, outsideAndInside: Self.layout(Self.huge).end).outside)
        var edited = Self.huge
        edited[i] = Self.line(String(format: "O%03d", i % 1000), pad: 80)
        try rig.write(edited + [Self.line("TAIL")])
        #expect(await Self.tokens(ledger) == 90150)
        #expect(await Self.stats(ledger).restarts == 0)
    }

    /// Sixteen evenly spaced 4 KiB samples between the first and the last window, inside the bytes read.
    @Test func anchorWindows() {
        #expect(Ledger.anchorRanges(upTo: 0).isEmpty)
        let small = Ledger.anchorRanges(upTo: 100)
        #expect(small.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= 100 })
        let big = Ledger.anchorRanges(upTo: 1_000_000)
        #expect(big.count == 18 && big.allSatisfy { $0.count == Ledger.anchorWindow && $0.upperBound <= 1_000_000 })
        #expect(big.first == 0..<4096 && big.last == (1_000_000 - 4096)..<1_000_000)
        let starts = big.map(\.lowerBound)
        #expect(starts == starts.sorted())
        let gaps = zip(starts.dropFirst(), starts).map { $0 - $1 }
        #expect(gaps.max()! - gaps.min()! <= 1) // evenly spaced
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
