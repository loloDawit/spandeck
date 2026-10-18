import Foundation
import Testing
@testable import Headroom

/// Metric contract F-2 (#4, #7): a quota percent that is missing, null, not a number, a boolean, not finite or outside
/// 0–100 is *unavailable*, never 0 %. A reported 0 stays an exact 0. The limit is kept with its reset time, window and
/// name; nothing is derived from tokens or costs, and no extra request is made. All fixtures are synthetic: canary
/// credentials and fake transports, never a real endpoint.
@MainActor
struct QuotaPercentTests {
    /// Percent values that aren't a usable percent. JSON can't spell NaN or infinity; 1e300 is finite but out of range
    /// (and would trap `Int(_:)`).
    nonisolated static let unusable: [String?] = [nil, "null", #""42""#, "true", "false", "-1", "-0.5", "100.5", "150",
                                                  "1e300", "{}", "[42]"]

    private static func claude(_ body: String) async throws -> ClaudeLimits {
        let client = ClaudeLimitsClient(credentials: FakeCredentialStore(FakeCredentialStore.synthetic()),
                                        transport: FakeTransport([Hosts.anthropic: [.json(body)]]))
        return try await client.fetch()
    }

    /// `"key":value` as a JSON member, or nothing when `value` is nil.
    private static func member(_ key: String, _ value: String?) -> String {
        value.map { #","\#(key)":\#($0)"# } ?? ""
    }

    private static let resets = "2030-01-01T00:00:00Z"

    // MARK: Claude, `limits` shape

    @Test(arguments: unusable)
    func claudeLimitPercentUnavailable(_ value: String?) async throws {
        let body = #"{"limits":[{"kind":"session","resets_at":"\#(Self.resets)""# + Self.member("percent", value)
            + #"},{"kind":"weekly_all","percent":30,"resets_at":"\#(Self.resets)"}]}"#
        let l = try await Self.claude(body)
        let session = try #require(l.session, "\(value ?? "absent")")
        #expect(session.percent == nil, "\(value ?? "absent")")
        // Everything else about the limit is kept.
        #expect(session.name == "Session (5h)" && session.window == 5 * 3600 && session.resetsAt == ISO.parse(Self.resets))
        #expect(l.all.count == 2 && l.weekly?.percent == 30)
    }

    @Test(arguments: [("0", 0.0), ("0.0", 0.0), ("100", 100.0), ("42.5", 42.5)])
    func claudeLimitPercentReported(_ value: String, _ expected: Double) async throws {
        let l = try await Self.claude(#"{"limits":[{"kind":"session","percent":\#(value)}]}"#)
        #expect(l.session?.percent == expected)
    }

    /// A model-scoped limit without a percent keeps its scope name, window and reset time.
    @Test func claudeScopedLimitKeepsItsFields() async throws {
        let l = try await Self.claude(#"{"limits":[{"kind":"weekly_scoped","resets_at":"\#(Self.resets)","#
                                      + #""scope":{"model":{"display_name":"Example"}}}]}"#)
        let model = try #require(l.model)
        #expect(model.percent == nil && model.name == "Weekly Example" && model.window == 7 * 86400)
        #expect(model.resetsAt == ISO.parse(Self.resets))
    }

    /// The weekly-share note needs both of its percents, and only attaches to the limit it names. Before the fix a
    /// share without `limit_index` was read as index 0, and a huge share value would trap.
    @Test func claudeShareNote() async throws {
        func note(_ share: String) async throws -> String? {
            try await Self.claude(#"{"limits":[{"kind":"weekly_scoped","percent":5}],"weekly_scoped_shares":[\#(share)]}"#)
                .model?.note
        }
        #expect(try await note(#"{"limit_index":0,"used_percent_of_weekly":12,"allowance_percent_of_weekly":40}"#)
                == "12% of weekly used, 40% allowed")
        #expect(try await note(#"{"limit_index":0,"used_percent_of_weekly":0,"allowance_percent_of_weekly":0}"#)
                == "0% of weekly used, 0% allowed")
        #expect(try await note(#"{"used_percent_of_weekly":12,"allowance_percent_of_weekly":40}"#) == nil)
        for bad in ["null", #""12""#, "true", "-1", "1e300"] {
            #expect(try await note(#"{"limit_index":0,"used_percent_of_weekly":\#(bad),"allowance_percent_of_weekly":40}"#)
                    == nil, "\(bad)")
        }
    }

    // MARK: Claude, older `five_hour` / `seven_day` shape

    @Test(arguments: unusable)
    func claudeUtilizationUnavailable(_ value: String?) async throws {
        let l = try await Self.claude(#"{"five_hour":{"resets_at":"\#(Self.resets)""# + Self.member("utilization", value)
                                      + #"},"seven_day":{"resets_at":"\#(Self.resets)""# + Self.member("utilization", value) + "}}")
        #expect(l.session?.percent == nil && l.weekly?.percent == nil, "\(value ?? "absent")")
        #expect(l.session?.resetsAt == ISO.parse(Self.resets) && l.weekly?.resetsAt == ISO.parse(Self.resets))
        #expect(l.all.map(\.id) == ["five_hour", "seven_day"])
    }

    @Test func claudeUtilizationZeroIsExact() async throws {
        let l = try await Self.claude(#"{"five_hour":{"utilization":0},"seven_day":{"utilization":0.0}}"#)
        #expect(l.session?.percent == 0 && l.weekly?.percent == 0)
    }

    // MARK: Grok

    private struct GrokRig {
        let box: Sandbox
        let services: ProviderServices

        @MainActor init(_ body: String) throws {
            box = try Sandbox()
            try box.installGrok()
            services = ProviderServices(store: Store(), env: box.environment(
                transport: FakeTransport([Hosts.grok: [.json(body)]]), grokCredentials: CountingGrokAuth(home: box.home)))
            services.setGrokEnabled(true)
        }
    }

    /// A product's missing or unusable percent is unavailable; the product, the plan and its top-level percent stay.
    @Test(arguments: unusable)
    func grokProductPercentUnavailable(_ value: String?) async throws {
        let rig = try GrokRig(#"{"config":{"creditUsagePercent":10,"productUsage":[{"product":"A""#
                              + Self.member("usagePercent", value) + #"},{"product":"B","usagePercent":0}]}}"#)
        await rig.services.refreshGrok()
        let plan = try #require(rig.services.store.grokPlan, "\(value ?? "absent")")
        #expect(plan.percent == 10 && plan.products.map(\.name) == ["A", "B"])
        #expect(plan.products[0].percent == nil, "\(value ?? "absent")")
        #expect(plan.products[1].percent == 0) // a reported 0 stays exact
        #expect(LimitText.products(plan) == "A --  B 0%")
        #expect(StatusRenderer.grokGauge(rig.services.store) == [10])
    }

    /// The top-level percent was already strict for missing values (#21); out of range is malformed too.
    @Test(arguments: ["-1", "100.5", "1e300"])
    func grokTopLevelOutOfRangeIsMalformed(_ value: String) async throws {
        let rig = try GrokRig(#"{"config":{"creditUsagePercent":\#(value)}}"#)
        await rig.services.refreshGrok()
        #expect(rig.services.store.grokFailure == .unexpectedResponse && rig.services.store.grokPlan == nil)
    }

    @Test(arguments: [("0", 0.0), ("100", 100.0)])
    func grokTopLevelBounds(_ value: String, _ expected: Double) async throws {
        let rig = try GrokRig(#"{"config":{"creditUsagePercent":\#(value)}}"#)
        await rig.services.refreshGrok()
        #expect(rig.services.store.grokFailure == nil && rig.services.store.grokPlan?.percent == expected)
    }

    // MARK: What the UI shows

    private struct ClaudeRig {
        let box: Sandbox
        let transport: FakeTransport
        let services: ProviderServices

        @MainActor init(_ body: String) throws {
            box = try Sandbox()
            box.preferences.set(true, forKey: Prefs.claudeLimits)
            transport = FakeTransport([Hosts.anthropic: [.json(body)]])
            services = ProviderServices(store: Store(), env: box.environment(
                transport: transport, credentials: FakeCredentialStore(FakeCredentialStore.synthetic())))
        }
    }

    /// An unavailable percent is a blank gauge segment and "--" with a reason, not an empty bar at 0 %. The account
    /// still counts as available, there's no error, and only the one request is made.
    @Test func claudeUnavailablePercentIsShownAsUnavailable() async throws {
        let rig = try ClaudeRig(#"{"limits":[{"kind":"session","resets_at":"\#(Self.resets)"},"#
                                + #"{"kind":"weekly_all","percent":0}]}"#)
        await rig.services.refreshClaude()
        let store = rig.services.store
        #expect(store.claudeAvailable && store.claudeError == nil)
        #expect(StatusRenderer.claudeGauge(store) == [nil, 0, nil])
        let session = try #require(store.claudeLimits?.session), weekly = try #require(store.claudeLimits?.weekly)
        #expect(Fmt.pct(session.percent) == "--" && LimitText.note(session) == LimitText.unavailable)
        #expect(Fmt.pct(weekly.percent) == "0%" && LimitText.note(weekly) == nil)
        #expect(rig.transport.requests.count == 1)
    }

    /// The reason is added to a note the limit already has, not put in its place.
    @Test func unavailableReasonKeepsTheNote() {
        let e = LimitEntry(id: "x", name: "Weekly Example", percent: nil, resetsAt: nil, note: "12% of weekly used, 40% allowed")
        #expect(LimitText.note(e) == LimitText.unavailable + " · 12% of weekly used, 40% allowed")
        #expect(LimitText.note(LimitEntry(id: "y", name: "W", percent: 3, resetsAt: nil, note: "n")) == "n")
    }
}
