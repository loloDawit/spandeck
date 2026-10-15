import Foundation
import Testing
@testable import Headroom

/// R7: a missing price is never a $0 cost. Every total carries its coverage (complete, partial, unavailable) through
/// hours, days, windows, providers and the Claude + Grok combination; known costs and token counts are kept. All
/// fixtures are synthetic: each transcript line is 100 input + 50 output tokens, each Grok turn too.
@MainActor
struct CostCompletenessTests {
    /// Synthetic prices: `claude-priced` at $1,000 / M tokens in and out ($0.15 per line), `claude-free` at $0.
    nonisolated private static let table = #"{"claude-priced":{"input":0.001,"output":0.001,"cacheWrite":0.001,"cacheWrite1h":0.001,"cacheRead":0.001},"claude-free":{"input":0,"output":0,"cacheWrite":0,"cacheWrite1h":0,"cacheRead":0}}"#
    nonisolated private static let line = 0.15

    private struct Rig {
        let box: Sandbox
        let pricing: Pricing
        let ledger: Ledger

        /// `table` nil uses the real built-in snapshot; `damaged` gives it a wrong checksum (no prices at all).
        init(table: String? = CostCompletenessTests.table, damaged: Bool = false,
             pin: PricingPin = PricingPin(revision: String(repeating: "b", count: 40), sourceSHA256: ""),
             transport: HTTPTransport = FakeTransport()) throws {
            box = try Sandbox()
            if let table {
                let bundle = PricingBundle(revision: String(repeating: "a", count: 40), sourceSHA256: "", retrieved: "x",
                                           tableSHA256: damaged ? "0" : Pricing.sha256(Data(table.utf8)), tableJSON: table)
                pricing = Pricing(directory: box.appSupport, transport: transport, pin: pin, bundle: bundle)
            } else {
                pricing = Pricing(directory: box.appSupport, transport: transport)
            }
            pricing.load()
            ledger = Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing)
        }

        /// Writes one transcript with a line per (model, date).
        func claude(_ lines: [(String, Date)], file: String = "s1") throws {
            let text = lines.enumerated().map { i, l in
                Sandbox.transcriptLine(model: l.0, id: "\(file)-\(i)", canary: "x", date: l.1)
            }.joined(separator: "\n") + "\n"
            try box.write(".claude/projects/-Users-synthetic-proj/\(file).jsonl", text)
        }

        func summaries(window: Date? = nil) async -> (claude: UsageSummary, grok: UsageSummary) {
            await withCheckedContinuation { c in
                ledger.refresh(windowStart: window, progress: { _ in },
                               completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
            }
        }
    }

    private static func cost(_ known: Double, _ knownTokens: Int, _ unknownTokens: Int = 0) -> CostEstimate {
        CostEstimate(known: known, knownTokens: knownTokens, unknownTokens: unknownTokens)
    }

    private static func near(_ a: CostEstimate, _ b: CostEstimate) -> Bool {
        abs(a.known - b.known) < 1e-12 && a.knownTokens == b.knownTokens && a.unknownTokens == b.unknownTokens
    }

    // MARK: Model

    @Test func coverageRules() {
        let empty = CostEstimate.zero, known = Self.cost(1, 10), zero = Self.cost(0, 10)
        let unknown = Self.cost(0, 0, 10)
        #expect(empty.coverage == .complete && zero.coverage == .complete && known.coverage == .complete)
        #expect(unknown.coverage == .unavailable)
        #expect((known + known).coverage == .complete && (known + known).known == 2)
        #expect((known + unknown).coverage == .partial && (known + unknown).known == 1)
        #expect((zero + unknown).coverage == .partial) // a known zero is still known coverage
        #expect((unknown + unknown).coverage == .unavailable)
        // An empty period adds nothing: it never turns "unavailable" into "partial".
        #expect((empty + unknown).coverage == .unavailable && (unknown + empty) == unknown)
        #expect((empty + empty) == .zero)
        #expect(known.value == 1 && unknown.value == nil && (known + unknown).value == nil)
    }

