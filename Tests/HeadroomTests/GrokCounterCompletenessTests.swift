import Foundation
import Testing
@testable import Headroom

/// Metric contract F-1 (#7): a Grok turn's missing or invalid counter is never read as 0. The turn's valid counters
/// still count, and the turn is flagged (P8 rules) so the totals carry *incomplete data*. An explicit 0 stays an exact
/// 0. The dedupe key spells an absent `totalTokens` apart from a reported 0. All fixtures are synthetic.
struct GrokCounterCompletenessTests {
    private struct Rig {
        let box: Sandbox
        let ledger: Ledger

        init() throws {
            box = try Sandbox()
            let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
            ledger = Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing)
        }

        /// One `usage.json` whose turns are given as the JSON members after `endedAt` and the model.
        func grok(session: String = "s", _ turns: [String], ended: Date = Date()) throws {
            let stamp = ISO8601DateFormatter().string(from: ended)
            let list = turns.map { #"{"endedAt":"\#(stamp)","primaryModelId":"grok-test","# + $0 + "}" }
            try box.write(".grok/sessions/proj/\(session)/usage.json", #"{"turns":["# + list.joined(separator: ",") + "]}")
        }

        func summaries() async -> (claude: UsageSummary, grok: UsageSummary) {
            await withCheckedContinuation { c in
                ledger.refresh(windowStart: nil, progress: { _ in },
                               completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
            }
        }
    }

    /// 100 input of which 20 cached, 50 output, 5 cache writes: 80 + 20 + 50 + 5 = 155 tokens.
    private static let counters: [(String, String)] = [
        ("inputTokens", "100"), ("cachedReadTokens", "20"), ("outputTokens", "50"), ("cacheCreationTokens", "5"),
        ("modelCalls", "1"), ("totalTokens", "155"), ("costUsdTicks", "10"),
    ]

    /// The full turn with `field` replaced by `value`, or left out when `value` is nil.
    private static func turn(_ field: String? = nil, _ value: String? = nil) -> String {
        counters.compactMap { k, v in
            guard k == field else { return #""\#(k)":\#(v)"# }
            return value.map { #""\#(k)":\#($0)"# }
        }.joined(separator: ",")
    }

    @Test func validTurnIsExactAndComplete() async throws {
        let rig = try Rig()
        try rig.grok([Self.turn()])
        let grok = await rig.summaries().grok
        #expect(grok.today.tokens == 155 && grok.month.tokens == 155)
        #expect(grok.month.completeness.isComplete)
    }

    /// A reported 0 is a value: counted as exactly 0, never flagged.
    @Test func explicitZerosAreExactZeros() async throws {
        let rig = try Rig()
        try rig.grok([#""inputTokens":0,"cachedReadTokens":0,"outputTokens":0,"cacheCreationTokens":0,"modelCalls":0,"#
                      + #""totalTokens":0,"costUsdTicks":0"#])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 0 && grok.month.completeness == DataCompleteness())
        #expect(grok.models.map(\.model) == ["grok-test"] && grok.month.cost.coverage == .complete)
    }

    /// Each counter left out in turn: the others still count, and the turn is flagged instead of reading 0.
    /// Without `cachedReadTokens` the input can't be split, so all of it counts as input (the token total is unchanged);
    /// without `inputTokens` only the cache reads are known.
    @Test(arguments: [("inputTokens", 75), ("cachedReadTokens", 155), ("outputTokens", 105),
                      ("cacheCreationTokens", 150), ("modelCalls", 155), ("totalTokens", 155)])
    func missingCounterFlagsTheTurn(_ field: String, _ tokens: Int) async throws {
        for value in [nil, "null"] as [String?] {
            let rig = try Rig()
            try rig.grok([Self.turn(field, value)])
            let grok = await rig.summaries().grok
            #expect(grok.month.tokens == tokens, "\(field) = \(value ?? "absent")")
            #expect(grok.month.completeness == DataCompleteness(flawed: 1), "\(field) = \(value ?? "absent")")
            #expect(grok.today.completeness.flawed == 1 && grok.week.completeness.flawed == 1)
        }
    }

    /// Negative, fractional, too large, a string or a boolean is invalid: left out and flagged, never 0 or 1.
    @Test(arguments: ["-1", "1.5", "1e30", #""50""#, "true", "false", "{}", "[50]"])
    func invalidCounterIsLeftOutAndFlagged(_ value: String) async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("outputTokens", value)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 105, "outputTokens = \(value)")
        #expect(grok.month.completeness == DataCompleteness(flawed: 1), "outputTokens = \(value)")
    }

    /// Valid spellings of a whole number still count: 50.0 and 5e1 are 50.
    @Test(arguments: ["50.0", "5e1"])
    func integralSpellingsAreValid(_ value: String) async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("outputTokens", value)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155 && grok.month.completeness.isComplete)
    }

    /// More cache reads than input is a conflict, not 0 uncached input: the turn is flagged, and only what both
    /// counters allow (the smaller, 100) is counted for the input side. Before the fix the difference was clamped to 0
    /// and the 120 cache reads counted on top, unflagged (175).
    @Test func cachedReadsAboveInputAreAConflict() async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("cachedReadTokens", "120")])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155)
        #expect(grok.month.completeness == DataCompleteness(flawed: 1))
    }

