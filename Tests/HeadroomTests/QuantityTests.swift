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
        #expect(known.coverage == .complete && known.value == 4.25 && known.amount == 4.25)

        let minimum = CostEstimate(known: 1, knownTokens: 10, minimum: 0.5, minimumTokens: 300)
        #expect(minimum.coverage == .partial && minimum.value == nil && minimum.amount == 1.5 && !minimum.isProvisional)
        #expect(Fmt.cost(minimum) == "≥$1.50")
        #expect(Fmt.costDetail(minimum) == "Partial estimate: $1.00 known; at least $0.50 for 300 cache-write tokens of unknown tier")

        let disputed = CostEstimate(known: 1, knownTokens: 10, disputedTokens: 200)
        #expect(disputed.coverage == .partial && disputed.amount == 1 && disputed.isProvisional)
        #expect(Fmt.cost(disputed) == "~$1.00") // never ≥: no bound is claimed when quantities disagree
        #expect(Fmt.costDetail(disputed) == "Provisional estimate, not a lower bound: $1.00 known; cost unknown for 200 provisional cache-write tokens")

        let onlyMinimum = CostEstimate(minimum: 0.5, minimumTokens: 300)
        #expect(onlyMinimum.coverage == .partial) // something is known: at least the minimum
        #expect(CostEstimate(disputedTokens: 5).coverage == .unavailable)

        let sum = minimum + disputed + CostEstimate(unknownTokens: 7)
        #expect(sum.known == 2 && sum.minimum == 0.5 && sum.minimumTokens == 300 && sum.disputedTokens == 200
                && sum.unknownTokens == 7 && sum.knownTokens == 20)
        // A minimum next to disputed tokens is conditional, so it's no longer called "at least".
        #expect(sum.isProvisional && Fmt.cost(sum) == "~$2.50")
        #expect(Fmt.costDetail(sum) == "Provisional estimate, not a lower bound: $2.00 known; $0.50 more for 300 cache-write tokens of unknown tier, if the logged cache-write totals are right; cost unknown for 7 tokens; cost unknown for 200 provisional cache-write tokens")
        #expect(Fmt.costDetail(CostEstimate(disputedTokens: 5)) == "Cost unavailable: cost unknown for 5 tokens")
    }

    /// What VoiceOver reads for each kind of cost, and the legend and chart marks that explain ~ next to ≥ and n/a.
    @Test func provisionalCostCopy() throws {
        let complete = CostEstimate(known: 4.25, knownTokens: 10)
        let minimum = CostEstimate(known: 1, knownTokens: 10, minimum: 0.5, minimumTokens: 300) // F11: flat > breakdown
        let provisional = CostEstimate(known: 1, knownTokens: 10, minimum: 0.5, minimumTokens: 300, disputedTokens: 200)
        #expect(Fmt.spokenCost(complete) == "$4.25" && Fmt.spokenCost(minimum) == "at least $1.50")
        #expect(Fmt.spokenCost(provisional) == "about $1.50, provisional")
        #expect(Fmt.spokenCost(CostEstimate(unknownTokens: 3)) == "cost not available")
        #expect(Fmt.cost(minimum) == "≥$1.50" && Fmt.cost(provisional) == "~$1.50")
        // At P9's real scale: F42's 30 days after step 2 (Haiku known, minimum and disputed; claude-test-1 unpriced).
        let f42 = CostEstimate(known: 0.0002685, knownTokens: 144, unknownTokens: 44, minimum: 0.000525, minimumTokens: 420,
                               disputedTokens: 280)
        #expect(Fmt.cost(f42) == "~$0.0008" && Fmt.spokenCost(f42) == "about $0.0008, provisional")
        #expect(Fmt.costDetail(f42) == "Provisional estimate, not a lower bound: $0.0002 known; $0.0005 more for 420 cache-write tokens of unknown tier, if the logged cache-write totals are right; cost unknown for 44 tokens; cost unknown for 280 provisional cache-write tokens")
        // F11 has a minimum and no dispute: a lower bound, rounded down.
        let f11 = CostEstimate(known: 0.000991, knownTokens: 1517, minimum: 0.000375, minimumTokens: 300)
        #expect(Fmt.cost(f11) == "≥$0.001" && Fmt.spokenCost(f11) == "at least $0.001")
        #expect(Fmt.approximate(0.0007935) == "$0.0008" && Fmt.approximate(1.005) == "$1.01" && Fmt.approximate(0.15) == "$0.15")
        #expect(PricingText.unpricedRule.contains("costs show ~ (provisional, not a lower bound)"))

        var s = UsageSummary()
        s.models = [ModelRow(model: "claude-haiku", tokens: 520, cost: minimum)]
        s.month = Totals(tokens: 520, cost: minimum)
        let partial = try #require(PricingText.coverageNote(claude: s, grok: nil))
        #expect(partial.hasPrefix("≥ partial estimate, n/a no estimate: ") && !partial.contains("~"))
        #expect(partial.hasSuffix("On the chart, \"?\" marks days whose cost isn't fully known."))

        s.models = [ModelRow(model: "claude-haiku", tokens: 510, cost: provisional)]
        s.month = Totals(tokens: 510, cost: provisional, quantity: QuantityUncertainty(disputedTokens: 200))
        let note = try #require(PricingText.coverageNote(claude: s, grok: nil))
        #expect(note.hasPrefix("≥ partial estimate, ~ provisional estimate, n/a no estimate: "))
        #expect(note.contains("Provisional estimate, not a lower bound: $1.00 known; $0.50 more for 300 cache-write tokens"))
        #expect(note.hasSuffix("\"?\" marks days whose cost isn't fully known and \"~\" days whose cost is provisional."))
        #expect(QuantityText.note(s)?.detail.contains("200 cache-write tokens are counted provisionally") == true)

        // The chart marks a day by its own coverage.
        let day = Calendar.current.startOfDay(for: Date())
        s.bars = [DayBar(day: day, family: "Haiku", tokens: 510, cost: provisional),
                  DayBar(day: day.addingTimeInterval(-86400), family: "Haiku", tokens: 520, cost: minimum)]
        #expect(s.incompleteCostDays.map(\.cost.isProvisional) == [false, true])
        #expect(s.incompleteCostDays.map(\.cost.amount) == [1.5, 1.5])
    }

    // MARK: Streamed cache writes (P9 re-review)

    private static func cw(_ t5: Int, _ t1: Int, u: Int = 0, d: Int = 0) -> Agg {
        Agg(input: 1, output: 1, cacheWrite5m: t5, cacheWrite1h: t1, calls: 1,
            cacheWriteUnresolved: u == 0 ? nil : u, cacheWriteDisputed: d == 0 ? nil : d)
    }

    /// An operation's records reconcile to the same result in every order and grouping, and a reclassification never
    /// adds tokens: the cache-write quantity is the largest any record reported.
    @Test func reconcileIsOrderIndependent() {
        let records = [Self.cw(50, 50), Self.cw(0, 0, u: 100), Self.cw(30, 70), Self.cw(0, 0, u: 40, d: 60),
                       Self.cw(0, 0, u: 20, d: 80), Self.cw(100, 0)]
        func permutations(_ a: [Agg]) -> [[Agg]] {
            a.count <= 1 ? [a] : a.indices.flatMap { i in
                permutations(Array(a[..<i] + a[(i + 1)...])).map { [a[i]] + $0 }
            }
        }
        var results: [Agg] = []
        for order in permutations(records) {
            // Folded one record at a time, as streaming does, and as two halves joined, as a #55 merge does.
            let folded = order.dropFirst().reduce(order[0]) { $0.reconciled(with: $1) }
            let halves = order[..<3].dropFirst().reduce(order[0]) { $0.reconciled(with: $1) }
                .reconciled(with: order[4...].reduce(order[3]) { $0.reconciled(with: $1) })
            results += [folded, halves]
        }
        #expect(Set(results.map { "\($0)" }).count == 1)
        // All six report 100: the most disputed record's split wins, and no tier is priced as exact.
        #expect(results[0] == Self.cw(0, 0, u: 20, d: 80) && results[0].cacheWrites == 100)

        // Each transition, both ways: at equal quantity the less certain wins.
        let pairs: [(Agg, Agg, Agg)] = [
            (Self.cw(50, 50), Self.cw(0, 0, u: 100), Self.cw(0, 0, u: 100)),              // tiered <-> unresolved
            (Self.cw(60, 40), Self.cw(0, 0, u: 40, d: 60), Self.cw(0, 0, u: 40, d: 60)),  // tiered <-> disputed
            (Self.cw(0, 0, u: 100), Self.cw(0, 0, u: 20, d: 80), Self.cw(0, 0, u: 20, d: 80)), // unresolved <-> disputed
            (Self.cw(50, 50), Self.cw(30, 70), Self.cw(0, 0, u: 100)),                    // two splits of 100
            (Self.cw(50, 50), Self.cw(50, 50), Self.cw(50, 50)),                          // the same record again
            (Self.cw(0, 0, u: 100, d: 200), Self.cw(350, 0), Self.cw(350, 0)),            // more wins, whatever its class
        ]
        for (a, b, want) in pairs {
            #expect(a.reconciled(with: b) == want && b.reconciled(with: a) == want, "\(a) / \(b)")
            #expect(a.reconciled(with: b).total == max(a.total, b.total))
        }
        // Reclassifying moves tokens between fields; the bucket's difference adds nothing.
        let d = Self.cw(0, 0, u: 100).difference(from: Self.cw(50, 50))
        #expect(d.hasDecrease && d.total == 0 && d.cacheWrite5m == -50 && d.unresolved == 100)
    }

    /// A reclassification in a bucket held at `Int.max`, then a #55 join: the bucket is rebuilt, not reduced, so it
    /// becomes exact again instead of showing `Int.max` minus the moved tokens as exact.
    @Test func heldBucketReclassifiedThenMerged() async throws {
        let box = try Sandbox()
        func line(_ id: String?, _ req: String?, t5: Int, t1: Int = 0) -> String {
            let ts = ISO8601DateFormatter().string(from: Date())
            let r = req.map { #""requestId":"\#($0)","# } ?? "", m = id.map { #""id":"\#($0)","# } ?? ""
            return #"{"type":"assistant","timestamp":"\#(ts)",\#(r)"message":{\#(m)"model":"claude-test-1","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":\#(Self.big),"cache_creation":{"ephemeral_5m_input_tokens":\#(t5),"ephemeral_1h_input_tokens":\#(t1)}}}}"#
        }
        // 1023 pairs + one message-only + one request-only record, each `big` 5-minute writes: more than Int holds.
        var lines = (0..<1023).map { line("msg_\($0)", "req_\($0)", t5: Self.big) }
        lines += [line("msg_P", nil, t5: Self.big), line(nil, "req_P", t5: Self.big)]
        let file = try box.write(".claude/projects/-p/s1.jsonl", lines.joined(separator: "\n") + "\n")
        let ledger = Self.ledger(box)
        func bucket() async -> Agg {
            await withCheckedContinuation { c in ledger.claudeHourlyUsage { c.resume(returning: $0) } }
                .values.compactMap { $0["claude-test-1"] }.first ?? Agg()
        }
        func append(_ l: String) throws {
            let h = try FileHandle(forWritingTo: file)
            try h.seekToEnd()
            try h.write(contentsOf: Data((l + "\n").utf8))
            try h.close()
        }
        _ = await refreshLedger(ledger)
        #expect(await bucket().cacheWrite5m == .max)

        // msg_0 is logged again with the same quantity split differently: its tier becomes unresolved.
        try append(line("msg_0", "req_0", t5: Self.big - 1, t1: 1))
        let s = await refreshLedger(ledger).claude
        let b = await bucket()
        #expect(b.cacheWrite5m == 1024 * Self.big && b.cacheWrite1h == 0 && b.unresolved == Self.big)
        #expect(s.month.tokens == .max && s.month.quantity.saturated) // 1025 big is still more than Int holds

        // The pair joins the two partials: one big operation goes, and every sum is exact again.
        try append(line("msg_P", "req_P", t5: Self.big))
        let after = await refreshLedger(ledger).claude
        let exact = await bucket()
        #expect(exact.cacheWrite5m == 1023 * Self.big && exact.unresolved == Self.big && !exact.isSaturated)
        #expect(after.month.tokens == 1024 * Self.big && after.month.quantity.isExact)
        ledger.flush()
        #expect(await refreshLedger(Self.ledger(box)).claude.month.tokens == 1024 * Self.big)
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