    @Test func formatting() {
        #expect(Fmt.cost(.zero) == "$0.00")
        #expect(Fmt.cost(Self.cost(4.25, 10)) == "$4.25")
        #expect(Fmt.cost(Self.cost(4.25, 10, 5)) == "≥$4.25")
        #expect(Fmt.cost(Self.cost(0, 0, 5)) == "n/a")
        #expect(Fmt.cost(Self.cost(0.003, 10)) == "<$0.01") // tiny but real is not shown as free
        // A partial cost shows its known part rounded down (it's a lower bound), keeping a tiny amount visible.
        #expect(Fmt.cost(Self.cost(0.003, 10, 5)) == "≥$0.003")
        #expect(Fmt.cost(Self.cost(0.0099, 10, 5)) == "≥$0.009")
        #expect(Fmt.cost(Self.cost(3e-10, 10, 5)) == "≥$0.0000000003") // one Grok tick unit
        #expect(Fmt.cost(Self.cost(0, 10, 5)) == "≥$0.00")                // known part really is $0
        #expect(Fmt.cost(Self.cost(4.249, 10, 5)) == "≥$4.24" && Fmt.cost(Self.cost(0.29, 10, 5)) == "≥$0.29")
        #expect(Fmt.cost(Self.cost(150.9, 10, 5)) == "≥$150" && Fmt.cost(Self.cost(1999, 10, 5)) == "≥$1.9k")
        #expect(Fmt.usd(0.005) == "$0.01" && Fmt.usd(0) == "$0.00")
        #expect(Fmt.costDetail(Self.cost(4.25, 10, 500_000)) == "Partial estimate: $4.25 known; cost unknown for 500.0K tokens")
        #expect(Fmt.costDetail(Self.cost(0.003, 10, 5)).contains("$0.003 known"))
        #expect(Fmt.costDetail(Self.cost(0, 0, 500_000)) == "Cost unavailable: cost unknown for 500.0K tokens")
        #expect(!Fmt.costDetail(Self.cost(0, 0, 5)).contains("price")) // could be Grok, which has no price list
    }

    // MARK: Golden fixtures

    enum Scenario: String, CaseIterable {
        case empty, priced, knownZero, unpriced, mixed, grokReported, grokMissing, grokMixed, mixedProviders
    }

    /// Expected 30-day costs (Claude, Grok, combined) and how the combined total is shown.
    private static func expected(_ s: Scenario) -> (CostEstimate, CostEstimate, CostEstimate, String) {
        switch s {
        case .empty: return (.zero, .zero, .zero, "$0.00")
        case .priced: return (cost(2 * line, 300), .zero, cost(2 * line, 300), "$0.30")
        case .knownZero: return (cost(0, 150), cost(0, 150), cost(0, 300), "$0.00")
        case .unpriced: return (cost(0, 0, 150), .zero, cost(0, 0, 150), "n/a")
        case .mixed: return (cost(line, 150, 150), .zero, cost(line, 150, 150), "≥$0.15")
        case .grokReported: return (.zero, cost(0.25, 150), cost(0.25, 150), "$0.25")
        case .grokMissing: return (.zero, cost(0, 0, 150), cost(0, 0, 150), "n/a")
        case .grokMixed: return (.zero, cost(0.25, 150, 150), cost(0.25, 150, 150), "≥$0.25")
        case .mixedProviders: return (cost(line, 150), cost(0, 0, 150), cost(line, 150, 150), "≥$0.15")
        }
    }

    @Test(arguments: Scenario.allCases)
    func golden(_ s: Scenario) async throws {
        let rig = try Rig()
        let now = Date()
        switch s {
        case .empty: break
        case .priced: try rig.claude([("claude-priced", now), ("claude-priced", now)])
        case .knownZero:
            try rig.claude([("claude-free", now)])
            try rig.box.writeGrokUsage(session: "g", turns: [(now, 0, "grok-test")])
        case .unpriced: try rig.claude([("claude-new-9", now)])
        case .mixed: try rig.claude([("claude-priced", now), ("claude-new-9", now)])
        case .grokReported: try rig.box.writeGrokUsage(session: "g", turns: [(now, 2_500_000_000, "grok-test")])
        case .grokMissing: try rig.box.writeGrokUsage(session: "g", turns: [(now, nil, "grok-test")])
        case .grokMixed:
            try rig.box.writeGrokUsage(session: "g", turns: [(now, 2_500_000_000, "grok-test"), (now, nil, "grok-test")])
        case .mixedProviders:
            try rig.claude([("claude-priced", now)])
            try rig.box.writeGrokUsage(session: "g", turns: [(now, nil, "grok-test")])
        }

        let (claude, grok) = await rig.summaries()
        let combined = try #require(UsageSummary.combine(claude, grok))
        let (c, g, both, shown) = Self.expected(s)

        #expect(Self.near(claude.month.cost, c), "\(s) claude \(claude.month.cost)")
        #expect(Self.near(grok.month.cost, g), "\(s) grok \(grok.month.cost)")
        #expect(Self.near(combined.month.cost, both), "\(s) combined \(combined.month.cost)")
        #expect(Fmt.cost(combined.month.cost) == shown, "\(s) \(Fmt.cost(combined.month.cost))")
        // Today, 7 and 30 days agree here (all usage is now); tokens are never lost.
        #expect(combined.today.cost == combined.month.cost && combined.week.cost == combined.month.cost)
        #expect(combined.month.tokens == both.knownTokens + both.unknownTokens)
        // The explanation names exactly the models whose cost isn't fully known.
        let uncosted = combined.models.filter { $0.cost.coverage != .complete }.map(\.model).sorted()
        #expect(combined.uncostedModels == uncosted && (PricingText.coverageNote(combined) == nil) == uncosted.isEmpty)
    }

