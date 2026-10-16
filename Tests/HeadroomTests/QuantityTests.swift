import Foundation
import Testing
@testable import Headroom

/// #58: token quantities that aren't exact are said so, separately from identity (#55), completeness and cost
/// coverage (R7). Sums held at `Int.max` never trap, and a held sum is rebuilt, never subtracted from, when a #55 merge
/// takes an operation back.
struct QuantityTests {
    static let big = (1 << 53) - 1 // the largest valid counter

    private static func line(id: String?, req: String?, model: String = "claude-test-1", date: Date = Date(),
                             input: Int = big) -> String {
        let ts = ISO8601DateFormatter().string(from: date)
        let r = req.map { #""requestId":"\#($0)","# } ?? "", m = id.map { #""id":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)",\#(r)"message":{\#(m)"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
    }

    private static func ledger(_ box: Sandbox) -> Ledger {
        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        pricing.load()
        return Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing)
    }

    @Test func costSumsSaturate() {
        let a = CostEstimate(known: 1, knownTokens: .max, unknownTokens: .max)
        let b = a + CostEstimate(known: 1, knownTokens: 1, unknownTokens: 1)
        #expect(b.knownTokens == .max && b.unknownTokens == .max && b.known == 2)
        var t = Totals()
        t.addTokens(.max)
        #expect(t.tokens == .max && t.quantity.saturated) // == .max alone is held, conservatively
        var u = Totals()
        u.addTokens(5)
        #expect(u.tokens == 5 && u.quantity.isExact)
        u.addTokens(.max)
        #expect(u.tokens == .max && u.quantity.saturated)
    }

    /// Two models over two hours, each bucket held at `Int.max`: the 30-day sums of tokens and of priced and unpriced
    /// cost tokens all exceed `Int` too. Nothing traps, every period that holds one says it isn't exact, and a
    /// relaunch from the saved cache says the same.
    @Test func manyHeldBucketsDontTrap() async throws {
        let box = try Sandbox()
        let now = Date()
        var lines: [String] = []
        for (h, model) in [(0, "claude-test-1"), (1, "claude-test-1"), (0, "claude-haiku-4-5-20251001"),
                           (1, "claude-haiku-4-5-20251001")] {
            for i in 0..<1100 {
                lines.append(Self.line(id: "msg_\(h)_\(model)_\(i)", req: "req_\(h)_\(model)_\(i)", model: model,
                                       date: now.addingTimeInterval(-Double(h) * 3600)))
            }
        }
        try box.write(".claude/projects/-p/s1.jsonl", lines.joined(separator: "\n") + "\n")
        let ledger = Self.ledger(box)
        let s = await refreshLedger(ledger).claude
        #expect(s.month.tokens == .max && s.month.quantity.saturated)
        #expect(s.month.cost.knownTokens == .max && s.month.cost.unknownTokens == .max)
        #expect(s.models.allSatisfy { $0.tokens == .max })
        #expect(QuantityText.note(s)?.text == QuantityText.provisional)
        ledger.flush()
        let relaunched = await refreshLedger(Self.ledger(box)).claude
        #expect(relaunched.month.tokens == .max && relaunched.month.quantity.saturated)
    }

    /// A held bucket, then a #55 join that takes a partial operation back: the bucket is rebuilt from the operations
    /// still counted, so the result is exact again, not `Int.max` minus the partial shown as if it were exact.
    @Test func heldSumThenIdentityMerge() async throws {
        let box = try Sandbox()
        // 1023 pairs + one message-only + one request-only record: 1025 big counters, more than Int holds.
        var lines = (0..<1023).map { Self.line(id: "msg_\($0)", req: "req_\($0)") }
        lines += [Self.line(id: "msg_P", req: nil), Self.line(id: nil, req: "req_P")]
        let file = try box.write(".claude/projects/-p/s1.jsonl", lines.joined(separator: "\n") + "\n")
        let ledger = Self.ledger(box)
        let before = await refreshLedger(ledger).claude
        #expect(before.month.tokens == .max && before.month.quantity.saturated)
        #expect(before.month.identity == IdentityCoverage(identified: 1023, incomplete: 2))

        // The pair joins both partials: they were one operation, so one big counter goes away.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data((Self.line(id: "msg_P", req: "req_P") + "\n").utf8))
        try h.close()
        let after = await refreshLedger(ledger).claude
        #expect(after.month.tokens == 1024 * Self.big && after.month.quantity.isExact)
        #expect(after.month.identity == IdentityCoverage(identified: 1023, incomplete: 1))
        #expect(QuantityText.note(after) == nil)
        ledger.flush()
        #expect(await refreshLedger(Self.ledger(box)).claude.month.tokens == 1024 * Self.big)
    }

    // MARK: P9 costs and conflicts