    /// Cached reads equal to the input are valid: all of it is cached.
    @Test func cachedReadsEqualToInputAreValid() async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("cachedReadTokens", "100")])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155 && grok.month.completeness.isComplete)
    }

    /// Each turn is checked on its own: a flawed turn doesn't hide its neighbours' counts.
    @Test func flawsAreCountedPerTurn() async throws {
        let rig = try Rig()
        let second = Self.turn("totalTokens", "156"), third = Self.turn("totalTokens", "157")
        try rig.grok([Self.turn("outputTokens", "-1"), second.replacingOccurrences(of: #""modelCalls":1"#, with: #""modelCalls":"x""#),
                      third])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 105 + 155 + 155)
        #expect(grok.month.completeness == DataCompleteness(flawed: 2))
    }

    // MARK: Dedupe identity

    /// An absent `totalTokens` and a reported 0 are different turns. Before the fix both keys read 0, so one of the two
    /// turns vanished.
    @Test func absentTotalIsNotZeroTotal() async throws {
        let rig = try Rig()
        try rig.grok(session: "a", [Self.turn("totalTokens", "0")])
        try rig.grok(session: "b", [Self.turn("totalTokens", nil)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 310)
        #expect(grok.month.completeness == DataCompleteness(flawed: 1)) // the turn without a total
    }

    /// Copies of one turn (resumed or forked sessions) still count once, whether the shared total is reported,
    /// absent or invalid.
    @Test(arguments: ["155", nil, #""x""#] as [String?])
    func copiesStillCountOnce(_ total: String?) async throws {
        let rig = try Rig()
        try rig.grok(session: "a", [Self.turn("totalTokens", total)])
        try rig.grok(session: "b", [Self.turn("totalTokens", total)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155)
        #expect(grok.month.completeness.flawed == (total == "155" ? 0 : 1))
    }

    /// Of two copies with the same key, the one with valid counters wins, whichever file is read first. Before the fix
    /// the copy whose missing output read as 0 ranked first and was counted (105).
    @Test(arguments: [("a", "b"), ("b", "a")])
    func validCopyWinsOverFlawedCopy(_ complete: String, _ flawed: String) async throws {
        let rig = try Rig()
        try rig.grok(session: complete, [Self.turn()])
        try rig.grok(session: flawed, [Self.turn("outputTokens", nil)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155)
        #expect(grok.month.completeness.isComplete)
    }

    /// An invalid reported cost is unknown (R7), never a negative or truncated cost; the tokens still count.
    @Test(arguments: ["-5", "1.5", "1e30"])
    func invalidCostIsUnknown(_ value: String) async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("costUsdTicks", value)])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 155 && grok.month.cost.coverage == .unavailable, "costUsdTicks = \(value)")
    }

    /// When every counter is unusable the turn adds no tokens, but the card still says so: the note reads Grok's
    /// summary as it is, not only when it has tokens (`Store.localGrokUsage` hides a summary without any).
    @MainActor @Test func noteShownWhenGrokHasNoTokens() async throws {
        let rig = try Rig()
        try rig.grok([#""inputTokens":"x","cachedReadTokens":"x","outputTokens":"x","cacheCreationTokens":"x","#
                      + #""modelCalls":"x","totalTokens":"x""#])
        let grok = await rig.summaries().grok
        #expect(grok.month.tokens == 0 && grok.month.completeness == DataCompleteness(flawed: 1))
        let store = Store()
        store.grokUsage = grok
        #expect(store.localGrokUsage == nil)
        #expect(UsageCard.notes(store).map(\.text) == [CompletenessText.incomplete])
    }

    // MARK: Totals and notes

    /// A flawed Grok turn keeps the combined Claude + Grok total qualified.
    @Test func combinedTotalsCarryGrokFlaws() async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("inputTokens", nil)])
        let (claude, grok) = await rig.summaries()
        let combined = try #require(UsageSummary.combine(claude, grok))
        #expect(combined.month.completeness == DataCompleteness(flawed: 1))
    }

    /// The usage card says a Grok total may be incomplete, in Grok's own words.
    @Test func noteCarriesGrokFlaws() async throws {
        let rig = try Rig()
        try rig.grok([Self.turn("inputTokens", nil)])
        let (claude, grok) = await rig.summaries()
        let note = try #require(CompletenessText.note(claude, grok: grok))
        #expect(note.text == CompletenessText.incomplete)
        #expect(note.detail.contains("In Grok's usage files for the last 30 days, 1 turn had a counter that is "
                                     + "missing, isn't a valid number or contradicts another"))
        #expect(!note.detail.contains("Claude Code's logs"))
        #expect(UsageNotes.notes(claude, grok: grok).map(\.text) == [CompletenessText.incomplete])
    }
}

