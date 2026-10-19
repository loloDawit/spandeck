import Foundation
import Testing
@testable import Headroom

/// R5 (#21): Grok failures are classified (`GrokError`), published without hiding Grok once the user opted in, and
/// shown with guidance that fits the failure. R3/R4 guards still apply. All fixtures are synthetic.
@MainActor
struct GrokErrorStateTests {
    private struct Rig {
        let box: Sandbox
        let auth: CountingGrokAuth
        let runner: FakeProcessRunner
        let claude = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services: ProviderServices

        /// Grok installed (canary key, `bin/grok`, one local usage file) and opted in.
        @MainActor init(transport: HTTPTransport, expiresIn: TimeInterval? = nil, install: Bool = true,
                        runner: FakeProcessRunner = FakeProcessRunner()) throws {
            box = try Sandbox()
            self.runner = runner
            if install { try box.installGrok(expiresIn: expiresIn) }
            auth = CountingGrokAuth(home: box.home)
            services = ProviderServices(store: Store(), env: box.environment(
                transport: transport, runner: runner, credentials: claude, grokCredentials: auth))
            services.setGrokEnabled(true)
        }

        var store: Store { services.store }
        @MainActor var section: GrokSection? { GrokSection.select(store) }
        func removeCLI() throws { try FileManager.default.removeItem(at: box.home.appendingPathComponent(".grok/bin/grok")) }
    }

    // MARK: Credentials