    /// Known costs, P9 minimums and unknown costs stay apart: a minimum makes the cost partial, never complete, and
    /// is never called known; disputed tokens are unpriced and claim no bound.
    @Test func minimumsAndDisputesStayApart() {
        let known = CostEstimate(known: 4.25, knownTokens: 10)
        #expect(known.coverage == .complete && known.value == 4.25 && known.lowerBound == 4.25)

        let minimum = CostEstimate(known: 1, knownTokens: 10, minimum: 0.5, minimumTokens: 300)
        #expect(minimum.coverage == .partial && minimum.value == nil && minimum.lowerBound == 1.5)
        #expect(Fmt.cost(minimum) == "≥$1.50")
        #expect(Fmt.costDetail(minimum) == "Partial estimate: $1.00 known; at least $0.50 for 300 cache-write tokens of unknown tier")

        let disputed = CostEstimate(known: 1, knownTokens: 10, disputedTokens: 200)
        #expect(disputed.coverage == .partial && disputed.lowerBound == 1)
        #expect(Fmt.costDetail(disputed) == "Partial estimate: $1.00 known; cost unknown for 200 provisional cache-write tokens")

        let onlyMinimum = CostEstimate(minimum: 0.5, minimumTokens: 300)
        #expect(onlyMinimum.coverage == .partial) // something is known: at least the minimum
        #expect(CostEstimate(disputedTokens: 5).coverage == .unavailable)

        let sum = minimum + disputed + CostEstimate(unknownTokens: 7)
        #expect(sum.known == 2 && sum.minimum == 0.5 && sum.minimumTokens == 300 && sum.disputedTokens == 200
                && sum.unknownTokens == 7 && sum.knownTokens == 20)
        #expect(Fmt.costDetail(sum) == "Partial estimate: $2.00 known; at least $0.50 for 300 cache-write tokens of unknown tier; cost unknown for 7 tokens; cost unknown for 200 provisional cache-write tokens")
    }

    /// The cost note names a missing price and an uncertain cache-write tier as different causes.
    @Test func coverageNoteNamesTierCause() throws {
        var s = UsageSummary()
        s.models = [ModelRow(model: "claude-haiku", tokens: 10, cost: CostEstimate(known: 1, knownTokens: 5, minimum: 0.1, minimumTokens: 5)),
                    ModelRow(model: "claude-new", tokens: 3, cost: CostEstimate(unknownTokens: 3))]
        s.month = Totals(tokens: 13, cost: s.models.map(\.cost).reduce(.zero, +))
        #expect(s.uncostedModels == ["claude-new"] && s.uncertainCacheModels == ["claude-haiku"])
        let note = try #require(PricingText.coverageNote(claude: s, grok: nil))
        #expect(note.contains("no price for claude-new") && note.contains("cache writes of uncertain tier or amount for claude-haiku"))
        s.models.removeLast()
        #expect(try #require(PricingText.coverageNote(claude: s, grok: nil)).contains("no price") == false)
    }

    @Test func conflictNote() throws {
        var s = UsageSummary()
        s.month = Totals(tokens: 500, cost: CostEstimate(known: 1, knownTokens: 200, disputedTokens: 300),
                         identity: IdentityCoverage(identified: 1), quantity: QuantityUncertainty(disputedTokens: 300))
        let note = try #require(QuantityText.note(s))
        #expect(note.text == QuantityText.provisional)
        #expect(note.detail.contains("300 cache-write tokens are counted provisionally")
                && note.detail.contains("may be lower or higher") && !note.detail.contains("larger than SpanDeck"))
        #expect(CompletenessText.note(s) == nil && IdentityText.note(s) == nil) // its own dimension
    }

    @Test func quantityNote() throws {
        var s = UsageSummary()
        s.month = Totals(tokens: 10, cost: CostEstimate(known: 1, knownTokens: 10), identity: IdentityCoverage(identified: 1))
        #expect(QuantityText.note(nil) == nil && QuantityText.note(s) == nil)
        s.month.quantity.saturated = true
        let note = try #require(QuantityText.note(s))
        #expect(note.text == "Some token counts are provisional. Totals may be over- or understated.")
        #expect(note.detail.contains("larger than SpanDeck can count") && note.detail.contains("not your bill"))
        // Independent of the other notes, and listed between completeness and identity.
        #expect(CompletenessText.note(s) == nil && IdentityText.note(s) == nil)
        #expect(PricingText.coverageNote(claude: s, grok: nil) == nil)
        s.month.completeness = DataCompleteness(malformed: 1)
        s.month.identity = IdentityCoverage(fingerprinted: 1)
        #expect(UsageNotes.notes(s).map(\.text) == [CompletenessText.incomplete, QuantityText.provisional,
                                                     IdentityText.approximate])
    }
}