/// The note's copy for Grok, without a ledger: counts only, and Claude's wording unchanged when Grok is complete.
struct GrokCompletenessTextTests {
    private func summary(_ c: DataCompleteness) -> UsageSummary {
        var s = UsageSummary()
        s.month = Totals(tokens: 10, cost: CostEstimate(known: 1, knownTokens: 10), completeness: c)
        return s
    }

    @Test func grokOnly() throws {
        #expect(CompletenessText.note(nil, grok: summary(DataCompleteness())) == nil)
        let two = try #require(CompletenessText.note(nil, grok: summary(DataCompleteness(flawed: 2))))
        #expect(two.detail.contains("2 turns had a counter that is missing, isn't a valid number or contradicts another; "
                                    + "it was left out and the rest counted."))
        #expect(two.detail.contains("token totals may be low"))
    }

    @Test func claudeWordingUnchangedWhenGrokIsComplete() throws {
        let claude = summary(DataCompleteness(flawed: 1))
        let alone = try #require(CompletenessText.note(claude))
        let withGrok = try #require(CompletenessText.note(claude, grok: summary(DataCompleteness())))
        #expect(alone == withGrok)
    }

    @Test func both() throws {
        let note = try #require(CompletenessText.note(summary(DataCompleteness(malformed: 1)),
                                                      grok: summary(DataCompleteness(flawed: 1))))
        #expect(note.detail.contains("In Claude Code's logs for the last 30 days, 1 record couldn't be read"))
        #expect(note.detail.contains("In Grok's usage files for the last 30 days, 1 turn had a counter"))
    }
}