    @Test func missingCredentialsIsNotConfigured() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport, install: false)

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .notConfigured)
        #expect(rig.section == .failure(.notConfigured))
        #expect(transport.requests.isEmpty && rig.runner.calls.isEmpty)
    }

    @Test(arguments: ["{not json", #"{"default":{"key":""}}"#, #"{"default":{"token":"CANARY-GROK-KEY"}}"#, "[]"])
    func unusableCredentialsAreInvalid(_ contents: String) async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport)
        try rig.box.write(".grok/auth.json", contents)

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .invalidCredentials)
        #expect(rig.section == .failure(.invalidCredentials))
        #expect(transport.requests.isEmpty && rig.runner.calls.isEmpty)
    }

    // MARK: Expired key and `grok models`

    @Test func expiredKeyRefreshedThenAccepted() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport, expiresIn: -3600)

        await rig.services.refreshGrok()

        #expect(rig.runner.calls.map(\.args) == [["models"]])
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil)
        #expect(rig.section == .plan(.init(staleBecause: nil)))
    }

    /// Non-zero exit (1), or the CLI couldn't be launched (nil). The key is then rejected twice.
    @Test(arguments: [Int32(1), nil])
    func expiredKeyCLIFailsThenRejected(_ status: Int32?) async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport, expiresIn: -3600)
        rig.runner.result = status.map { ($0, Data()) }

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .authRejected(.failed(status: status)))
        #expect(rig.section == .failure(.authRejected(.failed(status: status))))
        #expect(rig.runner.calls.count == 1) // the 401 path is throttled and reports the same outcome
        #expect(transport.requests.count == 2)

        // Within 10 minutes: no further CLI run, and the earlier outcome is still reported.
        await rig.services.refreshGrok()
        #expect(rig.runner.calls.count == 1)
        #expect(rig.store.grokFailure == .authRejected(.failed(status: status)))
    }

    @Test func expiredKeyWithoutCLI() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport, expiresIn: -3600)
        try rig.removeCLI()

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .authRejected(.cliMissing))
        #expect(rig.runner.calls.isEmpty)
        #expect(rig.section == .failure(.authRejected(.cliMissing)))
    }

    // MARK: 401 recovery

    @Test func unauthorizedThenRecovered() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized, .grokBilling]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshGrok()

        #expect(rig.runner.calls.count == 1)
        #expect(transport.requests.count == 2)
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil)
    }

    @Test func unauthorizedTwiceIsAuthRejected() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .authRejected(.succeeded))
        #expect(rig.store.grokPlan == nil && !rig.store.grokAvailable)
        #expect(rig.section == .failure(.authRejected(.succeeded)))
        #expect(transport.requests.count == 2 && rig.runner.calls.count == 1)
    }

    // MARK: HTTP and transport classification

    @Test(arguments: [(402, GrokError.accessDenied(402)), (403, .accessDenied(403)), (404, .endpointUnavailable),
                      (400, .http(400))])
    func accessAndEndpointFailures(_ status: Int, _ expected: GrokError) async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling, .json("{}", status: status)]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshGrok()
        #expect(rig.store.grokPlan != nil)

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == expected)
        #expect(expected != .notConfigured && !expected.isTemporary)
        #expect(rig.store.grokPlan == nil && !rig.store.grokAvailable) // not temporary: no stale plan
        #expect(rig.section == .failure(expected))
        #expect(transport.requests.count == 2 && rig.runner.calls.isEmpty) // no recovery for non-401
    }

    @Test(arguments: [(FakeTransport.Response.json("{}", status: 429), GrokError.rateLimited),
                      (.json("{}", status: 500), .serverError(500)), (.json("{}", status: 503), .serverError(503)),
                      (.timeout, .network)])
    func temporaryFailuresKeepStalePlan(_ response: FakeTransport.Response, _ expected: GrokError) async throws {
        // A plan with a period that hasn't ended: a stale plan is shown only within its period (F-3).
        let billing = FakeTransport.Response.json(#"{"config":{"creditUsagePercent":10,"#
                                                  + #""currentPeriod":{"end":"2099-01-01T00:00:00Z"}}}"#)
        let transport = FakeTransport([Hosts.grok: [billing, response]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshGrok()
        let fetchedAt = try #require(rig.store.grokPlan?.fetchedAt)
        #expect(StatusRenderer.grokGauge(rig.store) == [10])

        await rig.services.refreshGrok()

        #expect(StatusRenderer.grokGauge(rig.store) == [nil]) // the stale plan isn't drawn as current
        #expect(rig.store.grokFailure == expected && expected.isTemporary)
        #expect(rig.store.grokPlan?.fetchedAt == fetchedAt) // the old plan, not a new one
        #expect(rig.section == .plan(.init(staleBecause: expected)))
        #expect(rig.runner.calls.isEmpty && transport.requests.count == 2)
    }

    @Test(arguments: [FakeTransport.Response.json("{}", status: 500), .timeout])
    func temporaryFailureWithoutPlanIsShown(_ response: FakeTransport.Response) async throws {
        let rig = try Rig(transport: FakeTransport([Hosts.grok: [response]]))

        await rig.services.refreshGrok()

        let failure = try #require(rig.store.grokFailure)
        #expect(failure.isTemporary)
        #expect(rig.section == .failure(failure))
    }

    @Test(arguments: ["not json", "{}", #"{"config":"x"}"#, #"{"config":{}}"#,
                      #"{"config":{"creditUsagePercent":"not-a-number"}}"#, #"{"config":{"creditUsagePercent":null}}"#,
                      #"{"config":{"creditUsagePercent":true}}"#])
    func malformedBillingResponse(_ body: String) async throws {
        let rig = try Rig(transport: FakeTransport([Hosts.grok: [.json(body)]]))

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == .unexpectedResponse)
        #expect(rig.store.grokPlan == nil)
        #expect(rig.section == .failure(.unexpectedResponse))
    }

    /// A real 0 is a valid plan, not a malformed answer; other metadata stays optional.
    @Test(arguments: [#"{"config":{"creditUsagePercent":0}}"#, #"{"config":{"creditUsagePercent":0.0}}"#])
    func zeroUsageIsValid(_ body: String) async throws {
        let rig = try Rig(transport: FakeTransport([Hosts.grok: [.json(body)]]))

        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == nil && rig.store.grokPlan?.percent == 0 && rig.store.grokAvailable)
        #expect(rig.section == .plan(.init(staleBecause: nil)))
    }

    /// Two overlapping refreshes (e.g. timer and wake): the newer one succeeds first, then the older one answers.
    /// The older answer, failure or success, must not replace the newer plan.
    @Test(arguments: [FakeTransport.Response.json("{}", status: 403), .json("{}", status: 500),
                      .json(#"{"config":{"creditUsagePercent":55}}"#)])
    func olderRefreshCannotOverrideNewer(_ older: FakeTransport.Response) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let first = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: first) else { Issue.record("first refresh never started a request"); return }
        let second = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: second) else { Issue.record("second refresh never started a request"); return }
        #expect(transport.respond(.grokBilling, newest: true))
        #expect(await transport.join(second))
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil)
        #expect(transport.respond(older))
        #expect(await transport.join(first))

        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil && rig.store.grokAvailable)
        #expect(rig.section == .plan(.init(staleBecause: nil)))
        #expect(transport.started == 2 && rig.runner.calls.isEmpty)
    }

    /// In order, the newer answer still wins: a later failure is published as usual.
    @Test func newerFailureAfterOlderSuccessIsShown() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let first = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: first) else { Issue.record("first refresh never started a request"); return }
        let second = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: second) else { Issue.record("second refresh never started a request"); return }
        #expect(transport.respond(.grokBilling))
        #expect(await transport.join(first))
        #expect(transport.respond(.json("{}", status: 403)))
        #expect(await transport.join(second))

        #expect(rig.store.grokFailure == .accessDenied(403) && rig.store.grokPlan == nil)
    }

    @Test func successClearsEarlierFailure() async throws {
        let rig = try Rig(transport: FakeTransport([Hosts.grok: [.json("{}", status: 500), .grokBilling]]))

        await rig.services.refreshGrok()
        #expect(rig.store.grokFailure == .serverError(500))
        await rig.services.refreshGrok()

        #expect(rig.store.grokFailure == nil && rig.store.grokPlan?.percent == 10)
        #expect(rig.section == .plan(.init(staleBecause: nil)))
    }

    // MARK: R3 / R4 guards still apply to failures

    @Test(arguments: [false, true])
    func offOrPausedPublishesNoFailure(paused: Bool) async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport)
        try rig.box.write(".grok/auth.json", "{not json")
        if paused {
            rig.box.preferences.set(false, forKey: Prefs.showGrok)
            rig.services.recordQuotaShown(.grok, false)
        } else {
            rig.services.setGrokEnabled(false)
        }

        await rig.services.refreshGrok()

        #expect(rig.auth.reads == 0 && transport.requests.isEmpty && rig.runner.calls.isEmpty)
        #expect(rig.store.grokFailure == nil)
        #expect(rig.section == (paused ? .paused : nil))
    }

    /// Consent withdrawn or gauge hidden while the first request is pending; it then answers 401.
    @Test(arguments: [false, true])
    func withdrawnDuringRefreshPublishesNoFailure(hide: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        let reads = rig.auth.reads
        if hide {
            rig.box.preferences.set(false, forKey: Prefs.showGrok)
            rig.services.recordQuotaShown(.grok, false)
        } else {
            rig.services.setGrokEnabled(false)
        }
        transport.respond(.unauthorized)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.grokFailure == nil && rig.store.grokPlan == nil)
        #expect(rig.runner.calls.isEmpty && rig.auth.reads == reads && transport.started == 1)
    }

    /// Withdrawn while `grok models` runs in the 401 recovery path: no key re-read, retry or failure afterwards.
    @Test(arguments: [false, true])
    func withdrawnDuringRecoveryStops(hide: Bool) async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let runner = FakeProcessRunner(pausing: true)
        let rig = try Rig(transport: transport, runner: runner)

        let inFlight = Task { await rig.services.refreshGrok() }
        let running = await runner.waitUntilRunning()
        let reads = rig.auth.reads
        if hide {
            rig.box.preferences.set(false, forKey: Prefs.showGrok)
            rig.services.recordQuotaShown(.grok, false)
        } else {
            rig.services.setGrokEnabled(false)
        }
        runner.resume()
        await inFlight.value // bounded: the paused run gives up after 2 s

        #expect(running, "`grok models` never started")
        #expect(rig.auth.reads == reads)
        #expect(transport.requests.count == 1 && runner.calls.count == 1)
        #expect(rig.store.grokFailure == nil)
    }

    /// Off → on while a request is pending: its failure can't overwrite the state of the new request.
    @Test(arguments: [FakeTransport.Response.json("{}", status: 500), .json("{}", status: 403), .unauthorized])
    func rapidOffOnOldFailureDropped(_ late: FakeTransport.Response) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let old = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: old) else { Issue.record("refresh never started a request"); return }
        rig.box.preferences.set(false, forKey: Prefs.showGrok)
        rig.services.recordQuotaShown(.grok, false)
        rig.box.preferences.set(true, forKey: Prefs.showGrok)
        rig.services.recordQuotaShown(.grok, true)
        let fresh = Task { await rig.services.resumeQuota(.grok) }
        guard await transport.awaitRequests(2, from: fresh) else { Issue.record("resume never refreshed"); return }

        transport.respond(late) // the old request
        #expect(await transport.join(old), "task did not finish; it likely sent an unexpected extra request")
        #expect(rig.store.grokFailure == nil)
        #expect(rig.section == .loading)

        transport.respond(.grokBilling)
        #expect(await transport.join(fresh), "task did not finish; it likely sent an unexpected extra request")
        #expect(rig.store.grokFailure == nil && rig.store.grokPlan?.percent == 10)
        #expect(rig.runner.calls.isEmpty && transport.started == 2)
    }

    // MARK: Isolation

    @Test func claudeAndLocalUsageUnaffected() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized], Hosts.anthropic: [.claudeUsage]])
        let rig = try Rig(transport: transport)
        try rig.box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                          Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
        rig.services.setClaudeLimitsEnabled(true)

        await rig.services.refreshGrok()
        await rig.services.refreshClaude()
        let usage = await refreshLedger(rig.services.ledger)
        rig.store.grokUsage = usage.grok

        #expect(rig.store.grokFailure == .authRejected(.succeeded))
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.claudeError == nil && rig.claude.reads == 1)
        #expect(usage.claude.today.tokens == 150)
        #expect(rig.store.localGrokUsage?.today.tokens == 150 && rig.store.localGrokUsage?.today.cost == CostEstimate(known: 0.25, knownTokens: 150))
    }

    // MARK: UI selection and copy

    private static let allFailures: [GrokError] = [
        .notConfigured, .invalidCredentials, .authRejected(nil), .authRejected(.succeeded),
        .authRejected(.failed(status: 1)), .authRejected(.failed(status: nil)), .authRejected(.cliMissing),
        .accessDenied(402), .accessDenied(403), .endpointUnavailable, .rateLimited, .serverError(500), .network,
        .unexpectedResponse, .http(400),
    ]

    @Test func sectionSelection() throws {
        let store = Store()
        #expect(GrokSection.select(store) == nil)
        store.grokConsentRequested = true
        #expect(GrokSection.select(store) == .consent)
        store.grokEnabled = true
        #expect(GrokSection.select(store) == .loading)

        // Opted in and shown: every failure is visible, with or without a plan ever fetched.
        for failure in Self.allFailures {
            store.grokPlan = nil
            store.grokFailure = failure
            #expect(GrokSection.select(store) == .failure(failure))
        }
        store.grokPlan = GrokPlan(percent: 5, periodEnd: Date().addingTimeInterval(86400), periodName: "month",
                                  products: [], fetchedAt: Date())
        store.grokFailure = .network
        #expect(GrokSection.select(store) == .plan(.init(staleBecause: .network)))

        store.grokQuotaShown = false
        #expect(GrokSection.select(store) == .paused)
    }

    @Test func guidanceFitsTheFailure() {
        for failure in Self.allFailures {
            let text = failure.title + " " + failure.guidance
            #expect(!text.contains("CANARY"))
            #expect(!failure.title.isEmpty && !failure.guidance.isEmpty)
            let credential: Bool
            switch failure {
            case .notConfigured, .invalidCredentials, .authRejected: credential = true
            default: credential = false
            }
            // Signing in is suggested for credential problems only, never for network, 429 or 5xx.
            let suggestsSignIn = ["sign in", "log in", "reauth"].contains { failure.guidance.localizedCaseInsensitiveContains($0) }
            #expect(suggestsSignIn == credential, "\(failure)")
        }
        // 402/403 doesn't claim a cause the response doesn't give.
        #expect(GrokError.accessDenied(403).guidance.contains("doesn't say why"))
    }
}
