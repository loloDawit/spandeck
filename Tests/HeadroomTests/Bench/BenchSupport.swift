import Darwin
import Foundation
@testable import Headroom

/// Measurement helpers for the #8 performance baseline. Process-wide counters only: run one dataset per process
/// (`scripts/bench.sh` does), with no other suite running, or the figures mix. Nothing here launches a process,
/// opens a socket or reads anything outside the sandbox it is given.
enum Bench {
    /// User + system CPU time of this process, in seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// The process's physical footprint now and its peak so far, in bytes (what Activity Monitor calls Memory).
    static func footprint() -> (now: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }

    /// Bytes this process read from and wrote to storage, as the kernel counts them. Reads served from the file
    /// cache aren't counted, so a warm-cache read can show 0 even when a file was read.
    static func diskIO() -> (read: UInt64, written: UInt64) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return (0, 0) }
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    struct Sample {
        var wall: Double
        var cpu: Double
        var read: UInt64
        var written: UInt64
    }

    /// Runs `body` once and measures wall time, CPU time and disk I/O around it.
    static func measure(_ body: () async throws -> Void) async rethrows -> Sample {
        let io0 = diskIO(), cpu0 = cpuSeconds(), t0 = DispatchTime.now().uptimeNanoseconds
        try await body()
        let t1 = DispatchTime.now().uptimeNanoseconds, cpu1 = cpuSeconds(), io1 = diskIO()
        return Sample(wall: Double(t1 - t0) / 1e9, cpu: cpu1 - cpu0, read: io1.read &- io0.read,
                      written: io1.written &- io0.written)
    }

    /// Median, 95th percentile (nearest rank: the ⌈0.95·n⌉-th smallest) and worst of `xs`. With n ≤ 19 the p95 is the
    /// worst sample, so a p95 from a small n says no more than the worst does.
    static func stats(_ xs: [Double]) -> [String: Double] {
        guard !xs.isEmpty else { return [:] }
        let s = xs.sorted()
        let mid = s.count / 2
        let median = s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
        let p95 = s[min(s.count - 1, Int((0.95 * Double(s.count)).rounded(.up)) - 1)]
        return ["median": median, "p95": p95, "max": s[s.count - 1], "min": s[0], "n": Double(s.count)]
    }

    static func summary(_ samples: [Sample]) -> [String: Any] {
        ["wall_s": stats(samples.map(\.wall)), "cpu_s": stats(samples.map(\.cpu)),
         "disk_read_bytes": stats(samples.map { Double($0.read) }),
         "disk_written_bytes": stats(samples.map { Double($0.written) })]
    }
}

/// A clock the ledger reads, moved forward by the benchmark to force full scans, a sleep or a new day.
final class BenchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }
    func advance(_ s: TimeInterval) { lock.withLock { offset += s } }
}

/// Synthetic Claude Code transcripts and Grok usage files. Every value is invented: no real prompt, path, id, model
/// response or account appears. Shape per logged message, like the #58 mix on #8: a ~1 KB user prompt, two streamed
/// assistant snapshots with growing counts, and a ~3 KB tool result that quotes `\"usage\"` escaped. Every 100th
/// message has no `requestId` (one-id identity, P4). Messages are spread evenly over the last 29 days and
/// round-robin over four models, so every quarter hour is active (the worst case for buckets, #57). Each file's
/// modification time is its last message's time, so only the newest file is "hot" (modified in the last 2 hours).
struct BenchDataset {
    /// The dataset named by `SPANDECK_BENCH_DATASET`, or nil (the benchmark is then skipped).
    static var selected: BenchDataset? {
        ProcessInfo.processInfo.environment["SPANDECK_BENCH_DATASET"].flatMap { all[$0] }
    }

    /// `gen`, `cold` or `warm` when `PerformanceMemoryBenchTests` should run (`SPANDECK_BENCH_MODE` and
    /// `SPANDECK_BENCH_HOME` set, with a dataset); nil otherwise.
    static var memoryMode: String? {
        let e = ProcessInfo.processInfo.environment
        guard selected != nil, e["SPANDECK_BENCH_HOME"] != nil, let m = e["SPANDECK_BENCH_MODE"],
              ["gen", "cold", "warm"].contains(m) else { return nil }
        return m
    }

    /// This package's `.build/bench`, from this file's own path (`Tests/HeadroomTests/Bench/`).
    static let benchRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/bench")

    /// Whether `url` is `<package>/.build/bench/data-<lowercase letters>` once `..` and symlinks in its parents are
    /// resolved, and is not itself a symlink. The memory runs write there, and delete it first in `gen` mode.
    static func isBenchDataFolder(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix("data-"), name.count > 5, name.dropFirst(5).allSatisfy({ $0.isLowercase && $0.isLetter }) else {
            return false
        }
        if let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType,
           type == .typeSymbolicLink { return false }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        return parent == benchRoot.resolvingSymlinksInPath().standardizedFileURL.path
    }

    let name: String
    let files: Int
    let messages: Int
    /// One extra file this many messages long (a long-running session), or 0.
    let bigFile: Int
    let grokSessions: Int
    let grokTurns: Int

