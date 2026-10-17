import Foundation
import Testing
@testable import Headroom

/// #66 (audit 0007 P1): model ids come from untrusted files. An id is kept only when it has the shape of a provider
/// model id; anything else is counted as `unknown`, with its tokens, and the raw text is never cached or shown.
/// Every value here is synthetic; credential-shaped strings contain `CANARY` and are obviously fake.
struct ModelIdentifierTests {
    // MARK: Policy

    /// Ids SpanDeck reads today: first-party, dated, Bedrock, Vertex, the fixtures' and the runtime fixture's.
    static let valid = [
        "claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001", "claude-opus-4-1-20250805",
        "claude-3-5-sonnet-20241022", "claude-opus-5-5", "claude-fable-5-1", "claude-mythos-preview",
        "claude-sonnet-4-5-20250929-v1:0", "anthropic.claude-opus-5-5", "us.anthropic.claude-sonnet-4-20250514-v1:0",
        "global.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-opus-4-5@20251101", "claude-3-5-sonnet-v2@20241022",
        "claude-test-1", "claude-synth-1", "claude-new", "claude-x", "gpt-x", "claude-rvmodel3fa9b2c1d4e5",
        "claude-CANARYMODEL-1", "grok-4", "grok-code-fast-1", "grok-4.6-build", "grok-test", "grok-CANARYGROKMODEL",
        "unknown", "a",
    ]

    @Test(arguments: valid) func providerIdsAreKept(_ id: String) {
        #expect(Ledger.modelID(id) == id)
    }

    static let invalid = [
        "", " ", "claude sonnet", " claude-x", "claude-x ", "claude-x\n", "claude-x\t1", "claude-\u{0}x", "claude-\u{1B}[31m",
        "claude-é", "claude-模型", "claude-\u{200B}x", "claude-x\u{FE0F}", "🙂",
        // Paths and path-like text.
        "/Users/CANARYUSER/src/CANARYREPO", "~/secret", "../claude", "claude/../../etc", "C:\\Users\\x", "file:///tmp/x",
        "arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/CANARY",
        "openrouter/anthropic/claude-x",
        // Credential-shaped (fake).
        "sk-ant-api03-CANARY-0000", "sk-CANARY", "SK-ant-CANARY", "xai-CANARY-GROK-KEY-0000", "AKIACANARY0000000000",
        "ASIACANARY0000000000", "ghp_CANARYGITHUB0000", "github_pat_CANARY",
        "claude-" + String(repeating: "a1b2", count: 9), "eyJhbGciOiJIUzI1NiJ9CANARYxxxxxxxxxxxxxxxx",
        // Not starting with a letter, or markup.
        "-claude", ".claude", "1claude", ":claude", "@claude", "<synthetic>", "claude[1m]", "claude\"x", "claude'x",
        "claude=x", "claude;x", "claude,x", "claude%20x", "claude+x", "claude#x",
    ]

    @Test(arguments: invalid) func otherTextIsUnknown(_ id: String) {
        #expect(Ledger.modelID(id) == "unknown")
    }

    @Test func missingIsUnknown() { #expect(Ledger.modelID(nil) == "unknown") }

    @Test func lengthBoundIsOneHundred() {
        // Hyphen-separated so no part is over the part limit.
        let base = Array(repeating: "claude", count: 15).joined(separator: "-") // 104
        let at100 = String(base.prefix(100)), at101 = String(base.prefix(101))
        #expect(at100.count == 100 && at101.count == 101)
        #expect(Ledger.modelID(at100) == at100)
        #expect(Ledger.modelID(at101) == "unknown")
        #expect(Ledger.modelID("claude-" + String(repeating: "x", count: 2000)) == "unknown")
    }

    @Test func partBoundIsThirtyTwo() {
        #expect(Ledger.modelID("claude-" + String(repeating: "x", count: 32)) == "claude-" + String(repeating: "x", count: 32))
        #expect(Ledger.modelID("claude-" + String(repeating: "x", count: 33)) == "unknown")
        #expect(Ledger.modelID(String(repeating: "x", count: 33)) == "unknown")
        #expect(Ledger.modelID("us." + String(repeating: "x", count: 33) + ".claude") == "unknown")
    }

    // MARK: Claude ingestion

    static let projectDir = ".claude/projects/-Users-synthetic-p1"
    static let badModel = "claude bad id CANARY-MODEL-RAW /Users/CANARYUSER sk-ant-CANARY"

    private static func line(model: String?, id: String, input: Int = 100, output: Int = 50,
                             iterations: String = "", date: Date = Date().addingTimeInterval(-600)) -> String {
        let ts = ISO8601DateFormatter().string(from: date)
        let m = model.map { #""model":\#(json($0)),"# } ?? ""
        let it = iterations.isEmpty ? "" : #","iterations":\#(iterations)"#
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req_\#(id)","message":{"id":"msg_\#(id)",\#(m)"usage":{"input_tokens":\#(input),"output_tokens":\#(output)\#(it)}}}"#
    }

    private static func json(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)
    }

    private struct Rig {
        let box: Sandbox
        let pricing: Pricing
        init() throws {
            box = try Sandbox()
            pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
        }
        func ledger() -> Ledger { Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing) }
        var cacheURL: URL { box.appSupport.appendingPathComponent(Ledger.cacheName) }
        var cache: String { (try? String(contentsOf: cacheURL, encoding: .utf8)) ?? "" }
        @discardableResult
        func transcript(_ lines: [String], name: String = "s1") throws -> URL {
            try box.write("\(ModelIdentifierTests.projectDir)/\(name).jsonl", lines.joined(separator: "\n") + "\n")
        }
    }