    // MARK: Aggregation

    /// Today, 7 days, 30 days and the 5-hour window each keep their own coverage.
    @Test func windowsKeepTheirOwnCoverage() async throws {
        let rig = try Rig()
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        let threeDays = Calendar.current.date(byAdding: .hour, value: -60, to: today)!
        let tenDays = Calendar.current.date(byAdding: .day, value: -10, to: today)!
        try rig.claude([("claude-priced", now), ("claude-priced", threeDays), ("claude-new-9", tenDays)])

        let s = await rig.summaries(window: now.addingTimeInterval(-5 * 3600)).claude

        #expect(Self.near(s.today.cost, Self.cost(Self.line, 150)))
        #expect(Self.near(s.week.cost, Self.cost(2 * Self.line, 300)))
        #expect(Self.near(s.month.cost, Self.cost(2 * Self.line, 300, 150)) && s.month.cost.coverage == .partial)
        #expect(Self.near(try #require(s.window).cost, Self.cost(Self.line, 150)))
        #expect(s.today.tokens == 150 && s.week.tokens == 300 && s.month.tokens == 450)
    }

    @Test func windowIsIncompleteOnItsOwn() async throws {
        let rig = try Rig()
        let now = Date()
        try rig.claude([("claude-new-9", now), ("claude-priced", now.addingTimeInterval(-6 * 3600))])

        let s = await rig.summaries(window: now.addingTimeInterval(-5 * 3600)).claude

        #expect(try #require(s.window).cost.coverage == .unavailable && s.window?.tokens == 150)
        #expect(s.month.cost.coverage == .partial)
    }

    /// Model rows, provider rows and daily bars keep unknown costs; the chart marks those days.
    @Test func rowsAndChartKeepUnknowns() async throws {
        let rig = try Rig()
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -5, to: Calendar.current.startOfDay(for: now))!
        try rig.claude([("claude-priced", now), ("claude-new-9", now), ("claude-priced", old)])

        let s = await rig.summaries().claude