    static let all: [String: BenchDataset] = [
        "small": BenchDataset(name: "small", files: 10, messages: 2_000, bigFile: 0, grokSessions: 5, grokTurns: 20),
        "medium": BenchDataset(name: "medium", files: 100, messages: 30_000, bigFile: 0, grokSessions: 20, grokTurns: 50),
        "large": BenchDataset(name: "large", files: 300, messages: 100_000, bigFile: 20_000, grokSessions: 50,
                              grokTurns: 100),
    ]

    static let models = ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5-20251001", "claude-sonnet-4"]
    static let projectDir = ".claude/projects/-Users-synthetic-bench"

    private static let prompt = String(repeating: "synthetic prompt text ", count: 48)              // ~1 KB
    private static let toolText = String(repeating: #"line with \"usage\": {\"x\":1} quoted "#, count: 80) // ~3 KB

    private static func formatter() -> ISO8601DateFormatter {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso
    }

    /// One logged message as four transcript lines: the prompt, two streamed snapshots, a tool result. Every message the
    /// benchmark writes, first or appended, has this shape. Every 100th has no `requestId`.
    private static func message(_ m: Int, prefix: String, at ts: String) -> String {
        let id = "\(prefix)\(m)", model = models[m % models.count]
        let req = m % 100 == 0 ? "" : #""requestId":"req_\#(id)","#
        var text = #"{"type":"user","timestamp":"\#(ts)","message":{"role":"user","content":"\#(prompt)"}}"# + "\n"
        for (out, read) in [(20, 0), (120, 400)] {
            text += #"{"type":"assistant","timestamp":"\#(ts)",\#(req)"message":{"id":"msg_\#(id)","model":"\#(model)","#
                + #""content":[{"type":"text","text":"synthetic"}],"usage":{"input_tokens":100,"output_tokens":\#(out),"#
                + #""cache_read_input_tokens":\#(read),"cache_creation_input_tokens":200,"#
                + #""cache_creation":{"ephemeral_5m_input_tokens":200,"ephemeral_1h_input_tokens":0}}}}"# + "\n"
        }
        return text + #"{"type":"user","timestamp":"\#(ts)","message":{"role":"user","content":[{"type":"tool_result","#
            + #""content":"\#(toolText)"}]}}"# + "\n"
    }

    /// Writes the dataset under `home`; returns (bytes, lines, transcript files). Every one of `messages + bigFile`
    /// messages is written: the regular files split `messages` as evenly as possible.
    @discardableResult
    func write(home: URL, now: Date) throws -> (bytes: Int, lines: Int, files: Int) {
        let dir = home.appendingPathComponent(Self.projectDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let span: TimeInterval = 29 * 86_400
        let start = now.addingTimeInterval(-span)
        let total = messages + bigFile
        var bytes = 0, lines = 0, written = 0
        let iso = Self.formatter()

        // The big file, if any, holds the newest `bigFile` messages, so it is the hot one.
        var chunks: [(name: String, range: Range<Int>)] = (0..<files).map { f in
            ("s\(f)", (f * messages / files)..<((f + 1) * messages / files))
        }
        if bigFile > 0 { chunks.append(("big", messages..<total)) }

        for (name, range) in chunks where !range.isEmpty {
            var text = ""
            text.reserveCapacity(range.count * 5_600)
            var last = start
            for m in range {
                last = start.addingTimeInterval(span * Double(m) / Double(total))
                text += Self.message(m, prefix: "b", at: iso.string(from: last))
                lines += 4
            }
            let url = dir.appendingPathComponent("\(name).jsonl")
            let data = Data(text.utf8)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: last], ofItemAtPath: url.path)
            bytes += data.count
            written += 1
        }

        for s in 0..<grokSessions {
            let turns = (0..<grokTurns).map { k -> String in
                let t = start.addingTimeInterval(span * Double(s * grokTurns + k) / Double(grokSessions * grokTurns))
                return #"{"endedAt":"\#(iso.string(from: t))","inputTokens":1000,"cachedReadTokens":200,"outputTokens":300,"#
                    + #""cacheCreationTokens":0,"modelCalls":2,"totalTokens":1300,"costUsdTicks":\#(1_000_000 + k),"#
                    + #""primaryModelId":"grok-bench"}"#
            }
            let url = home.appendingPathComponent(".grok/sessions/bench/g\(s)/usage.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data((#"{"turns":["# + turns.joined(separator: ",") + "]}").utf8)
            try data.write(to: url)
            bytes += data.count
        }
        return (bytes, lines, written)
    }

    /// Appends `count` new messages, dated `now` (the benchmark's clock), to the transcript `newest` places from the
    /// newest (0 = the hot file), as Claude Code would while a session runs. The file's modification time becomes
    /// `now`, so a file appended after a simulated sleep is "hot".
    static func append(home: URL, count: Int, now: Date, seq: inout Int, newest: Int = 0) throws {
        let dir = home.appendingPathComponent(projectDir)
        func order(_ n: String) -> Int { n == "big.jsonl" ? .max : Int(n.dropFirst().dropLast(6)) ?? -1 }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".jsonl") }
            .sorted { order($0) > order($1) }
        let url = dir.appendingPathComponent(names[min(newest, names.count - 1)])
        let ts = formatter().string(from: now)
        var text = ""
        for _ in 0..<count {
            seq += 1
            text += message(seq, prefix: "n", at: ts)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }
}
