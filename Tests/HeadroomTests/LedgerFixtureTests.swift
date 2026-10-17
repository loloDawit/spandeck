import Foundation
import Testing
@testable import Headroom

/// #6: accounting fixtures. Each folder under `Fixtures/Ledger` holds synthetic JSONL inputs and a `fixture.json` whose
/// expected values were worked out by hand from the policies in `Fixtures/Ledger/README.md`, never by running the
/// ledger. Every fixture runs three ways: one ledger tailing the changes, one doing a full scan on every refresh, and
/// a new ledger over the saved cache before every step (a relaunch). Separately, the cache is cleared after the last
/// step and the files are indexed again from scratch. The expected result is the same in every mode; a fixture can
/// still give a mode its own `baselineByMode` when today's ledger disagrees with itself (F15 did until #55).
///
/// A fixture's `expect` is the correct result. Where today's ledger differs, `baseline` records what it does instead;
/// the baseline must hold exactly, and the expected result is checked as a known issue naming its follow-up.
/// Time is pinned per fixture (`now`, `timeZone`); nothing sleeps.
struct LedgerFixtureTests {
    // MARK: Fixture format

    struct Fixture: Decodable {
        var title: String
        var classification: String
        var followUp: String?
        var timeZone: String
        var now: String
        var windowStart: String?
        var steps: [Step]
        var rebuild: Rebuild?
    }

    struct Step: Decodable {
        var ops: [Op]
        var expect: Expectation
        var baseline: Expectation?
        var baselineByMode: [String: Expectation]?
    }

    struct Rebuild: Decodable {
        var expect: Expectation
        var baseline: Expectation?
    }

    struct Op: Decodable {
        var op: String
        var path: String
        var from: String?
        var to: String?
    }

    /// Any field left out isn't checked. Token arrays are input, output, 5m write, 1h write, cache read, calls.
    struct Expectation: Decodable {
        var hours: [String: [String: [Int]]]?
        var operations: Int?
        var days: [String: Int]?
        var today: Int?
        var week: Int?
        var month: Int?
        var window: Int?
        var coverage: String?
        var models: [String: String]?
        var knownCost: Double?
        /// How the 30 days' operations were identified (#55).
        var identity: IdentityCoverage?
        /// What couldn't be read (#58). Unlike the other fields it is always checked: left out, it means everything was
        /// read and nothing is pending.
        var completeness: DataCompleteness?
        /// P9 (#58), always checked like `completeness`: UTC hour → model → [tier-unresolved, disputed] cache-write
        /// tokens, for buckets with either; left out, none.
        var tiers: [String: [String: [Int]]]?
        /// Whether the 30 days' token counts are exact (#58), always checked: left out, they are.
        var quantity: QuantityUncertainty?
        /// The P9 minimum for tier-unresolved cache writes, apart from `knownCost`.
        var minimumCost: Double?
    }

    /// What one refresh produced, in the same terms as an expectation.
    struct Observation: Equatable {
        var hours: [String: [String: [Int]]]
        var days: [String: Int]
        var today: Int
        var week: Int
        var month: Int
        var window: Int?
        var coverage: String
        var models: [String: String]
        var knownCost: Double
        var identity: IdentityCoverage
        var completeness: DataCompleteness
        var tiers: [String: [String: [Int]]]
        var quantity: QuantityUncertainty
        var minimumCost: Double

        var operations: Int { hours.values.flatMap(\.values).reduce(0) { $0 + $1[5] } }

        func mismatches(_ e: Expectation) -> [String] {
            var out: [String] = []
            func check<T: Equatable>(_ name: String, _ want: T?, _ got: T) {
                if let want, want != got { out.append("\(name): expected \(want), got \(got)") }
            }
            check("hours", e.hours, hours)
            check("operations", e.operations, operations)
            check("days", e.days, days)
            check("today", e.today, today)
            check("week", e.week, week)
            check("month", e.month, month)
            if let w = e.window, w != window { out.append("window: expected \(w), got \(String(describing: window))") }
            check("coverage", e.coverage, coverage)
            check("models", e.models, models)
            if let c = e.knownCost, abs(c - knownCost) > 1e-12 { out.append("knownCost: expected \(c), got \(knownCost)") }
            check("identity", e.identity, identity)
            check("completeness", e.completeness ?? DataCompleteness(), completeness)
            check("tiers", e.tiers ?? [:], tiers)
            check("quantity", e.quantity ?? QuantityUncertainty(), quantity)
            if let c = e.minimumCost, abs(c - minimumCost) > 1e-12 {
                out.append("minimumCost: expected \(c), got \(minimumCost)")
            }
            return out
        }
    }