        let rows = Dictionary(uniqueKeysWithValues: s.models.map { ($0.model, $0) })
        #expect(rows["claude-new-9"]?.cost.coverage == .unavailable && rows["claude-new-9"]?.tokens == 150)
        #expect(Fmt.cost(try #require(rows["claude-new-9"]).cost) == "n/a")
        #expect(Self.near(try #require(rows["claude-priced"]).cost, Self.cost(2 * Self.line, 300)))
        // Provider row text, as ProviderRow shows it.
        #expect(Fmt.cost(s.today.cost) == "≥$0.15" && Fmt.cost(s.month.cost) == "≥$0.30")
        // Only today is incomplete on the chart, with its known part; the older day is complete.
        let days = s.incompleteCostDays
        #expect(days.count == 1 && days.first?.day == Calendar.current.startOfDay(for: now))
        #expect(abs((days.first?.known ?? -1) - Self.line) < 1e-12)
        let todayBars = s.bars.filter { $0.day == Calendar.current.startOfDay(for: now) }
        #expect(todayBars.reduce(CostEstimate.zero) { $0 + $1.cost }.coverage == .partial)
    }

    @Test func combiningNeverHidesAnIncompleteProvider() {
        var complete = UsageSummary()
        complete.month = Totals(tokens: 100, cost: Self.cost(4, 100))
        var partial = UsageSummary()
        partial.month = Totals(tokens: 300, cost: Self.cost(1, 100, 200))
        var unavailable = UsageSummary()
        unavailable.month = Totals(tokens: 50, cost: Self.cost(0, 0, 50))

        #expect(UsageSummary.combine(complete, partial)?.month.cost == Self.cost(5, 200, 200))
        #expect(UsageSummary.combine(partial, complete)?.month.cost.coverage == .partial)
        #expect(UsageSummary.combine(complete, unavailable)?.month.cost.coverage == .partial)
        #expect(UsageSummary.combine(unavailable, unavailable)?.month.cost.coverage == .unavailable)
        #expect(UsageSummary.combine(complete, complete)?.month.cost == Self.cost(8, 200))
        #expect(UsageSummary.combine(complete, nil)?.month.cost == Self.cost(4, 100))
    }

    // MARK: Prices

    /// A model the snapshot doesn't list gets no guessed price; a date-suffixed id of a listed one still resolves.
    @Test func newClaudeModelIsNotGuessed() async throws {
        let rig = try Rig(table: nil)
        try rig.claude([("claude-opus-9-1", Date()), ("claude-opus-4-8-20261001", Date())])

        let s = await rig.summaries().claude

        let rows = Dictionary(uniqueKeysWithValues: s.models.map { ($0.model, $0.cost) })
        #expect(rows["claude-opus-9-1"]?.coverage == .unavailable)
        #expect(rows["claude-opus-4-8-20261001"]?.coverage == .complete)
        #expect(s.month.cost.coverage == .partial && s.month.tokens == 300)
    }

    /// No verified prices at all: Claude costs are unavailable, while Grok's reported costs are unaffected.
    @Test func missingSnapshotMeansUnavailableClaudeOnly() async throws {
        let rig = try Rig(damaged: true)
        #expect(rig.pricing.info == .unavailable)
        try rig.claude([("claude-priced", Date())])
        try rig.box.writeGrokUsage(session: "g", turns: [(Date(), 2_500_000_000, "grok-test")])

        let (claude, grok) = await rig.summaries()

        #expect(claude.month.cost == Self.cost(0, 0, 150) && claude.month.tokens == 150)
        #expect(Self.near(grok.month.cost, Self.cost(0.25, 150)))
        #expect(UsageSummary.combine(claude, grok)?.month.cost.coverage == .partial)
    }

    /// Verified new prices turn an unavailable estimate complete, recomputed from the same token data.
    @Test func newPricesRecomputeCoverage() async throws {
        // $500 / M tokens: the default 1-hour cache price (2x input) stays within R6's $1,000 / M limit.
        let upstream = Data(#"{"claude-new-9":{"input_cost_per_token":0.0005,"output_cost_per_token":0.0005}}"#.utf8)
        let pin = PricingPin(revision: String(repeating: "b", count: 40), sourceSHA256: Pricing.sha256(upstream))
        let rig = try Rig(pin: pin, transport: FakeTransport([Hosts.pricing: [.init(status: 200, body: upstream)]]))
        try rig.claude([("claude-new-9", Date()), ("claude-priced", Date())])

        let before = await rig.summaries().claude
        #expect(before.month.cost.coverage == .partial)
        _ = try await rig.pricing.update().get()
        let after = await rig.summaries().claude

        #expect(after.month.tokens == before.month.tokens)
        // The downloaded table prices claude-new-9 and (not listed there) no longer claude-priced.
        #expect(Self.near(after.month.cost, Self.cost(Self.line / 2, 150, 150)))
        #expect(after.models.first { $0.model == "claude-new-9" }?.cost.coverage == .complete)
    }

    // MARK: Grok

    @Test func grokMissingCostIsNotZero() async throws {
        let rig = try Rig()
        let now = Date()
        try rig.box.writeGrokUsage(session: "a", turns: [(now, nil, "grok-test")])
        // A different time: the unchanged dedupe key reads a missing cost as 0, so identical turns would merge.
        try rig.box.writeGrokUsage(session: "b", turns: [(now.addingTimeInterval(-1), 0, "grok-zero")])

        let grok = await rig.summaries().grok

        let rows = Dictionary(uniqueKeysWithValues: grok.models.map { ($0.model, $0.cost) })
        #expect(rows["grok-test"] == Self.cost(0, 0, 150)) // missing: unknown
        #expect(rows["grok-zero"] == Self.cost(0, 150))    // reported 0: a real $0
        #expect(grok.month.cost == Self.cost(0, 150, 150) && Fmt.cost(grok.month.cost) == "≥$0.00")
    }

    /// A turn without a cost and a copy of it reporting $0 share a dedupe key. The copy that reports a cost counts,
    /// whichever is read first, so coverage doesn't depend on file order.
    @Test func grokDuplicateChoiceIgnoresOrder() {
        func turn(_ ticks: Int?, _ model: String = "grok-test") -> Ledger.GrokTurn {
            Ledger.GrokTurn(key: "t|150|0", hour: 1, model: model,
                            agg: Agg(input: 100, output: 50, calls: 1, costTicks: ticks))
        }
        let turns = [turn(nil), turn(0), turn(nil, "grok-a")]
        for order in [turns, turns.reversed(), [turns[1], turns[2], turns[0]], [turns[2], turns[0], turns[1]]] {
            let kept = Ledger.uniqueGrokTurns(order)
            #expect(kept.count == 1 && kept[0].agg.costTicks == 0 && kept[0].model == "grok-test")
        }
        // With no reported cost anywhere, the choice is still fixed (lowest model), and the cost stays unknown.
        for order in [[turn(nil, "grok-b"), turn(nil, "grok-a")], [turn(nil, "grok-a"), turn(nil, "grok-b")]] {
            let kept = Ledger.uniqueGrokTurns(order)
            #expect(kept.count == 1 && kept[0].model == "grok-a" && kept[0].agg.costTicks == nil)
        }
    }

    @Test func grokDuplicateAcrossSessionsCountsOnce() async throws {
        let now = Date()
        for (missing, zero) in [("a", "b"), ("b", "a")] {
            let rig = try Rig()
            try rig.box.writeGrokUsage(session: missing, turns: [(now, nil, "grok-test")])
            try rig.box.writeGrokUsage(session: zero, turns: [(now, 0, "grok-test")])
            let grok = await rig.summaries().grok
            #expect(grok.month.tokens == 150 && grok.month.cost == Self.cost(0, 150), "\(missing) \(grok.month.cost)")
        }
    }

    /// The note names an unpriced Claude model and a Grok model with missing costs as different causes.
    @Test func coverageNoteSeparatesCauses() throws {
        var s = UsageSummary(monthStart: Date())
        s.models = [ModelRow(model: "claude-new-9", tokens: 150, cost: Self.cost(0, 0, 150)),
                    ModelRow(model: "grok-test", tokens: 150, cost: Self.cost(0, 0, 150))]
        s.month.cost = Self.cost(0, 0, 300)
        let note = try #require(PricingText.coverageNote(s))
        #expect(note.contains("no price for claude-new-9;"))
        #expect(note.contains("the Grok CLI reported no cost for some grok-test turns"))
        #expect(!note.contains("no price for grok"))
        s.models.removeFirst()
        #expect(PricingText.coverageNote(s)?.contains("no price") == false)
        #expect(PricingText.unpricedRule.contains("some Grok turns have no reported cost"))
    }

    // MARK: Compatibility

    /// A ledger cache written before R7 still loads (no re-index), and R7 writes nothing new into Claude's cache.
    @Test func ledgerCacheCompatible() async throws {
        let old = #"{"input":100,"output":50,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":1}"#
        let agg = try JSONDecoder().decode(Agg.self, from: Data(old.utf8))
        #expect(agg.total == 150 && agg.costTicks == nil && agg.uncostedTokens == nil)

        let rig = try Rig()
        try rig.claude([("claude-priced", Date())])
        _ = await rig.summaries()
        rig.ledger.flush()
        let cache = try String(contentsOf: rig.box.appSupport.appendingPathComponent("claude-ledger.json"), encoding: .utf8)
        #expect(!cache.contains("uncostedTokens"))

        // Transcripts gone: a new ledger can only have the tokens from the cache.
        try FileManager.default.removeItem(at: rig.box.home.appendingPathComponent(".claude"))
        let reloaded = Ledger(home: rig.box.home, appSupport: rig.box.appSupport, pricing: rig.pricing)
        let s = await withCheckedContinuation { c in
            reloaded.refresh(windowStart: nil, progress: { _ in }, completion: { claude, _, _ in c.resume(returning: claude) })
        }
        #expect(s.month.tokens == 150 && Self.near(s.month.cost, Self.cost(Self.line, 150)))
    }
}