    private static func tokens(_ s: UsageSummary) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: s.models.map { ($0.model, $0.tokens) })
    }

    /// Every string shown about these summaries that could carry a model id.
    private static func shown(_ s: (claude: UsageSummary, grok: UsageSummary)) -> [String] {
        (s.claude.models + s.grok.models).map(\.model) + (s.claude.bars + s.grok.bars).map(\.family)
            + s.claude.uncostedModels + s.grok.uncostedModels + s.claude.uncertainCacheModels
            + [PricingText.coverageNote(claude: s.claude, grok: s.grok) ?? ""]
            + UsageNotes.notes(s.claude).flatMap { [$0.text, $0.detail] }
    }

    private static func expectNoRaw(_ s: (claude: UsageSummary, grok: UsageSummary), _ rig: Rig, _ raws: [String],
                                    _ label: String) {
        for raw in raws {
            for piece in [raw, "CANARY"] {
                for text in shown(s) { #expect(!text.contains(piece), "\(label): shown \(text)") }
                #expect(!rig.cache.contains(piece), "\(label): \(piece) in the cache")
            }
        }
    }

    @Test func invalidMainModelCountsAsUnknown() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(model: Self.badModel, id: "a"), Self.line(model: "claude-test-1", id: "b", input: 7, output: 3)])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 150, "claude-test-1": 10])
        #expect(s.claude.month.tokens == 160)
        #expect(rig.cache.contains("claude-test-1"))
        Self.expectNoRaw(s, rig, [Self.badModel], "main")
    }

    @Test func overLongModelCountsAsUnknown() async throws {
        let rig = try Rig()
        let long = "claude-" + String(repeating: "x", count: 2000) + "-CANARY-IN-MODEL"
        try rig.transcript([Self.line(model: long, id: "a")])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 150])
        #expect(!rig.cache.contains("xxxxxxxx"))
        Self.expectNoRaw(s, rig, [long], "long")
    }

    @Test func invalidIterationModelCountsAsUnknown() async throws {
        let rig = try Rig()
        let it = #"[{"type":"advisor","model":\#(Self.json(Self.badModel)),"input_tokens":30,"output_tokens":3},"#
            + #"{"type":"advisor","model":"claude-haiku-4-5-20251001","input_tokens":5,"output_tokens":5}]"#
        try rig.transcript([Self.line(model: "claude-test-1", id: "a", iterations: it)])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["claude-test-1": 150, "unknown": 33, "claude-haiku-4-5-20251001": 10])
        #expect(s.claude.month.tokens == 193)
        Self.expectNoRaw(s, rig, [Self.badModel], "iteration")
    }

    /// Iterations are compared with the main model as written, before validation: a sub-call of another invalid model
    /// is still an extra operation (both now `unknown`), and one of the same model is still in the top-level usage.
    @Test func iterationsCompareRawIds() async throws {
        let rig = try Rig()
        let other = "claude other CANARY-MODEL-SUB"
        let it = #"[{"type":"advisor","model":\#(Self.json(other)),"input_tokens":30,"output_tokens":3},"#
            + #"{"type":"advisor","model":\#(Self.json(Self.badModel)),"input_tokens":1000,"output_tokens":1000}]"#
        try rig.transcript([Self.line(model: Self.badModel, id: "a", iterations: it)])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 183])
        Self.expectNoRaw(s, rig, [Self.badModel, other], "raw compare")
    }

    /// A transcript's `<synthetic>` records (Claude Code's own, not model calls) are still skipped, before validation.
    @Test func syntheticRecordsAreStillSkipped() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(model: "<synthetic>", id: "a"), Self.line(model: "claude-test-1", id: "b")])
        let s = await refreshLedger(rig.ledger())
        #expect(Self.tokens(s.claude) == ["claude-test-1": 150])
    }

    @Test func missingModelIsStillUnknown() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(model: nil, id: "a")])
        let s = await refreshLedger(rig.ledger())
        #expect(Self.tokens(s.claude) == ["unknown": 150])
    }

    /// Fingerprints (records without ids) still dedupe on the id as written, so a record re-read after this change
    /// matches what an earlier version counted.
    @Test func fingerprintedRecordsDedupeWithInvalidModels() async throws {
        let rig = try Rig()
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let rec = #"{"type":"assistant","timestamp":"\#(ts)","message":{"model":\#(Self.json(Self.badModel)),"usage":{"input_tokens":100,"output_tokens":50}}}"#
        try rig.transcript([rec, rec])
        let s = await refreshLedger(rig.ledger())
        #expect(Self.tokens(s.claude) == ["unknown": 150])
    }

    // MARK: Grok

    @Test func invalidGrokModelCountsAsUnknown() async throws {
        let rig = try Rig()
        let now = Date().addingTimeInterval(-600)
        try rig.box.writeGrokUsage(session: "s1", turns: [(now, 10, "grok bad CANARY-GROK-RAW /Users/CANARYUSER"),
                                                          (now.addingTimeInterval(1), 10, "grok-4"),
                                                          (now.addingTimeInterval(2), 10, "xai-CANARY-KEY-0000")])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.grok) == ["unknown": 300, "grok-4": 150])
        #expect(s.grok.month.tokens == 450)
        Self.expectNoRaw(s, rig, ["grok bad CANARY-GROK-RAW", "xai-CANARY"], "grok")
    }

    /// Copies of a turn (resumed or forked sessions) still count once when their model id is invalid.
    @Test func grokCopiesWithInvalidModelsCountOnce() async throws {
        let rig = try Rig()
        let now = Date().addingTimeInterval(-600)
        try rig.box.writeGrokUsage(session: "s1", turns: [(now, 10, "grok bad CANARY-A")])
        try rig.box.writeGrokUsage(session: "s2", turns: [(now, 10, "grok bad CANARY-B")])
        let s = await refreshLedger(rig.ledger())
        #expect(Self.tokens(s.grok) == ["unknown": 150])
    }

    @Test func missingGrokModelIsStillGrok() async throws {
        let rig = try Rig()
        let ended = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        try rig.box.write(".grok/sessions/proj/s1/usage.json",
                          #"{"turns":[{"endedAt":"\#(ended)","inputTokens":100,"outputTokens":50,"modelCalls":1,"totalTokens":150,"costUsdTicks":10}]}"#)
        let s = await refreshLedger(rig.ledger())
        #expect(Self.tokens(s.grok) == ["grok": 150])
    }

    // MARK: Existing v7 caches

    /// Renames model keys in a saved cache, as a version written before validation would have stored them: moves the
    /// `unknown` usage of each seen operation that `match`es, in its parts and in its slot's bucket, to the raw id.
    /// Returns how many keys changed.
    private static func plant(_ url: URL, raw: String, where match: ([String: Any]) -> Bool) throws -> Int {
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var seen = root["seen"] as! [String: Any]
        var slots = root["slots"] as! [String: Any] // [Int: [String: Agg]]: slot numbers as string keys
        var changed = 0
        for (k, v) in seen {
            var op = v as! [String: Any]
            var parts = op["parts"] as! [String: Any]
            guard let part = parts["unknown"], match(part as! [String: Any]) else { continue }
            parts["unknown"] = nil
            parts[raw] = part
            op["parts"] = parts
            seen[k] = op
            changed += 1
            // Move this operation's share of its slot's bucket to the raw id, as the old code would have kept it.
            let slot = String(op["slot"] as! Int)
            if var buckets = slots[slot] as? [String: Any], let total = buckets["unknown"] as? [String: Any] {
                let mine = part as! [String: Any]
                var rest = total
                for (f, n) in mine { if let a = n as? Int, let b = total[f] as? Int { rest[f] = b - a } }
                if (rest["input"] as? Int ?? 0) + (rest["output"] as? Int ?? 0) == 0 && (rest["calls"] as? Int ?? 0) == 0 {
                    buckets["unknown"] = nil
                } else {
                    buckets["unknown"] = rest
                }
                buckets[raw] = mine
                slots[slot] = buckets
                changed += 1
            }
        }
        root["seen"] = seen
        root["slots"] = slots
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        return changed
    }

    /// A v7 cache saved before validation holds the raw id in `slots` and `seen.parts`. Loading it moves that usage to
    /// `unknown` (merged with what was already there), keeps every total, and saves the cache without the raw id. The
    /// transcripts read again afterwards (a rewrite, an append) aren't counted twice.
    @Test func existingCacheIsNormalisedAtLoad() async throws {
        let rig = try Rig()
        let url = try rig.transcript([Self.line(model: Self.badModel, id: "a", input: 100, output: 50),
                                      Self.line(model: nil, id: "b", input: 7, output: 3),
                                      Self.line(model: "claude-test-1", id: "c", input: 20, output: 2)])
        do {
            let ledger = rig.ledger()
            let s = await refreshLedger(ledger)
            ledger.flush()
            #expect(Self.tokens(s.claude) == ["unknown": 160, "claude-test-1": 22])
        }
        // The bad record's 100 input tokens identify it; the missing-model record stays `unknown`, as it always was.
        let changed = try Self.plant(rig.cacheURL, raw: Self.badModel) { $0["input"] as? Int == 100 }
        #expect(changed == 2)
        #expect(rig.cache.contains("CANARY-MODEL-RAW"))

        let ledger = rig.ledger()
        var s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 160, "claude-test-1": 22])
        #expect(s.claude.month.tokens == 182)
        #expect(s.claude.month.identity.identified == 3)
        Self.expectNoRaw(s, rig, [Self.badModel], "loaded")
        #expect(rig.cache.contains("claude-test-1"))

        // An in-place rewrite of the same bytes is read again from the start: nothing counts twice.
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        s = await refreshLedger(ledger)
        #expect(Self.tokens(s.claude) == ["unknown": 160, "claude-test-1": 22])

        // A relaunch on the normalised cache, then an append with the same bad id: only the new record is added.
        let again = rig.ledger()
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data((Self.line(model: Self.badModel, id: "d", input: 1, output: 1) + "\n").utf8))
        try handle.close()
        s = await refreshLedger(again)
        again.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 162, "claude-test-1": 22])
        Self.expectNoRaw(s, rig, [Self.badModel], "appended")
    }

    /// A cache whose ids all pass is loaded as it is: no rewrite at launch, so nothing changes on disk.
    @Test func validCacheIsNotRewritten() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(model: "claude-test-1", id: "a"), Self.line(model: nil, id: "b"),
                            Self.line(model: "us.anthropic.claude-sonnet-4-5-20250929-v1:0", id: "c")])
        do {
            let ledger = rig.ledger()
            _ = await refreshLedger(ledger)
            ledger.flush()
        }
        let before = try Data(contentsOf: rig.cacheURL)
        let modified = try FileManager.default.attributesOfItem(atPath: rig.cacheURL.path)[.modificationDate] as? Date
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["claude-test-1": 150, "unknown": 150, "us.anthropic.claude-sonnet-4-5-20250929-v1:0": 150])
        #expect(try Data(contentsOf: rig.cacheURL) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: rig.cacheURL.path)[.modificationDate] as? Date == modified)
    }

    /// An over-long raw id in an old cache is normalised too.
    @Test func existingCacheWithLongIdIsNormalised() async throws {
        let rig = try Rig()
        let long = "claude-" + String(repeating: "y", count: 2000) + "-CANARY-LONG"
        try rig.transcript([Self.line(model: long, id: "a")])
        do {
            let ledger = rig.ledger()
            _ = await refreshLedger(ledger)
            ledger.flush()
        }
        #expect(try Self.plant(rig.cacheURL, raw: long) { _ in true } == 2)
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger)
        ledger.flush()
        #expect(Self.tokens(s.claude) == ["unknown": 150])
        #expect(!rig.cache.contains("yyyyyyyy"))
        Self.expectNoRaw(s, rig, [long], "long cache")
    }
}