    enum Mode: String, CaseIterable, CustomTestStringConvertible {
        case tail, fullScan, relaunch
        var testDescription: String { rawValue }
    }

    // MARK: Loading

    static let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Ledger")
    static let names: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/fixture.json").path) }.sorted()

    static func load(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("\(name)/fixture.json")))
    }

    /// Ledger, clock and files for one run of one fixture.
    private final class Rig {
        let name: String
        let fixture: Fixture
        let box: Sandbox
        let pricing: Pricing
        let clock: TestClock
        let calendar: Calendar
        let window: Date?
        var ledger: Ledger!

        init(_ name: String) throws {
            self.name = name
            fixture = try LedgerFixtureTests.load(name)
            box = try Sandbox()
            pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
            clock = TestClock(try #require(ISO.parse(fixture.now)))
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = try #require(TimeZone(identifier: fixture.timeZone))
            calendar = cal
            window = fixture.windowStart.flatMap(ISO.parse)
            relaunch()
        }

        var projects: URL { box.home.appendingPathComponent(".claude/projects") }

        /// A new ledger over the same home and cache, as after a relaunch.
        func relaunch() {
            let clock = clock, calendar = calendar
            ledger = Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing, now: { clock.now }, calendar: { calendar })
        }

        func apply(_ ops: [Op]) throws {
            let fm = FileManager.default
            for op in ops {
                let dest = projects.appendingPathComponent(op.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                let source = { try Data(contentsOf: LedgerFixtureTests.root.appendingPathComponent("\(self.name)/\(op.from!)")) }
                switch op.op {
                case "write": try source().write(to: dest) // in place, like an editor or a rewrite, not a rename
                case "append":
                    let h = try FileHandle(forWritingTo: dest)
                    try h.seekToEnd()
                    try h.write(contentsOf: source())
                    try h.close()
                case "delete": try fm.removeItem(at: dest)
                case "rename":
                    let to = projects.appendingPathComponent(op.to!)
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: dest, to: to)
                default: Issue.record("unknown op \(op.op)")
                }
            }
            // Real modification times would make "recent" depend on the day the tests run; pin them just before now.
            let stamp = clock.now.addingTimeInterval(-60)
            guard let en = fm.enumerator(at: projects, includingPropertiesForKeys: nil) else { return }
            for case let url as URL in en { try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
        }

        func observe() async -> Observation {
            let ledger = ledger!
            let window = window
            let s = await withCheckedContinuation { c in
                ledger.refresh(windowStart: window, progress: { _ in }, completion: { claude, _, _ in c.resume(returning: claude) })
            }
            let raw = await withCheckedContinuation { c in ledger.claudeHourlyUsage { c.resume(returning: $0) } }

            let hourFormat = DateFormatter()
            hourFormat.locale = Locale(identifier: "en_US_POSIX")
            hourFormat.timeZone = TimeZone(identifier: "UTC")
            hourFormat.dateFormat = "yyyy-MM-dd'T'HH"
            let dayFormat = DateFormatter()
            dayFormat.locale = Locale(identifier: "en_US_POSIX")
            dayFormat.calendar = calendar
            dayFormat.timeZone = calendar.timeZone
            dayFormat.dateFormat = "yyyy-MM-dd"

            var hours: [String: [String: [Int]]] = [:], tiers: [String: [String: [Int]]] = [:]
            for (hour, models) in raw {
                let key = hourFormat.string(from: Date(timeIntervalSince1970: Double(hour) * 3600))
                for (model, a) in models {
                    hours[key, default: [:]][model] = [a.input, a.output, a.cacheWrite5m, a.cacheWrite1h, a.cacheRead, a.calls]
                    if a.unresolved != 0 || a.disputed != 0 { tiers[key, default: [:]][model] = [a.unresolved, a.disputed] }
                }
            }
            var days: [String: Int] = [:]
            for bar in s.bars { days[dayFormat.string(from: bar.day), default: 0] += bar.tokens }
            func name(_ c: CostEstimate.Coverage) -> String {
                switch c { case .complete: "complete"; case .partial: "partial"; case .unavailable: "unavailable" }
            }
            return Observation(hours: hours, days: days, today: s.today.tokens, week: s.week.tokens, month: s.month.tokens,
                               window: s.window?.tokens, coverage: name(s.month.cost.coverage),
                               models: Dictionary(uniqueKeysWithValues: s.models.map { ($0.model, name($0.cost.coverage)) }),
                               knownCost: s.month.cost.known, identity: s.month.identity,
                               completeness: s.month.completeness, tiers: tiers, quantity: s.month.quantity,
                               minimumCost: s.month.cost.minimum)
        }

        /// Checks the baseline exactly when there is one, and the expected result (as a known issue if there's a
        /// baseline).
        func verify(_ o: Observation, expect: Expectation, baseline: Expectation?, _ label: String) {
            guard let baseline else {
                let diff = o.mismatches(expect)
                #expect(diff.isEmpty, "\(name) \(label): \(diff.joined(separator: "; "))")
                return
            }
            let base = o.mismatches(baseline)
            #expect(base.isEmpty, "\(name) \(label) baseline: \(base.joined(separator: "; "))")
            withKnownIssue("\(name): \(fixture.followUp ?? "policy decision pending") — \(fixture.title)") {
                let diff = o.mismatches(expect)
                #expect(diff.isEmpty, "\(name) \(label): \(diff.joined(separator: "; "))")
            }
        }
    }

    // MARK: Tests

    @Test func everyFixtureIsComplete() throws {
        #expect(Self.names.count == 47)
        for name in Self.names {
            let f = try Self.load(name)
            #expect(["pass", "defect", "ambiguous"].contains(f.classification), "\(name)")
            #expect(!f.steps.isEmpty, "\(name)")
            let differs = f.steps.contains { $0.baseline != nil || $0.baselineByMode != nil } || f.rebuild?.baseline != nil
            // A known failure always names where it's tracked; a passing fixture has no baseline.
            if f.classification == "defect" { #expect(differs && f.followUp?.hasPrefix("#") == true, "\(name)") }
            if f.classification == "pass" { #expect(!differs, "\(name)") }
        }
    }

    /// Fresh indexing and incremental refresh: every step, in every mode, matches the fixture; a second refresh with
    /// nothing new changes nothing.
    @Test(arguments: names, Mode.allCases)
    func fixture(_ name: String, _ mode: Mode) async throws {
        let rig = try Rig(name)
        for (i, step) in rig.fixture.steps.enumerated() {
            try rig.apply(step.ops)
            if i > 0 {
                switch mode {
                case .tail: break
                case .fullScan: rig.clock.advance(301) // past the 5-minute full-scan interval
                case .relaunch: rig.ledger.flush(); rig.relaunch()
                }
            }
            let o = await rig.observe()
            rig.verify(o, expect: step.expect, baseline: step.baselineByMode?[mode.rawValue] ?? step.baseline,
                       "step \(i + 1) \(mode.rawValue)")
            #expect(await rig.observe() == o, "\(name) step \(i + 1) \(mode.rawValue): a refresh with no changes moved totals")
        }
    }

    /// Clearing the cache and indexing the final files from scratch. Unless a fixture says otherwise this equals its
    /// last step: re-reading must neither inflate nor lose anything still on disk.
    @Test(arguments: names)
    func rebuild(_ name: String) async throws {
        let rig = try Rig(name)
        for step in rig.fixture.steps {
            try rig.apply(step.ops)
            _ = await rig.observe()
        }
        let ledger = rig.ledger!
        let cleared = await withCheckedContinuation { c in ledger.clearCache { c.resume(returning: $0) } }
        #expect(cleared == nil)
        let last = rig.fixture.steps.last!
        let expect = rig.fixture.rebuild?.expect ?? last.expect
        let baseline = rig.fixture.rebuild.map(\.baseline) ?? last.baseline
        rig.verify(await rig.observe(), expect: expect, baseline: baseline, "rebuild")
    }

    /// A crash after counting new records but before saving them: the next launch starts from the older cache and
    /// must reach the same totals, not count the unsaved records twice. F40 does the same for unread records (#58).
    @Test(arguments: ["F01-streaming-growth", "F40-unread-appended"])
    func unsavedProgressIsNotCountedTwice(_ name: String) async throws {
        let rig = try Rig(name)
        try rig.apply(rig.fixture.steps[0].ops)
        _ = await rig.observe() // the first refresh saves
        for step in rig.fixture.steps.dropFirst() {
            try rig.apply(step.ops)
            _ = await rig.observe() // not saved: under 10 minutes since the last save
        }
        rig.relaunch() // no flush
        let o = await rig.observe()
        rig.verify(o, expect: rig.fixture.steps.last!.expect, baseline: nil, "after crash")
        rig.ledger.flush()
        rig.relaunch()
        #expect(await rig.observe() == o)
    }
}
