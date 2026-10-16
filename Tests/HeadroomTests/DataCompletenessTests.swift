import Foundation
import Testing
@testable import Headroom

/// #58: what the ledger couldn't read is carried with every total, separately from identity (#55) and cost coverage
/// (R7), and the usage card says when a total may be incomplete. The notes are checked through `CompletenessText` and
/// `UsageNotes`, the copy the card shows; the SwiftUI view itself isn't rendered here.
struct DataCompletenessTests {
    private func summary(_ c: DataCompleteness, identity: IdentityCoverage = IdentityCoverage(identified: 1),
                         cost: CostEstimate = CostEstimate(known: 1, knownTokens: 10)) -> UsageSummary {
        var s = UsageSummary()
        s.month = Totals(tokens: 10, cost: cost, identity: identity, completeness: c)
        return s
    }

    // MARK: Reading

    /// P8: a counter is a non-negative integral number below 2^53. Absent and null report nothing; anything else is
    /// invalid, never read as 0 or as some other number.
    @Test func counterValues() {
        let valid: [(Any?, Int)] = [(0, 0), (7, 7), (100.0, 100), (5e1, 50), (NSNumber(value: Int64(1) << 52), 1 << 52),
                                    (-0.0, 0)]
        for (v, n) in valid { #expect(Ledger.counter(v) == .value(n), "\(String(describing: v))") }
        for v: Any? in [nil, NSNull()] { #expect(Ledger.counter(v) == .absent) }
        let invalid: [Any] = [-1, -0.5, 1.5, "100", "", true, false, 1e30, Double.infinity, Double.nan,
                              NSNumber(value: Int64(1) << 53), NSDecimalNumber(string: "1e40"), ["n": 1], [2]]
        for v in invalid { #expect(Ledger.counter(v) == .invalid, "\(v)") }
    }

    /// The pre-filter finds a `"usage"` key whatever JSON whitespace surrounds its colon, and never matches the escaped
    /// `\"usage\"` inside text or `"usage"` as a value.
    @Test func usageKeyFilter() {
        func has(_ s: String) -> Bool { Data(s.utf8).withUnsafeBytes { Ledger.hasUsageKey($0) } }
        for s in [#"{"usage":{"a":1}}"#, #"{"usage": {}}"#, #"{"usage" :{}}"#, "{\"usage\"\t:\t{}}", "{\"usage\"\r:{}}",
                  #"{"usage":null}"#, #"{"usage":"n/a"}"#, #"{"kind":"usage","usage":{}}"#, #"{"usage":"#] {
            #expect(has(s), "\(s)")
        }
        for s in [#"{"text":"see \"usage\": {\"a\":1}"}"#, #"{"kind":"usage"}"#, #"{"usages":{}}"#, #"{"usage"}"#,
                  #"{"my_usage":{}}"#, "", #""usage""#, #"{"usage" x:{}}"#] {
            #expect(!has(s), "\(s)")
        }
    }

    // MARK: The note

    @Test func noteOnlyWhenSomethingWasNotRead() throws {
        #expect(CompletenessText.note(nil) == nil)
        #expect(CompletenessText.note(summary(DataCompleteness())) == nil)
        #expect(CompletenessText.note(summary(DataCompleteness(pending: 2))) == nil) // still being written: not a warning
        for c in [DataCompleteness(flawed: 1), DataCompleteness(invalidUsage: 1), DataCompleteness(undated: 1),
                  DataCompleteness(malformed: 1)] {
            let note = try #require(CompletenessText.note(summary(c)))
            #expect(note.text == "Some usage records couldn't be read. Totals may be incomplete.")
            #expect(note.detail.hasPrefix("In Claude Code's logs for the last 30 days"))
            #expect(note.detail.contains("not your bill"))
        }
        let all = try #require(CompletenessText.note(summary(DataCompleteness(flawed: 2, invalidUsage: 1, undated: 3,
                                                                                malformed: 4))))
        #expect(all.detail.contains("8 records couldn't be read: 4 aren't valid JSON, 3 have no usable timestamp, 1 has usage in a form SpanDeck doesn't recognize."))
        #expect(all.detail.contains("2 messages had a token count that isn't a valid number"))
        #expect(all.detail.contains("7 of the unread records have no date, so they may belong to any period"))
        let one = try #require(CompletenessText.note(summary(DataCompleteness(invalidUsage: 1))))
        #expect(one.detail.contains("1 record couldn't be read: 1 has usage in a form") && !one.detail.contains("any period"))
        let flawed = try #require(CompletenessText.note(summary(DataCompleteness(flawed: 1))))
        #expect(flawed.detail.contains("1 message had a token count") && !flawed.detail.contains("couldn't be read:"))
    }

    /// Completeness, identity and cost are three questions; no note stands in for another.
    @Test func independentOfIdentityAndCost() {
        let unread = summary(DataCompleteness(malformed: 1))
        #expect(CompletenessText.note(unread) != nil && IdentityText.note(unread) == nil)
        #expect(PricingText.coverageNote(claude: unread, grok: nil) == nil)

        let approximate = summary(DataCompleteness(), identity: IdentityCoverage(fingerprinted: 1))
        #expect(CompletenessText.note(approximate) == nil && IdentityText.note(approximate) != nil)

        var unpriced = summary(DataCompleteness(), cost: CostEstimate(unknownTokens: 10))
        unpriced.models = [ModelRow(model: "claude-new", tokens: 10, cost: CostEstimate(unknownTokens: 10))]
        #expect(CompletenessText.note(unpriced) == nil && PricingText.coverageNote(claude: unpriced, grok: nil) != nil)
    }

    /// The card shows the notes that apply as one short list: what couldn't be read first, then identity.
    @Test func notesCompose() {
        #expect(UsageNotes.notes(nil).isEmpty)
        #expect(UsageNotes.notes(summary(DataCompleteness())).isEmpty)
        let both = UsageNotes.notes(summary(DataCompleteness(undated: 1), identity: IdentityCoverage(incomplete: 1)))
        #expect(both.map(\.text) == [CompletenessText.incomplete, IdentityText.approximate])
        #expect(UsageNotes.notes(summary(DataCompleteness(undated: 1))).map(\.text) == [CompletenessText.incomplete])
    }

    /// Combining with Grok keeps Claude's counts; an unread Claude record says nothing about Grok.
    @Test func combineKeepsClaudeCompleteness() throws {
        let claude = summary(DataCompleteness(flawed: 1, malformed: 2))
        let combined = try #require(UsageSummary.combine(claude, summary(DataCompleteness())))
        #expect(combined.month.completeness == DataCompleteness(flawed: 1, malformed: 2))
        #expect(DataCompleteness(flawed: 1, pending: 1) + DataCompleteness(invalidUsage: 2, undated: 1)
                == DataCompleteness(flawed: 1, invalidUsage: 2, undated: 1, pending: 1))
        #expect(DataCompleteness(undated: 1, pending: 3).isComplete == false)
        #expect(DataCompleteness(pending: 3).isComplete && DataCompleteness(flawed: 1, invalidUsage: 1, undated: 1, malformed: 1).unread == 3)
    }

    /// Counters are validated below 2^53, but enough valid ones in one hour still exceed `Int`: sums saturate instead
    /// of trapping, so a crafted transcript can't crash the app (it did before #58, with 1e30).
    @Test func hugeCountersSaturate() async throws {
        #expect(Int.max.saturatingAdd(1) == .max && Int.min.saturatingAdd(-1) == .min && 2.saturatingAdd(-3) == -1)
        let big = (1 << 53) - 1
        var a = Agg(input: big, output: big, calls: 1)
        for _ in 0..<1100 { a.add(Agg(input: big, output: big, calls: 1)) }
        #expect(a.input == .max && a.total == .max && a.calls == 1101)

        let box = try Sandbox()
        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        let ts = ISO8601DateFormatter().string(from: Date())
        try box.write(".claude/projects/-p/s1.jsonl", (0..<1100).map {
            Self.assistant($0, timestamp: ts, usage: #"{"input_tokens":\#(big),"output_tokens":\#(big)}"#)
        }.joined(separator: "\n") + "\n")
        let s = await refreshLedger(Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing)).claude
        #expect(s.month.tokens == .max && s.month.completeness == DataCompleteness())
    }

    // MARK: Periods and retention

    private static func assistant(_ n: Int, timestamp: String, usage: String) -> String {
        #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"req_\#(n)","message":{"id":"msg_\#(n)","model":"claude-test-1","usage":\#(usage)}}"#
    }

    /// A record with a timestamp is reported in its own periods; one without is reported with every period, since it
    /// could belong to any of them, and never given an invented day.
    @Test func unreadPeriods() async throws {
        let box = try Sandbox()
        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        let f = ISO8601DateFormatter()
        let now = Date()
        try box.write(".claude/projects/-p/s1.jsonl", [
            Self.assistant(1, timestamp: f.string(from: now), usage: #""n/a""#),
            Self.assistant(2, timestamp: f.string(from: now.addingTimeInterval(-10 * 86400)), usage: "[1]"),
            Self.assistant(3, timestamp: f.string(from: now.addingTimeInterval(-10 * 86400)),
                           usage: #"{"input_tokens":5,"output_tokens":-1}"#),
            Self.assistant(4, timestamp: "", usage: #"{"input_tokens":5}"#),
        ].joined(separator: "\n") + "\n")
        let s = await refreshLedger(Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing)).claude
        #expect(s.today.completeness == DataCompleteness(invalidUsage: 1, undated: 1))
        #expect(s.week.completeness == DataCompleteness(invalidUsage: 1, undated: 1))
        #expect(s.month.completeness == DataCompleteness(flawed: 1, invalidUsage: 2, undated: 1))
        #expect(s.month.tokens == 5 && s.today.tokens == 0)
    }

    /// P16: unread records and flaws are dropped with their hour after 32 days; an undated record 32 days after it was
    /// found. Nothing is reported for usage the ledger no longer covers.
    @Test func unreadRecordsAgeOut() async throws {
        let box = try Sandbox()
        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        let clock = TestClock()
        let f = ISO8601DateFormatter()
        try box.write(".claude/projects/-p/s1.jsonl", [
            Self.assistant(1, timestamp: f.string(from: clock.now), usage: #""n/a""#),
            Self.assistant(2, timestamp: "never", usage: #"{"input_tokens":5}"#),
            Self.assistant(3, timestamp: f.string(from: clock.now), usage: #"{"input_tokens":5,"output_tokens":"x"}"#),
            #"{"type":"assistant","usage":{"#,
        ].joined(separator: "\n") + "\n")
        let ledger = Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing, now: { clock.now })
        #expect(await refreshLedger(ledger).claude.month.completeness
                == DataCompleteness(flawed: 1, invalidUsage: 1, undated: 1, malformed: 1))
        clock.advance(31 * 86400)
        #expect(await refreshLedger(ledger).claude.month.completeness == DataCompleteness(undated: 1, malformed: 1))
        clock.advance(2 * 86400)
        let s = await refreshLedger(ledger).claude
        #expect(s.month.completeness == DataCompleteness() && s.month.tokens == 0)
    }
}
