import Foundation
import Testing
@testable import Headroom

/// #57: usage belongs to the local day of its own timestamp in every zone in use, including ones whose offset isn't a
/// whole number of hours. Days come from the stored UTC times at summary time, so a change of time zone needs no
/// cached day assignment to be updated. F21, F46 and F47 cover days, the 7 and 30 days, streaming, #55 joins and P9
/// in fixtures; these tests cover a change of zone and Grok.
struct TimeZoneTests {
    /// The zone a ledger sees, changeable while it runs, like the system's.
    private final class Zone: @unchecked Sendable {
        private let lock = NSLock()
        private var id: String
        init(_ id: String) { self.id = id }
        func set(_ id: String) { lock.withLock { self.id = id } }
        var calendar: Calendar {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: lock.withLock { id })!
            return c
        }
    }

    private static func line(_ n: String, _ ts: String, input: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req_\#(n)","message":{"id":"msg_\#(n)","model":"claude-test-1","usage":{"input_tokens":\#(input),"output_tokens":0}}}"#
    }

    private static func ledger(_ box: Sandbox, now: Date, zone: Zone) -> Ledger {
        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        pricing.load()
        return Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing, now: { now }, calendar: { zone.calendar })
    }

    private static func days(_ s: UsageSummary, _ zone: Zone) -> [String: Int] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone.calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        var out: [String: Int] = [:]
        for b in s.bars { out[f.string(from: b.day), default: 0] += b.tokens }
        return out
    }

    /// The zone changes while the app runs, between two zones that share today's midnight (UTC and London after
    /// summer time ends) but not an earlier one: the days are worked out again, not reused from before.
    @Test func zoneChangeWhileRunning() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/-p/s1.jsonl", [Self.line("a", "2026-10-20T23:30:00Z", input: 5),
                                                     Self.line("b", "2026-10-30T10:00:00Z", input: 1)].joined(separator: "\n") + "\n")
        let now = try #require(ISO.parse("2026-10-30T12:00:00Z"))
        let zone = Zone("UTC")
        let ledger = Self.ledger(box, now: now, zone: zone)
        let utc = await refreshLedger(ledger).claude
        #expect(Self.days(utc, zone) == ["2026-10-20": 5, "2026-10-30": 1] && utc.today.tokens == 1)

        zone.set("Europe/London") // 23:30Z Oct 20 was 00:30 BST Oct 21
        let london = await refreshLedger(ledger).claude
        #expect(Self.days(london, zone) == ["2026-10-21": 5, "2026-10-30": 1] && london.today.tokens == 1)
    }

    /// The zone changes between launches: the saved cache holds UTC times, so the new zone's days are exact too.
    @Test func zoneChangeAcrossRelaunch() async throws {
        let box = try Sandbox()
        // 18:20Z Mar 9 is 23:50 IST Mar 9 but 00:05 NPT Mar 10; 18:10Z is Mar 9 in both.
        try box.write(".claude/projects/-p/s1.jsonl", [Self.line("a", "2026-03-09T18:20:00Z", input: 2),
                                                     Self.line("b", "2026-03-09T18:10:00Z", input: 1)].joined(separator: "\n") + "\n")
        let now = try #require(ISO.parse("2026-03-10T06:00:00Z"))
        let kolkata = Zone("Asia/Kolkata")
        let first = Self.ledger(box, now: now, zone: kolkata)
        let k = await refreshLedger(first).claude
        #expect(Self.days(k, kolkata) == ["2026-03-09": 3] && k.today.tokens == 0)
        first.flush()

        let kathmandu = Zone("Asia/Kathmandu")
        let n = await refreshLedger(Self.ledger(box, now: now, zone: kathmandu)).claude
        #expect(Self.days(n, kathmandu) == ["2026-03-09": 1, "2026-03-10": 2] && n.today.tokens == 2 && n.month.tokens == 3)
    }

    /// Grok turns are bucketed like Claude records, so their days are exact in a half-hour zone too.
    @Test func grokInHalfHourZone() async throws {
        let box = try Sandbox()
        let at = { (s: String) in ISO.parse(s)! }
        // 18:40Z Mar 9 = 00:10 IST Mar 10; 18:20Z = 23:50 IST Mar 9. Each turn is 150 tokens.
        try box.writeGrokUsage(session: "s", turns: [(at("2026-03-09T18:40:00Z"), 1, "grok-test"),
                                                     (at("2026-03-09T18:20:00Z"), 1, "grok-test")])
        let zone = Zone("Asia/Kolkata")
        let g = await refreshLedger(Self.ledger(box, now: at("2026-03-10T06:00:00Z"), zone: zone)).grok
        #expect(Self.days(g, zone) == ["2026-03-09": 150, "2026-03-10": 150] && g.today.tokens == 150)
    }
}
