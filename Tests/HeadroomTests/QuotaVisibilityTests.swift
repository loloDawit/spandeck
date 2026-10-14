import Foundation
import Testing
@testable import Headroom

/// R3 (#19): the Claude limits / Grok credits menu-bar switches pause and resume quota collection. Consent stays
/// mandatory and is never changed by the switches; local transcript usage is unaffected. All fixtures are synthetic.
@MainActor
struct QuotaVisibilityTests {
    private struct Rig {
        let box: Sandbox
        let auth: CountingGrokAuth
        let runner: FakeProcessRunner
        let claude = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services: ProviderServices

        init(transport: HTTPTransport, grokExpiresIn: TimeInterval? = nil, runner: FakeProcessRunner = FakeProcessRunner(),
             prefs: [String: Bool] = [:]) throws {
            box = try Sandbox()
            try box.installGrok(expiresIn: grokExpiresIn)
            try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                          Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
            let saved = box.preferences
            prefs.forEach { saved.set($1, forKey: $0) }
            auth = CountingGrokAuth(home: box.home)
            self.runner = runner
            services = ProviderServices(store: Store(), env: box.environment(
                transport: transport, runner: runner, credentials: claude, grokCredentials: auth))
        }

        var store: Store { services.store }
        var prefs: InMemoryPreferences { box.preferences }

        /// Flips a menu-bar switch the way the Settings menu does: write the preference, then apply it.
        func show(_ key: String, _ on: Bool) async {
            prefs.set(on, forKey: key)
            await services.applyQuotaVisibility()
        }

        /// Timer, manual refresh and wake: `refreshLimits(force:)` in the app delegate calls these two.
        func refreshAll(force: Bool) async {
            await services.refreshClaude(force: force)
            await services.refreshGrok()
        }
    }

    private static let both: [String: [FakeTransport.Response]] = [Hosts.anthropic: [.claudeUsage], Hosts.grok: [.grokBilling]]
    private static let consented = [Prefs.claudeLimits: true, Prefs.grokCredits: true]
    private static let consentedHidden = consented.merging([Prefs.showClaude: false, Prefs.showGrok: false]) { $1 }

    // 1. Consent off, switches on (the default): no credential access or quota requests, forced or not.
    @Test(arguments: [false, true])
    func consentOffSwitchOnDoesNothing(force: Bool) async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, grokExpiresIn: -3600,
                          prefs: [Prefs.showClaude: true, Prefs.showGrok: true])

        await rig.refreshAll(force: force)
        await rig.show(Prefs.showClaude, true)

        #expect(rig.claude.reads == 0 && rig.auth.reads == 0)
        #expect(transport.requests.isEmpty && rig.runner.calls.isEmpty)
    }

    // 2 + 7. Consent on, switches off: timer, manual refresh and wake collect nothing; consent is untouched.
    @Test(arguments: [false, true])
    func hiddenWithConsentCollectsNothing(force: Bool) async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, grokExpiresIn: -3600, prefs: Self.consentedHidden)

        for _ in 0..<3 { await rig.refreshAll(force: force) }

        #expect(rig.claude.reads == 0 && rig.auth.reads == 0)
        #expect(transport.requests.isEmpty && rig.runner.calls.isEmpty)
        #expect(rig.store.claudeLimitsEnabled && rig.store.grokEnabled)
        #expect(!rig.store.claudeQuotaShown && !rig.store.grokQuotaShown)
    }

    // 3. Both on: normal refresh.
    @Test func consentAndSwitchOnCollects() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: Self.consented)

        await rig.refreshAll(force: false)

        #expect(rig.claude.reads == 1 && rig.auth.reads == 1)
        #expect(transport.hosts.sorted() == [Hosts.anthropic, Hosts.grok])
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.grokPlan?.percent == 10)
    }

    // Hiding a gauge clears its shown plan data and stops further collection, without touching consent.
    @Test func hidingClearsAndStops() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: Self.consented)
        await rig.refreshAll(force: false)

        await rig.show(Prefs.showClaude, false)
        await rig.show(Prefs.showGrok, false)
        await rig.refreshAll(force: true)

        #expect(rig.store.claudeLimits == nil && rig.store.claudeError == nil && !rig.store.claudeAvailable)
        #expect(rig.store.grokPlan == nil && rig.store.grokError == nil && !rig.store.grokAvailable)
        #expect(rig.claude.reads == 1 && rig.auth.reads == 1 && transport.requests.count == 2)
        #expect(rig.prefs.bool(forKey: Prefs.claudeLimits) && rig.prefs.bool(forKey: Prefs.grokCredits))
    }

    // 4. Off → on under existing consent: exactly one refresh per provider; re-applying does not refresh again.
    @Test func showingResumesOnceUnderConsent() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: Self.consentedHidden)

        await rig.show(Prefs.showClaude, true)
        await rig.show(Prefs.showGrok, true)
        await rig.services.applyQuotaVisibility() // e.g. an unrelated preference change
        await rig.services.applyQuotaVisibility()

        #expect(transport.hosts.sorted() == [Hosts.anthropic, Hosts.grok])
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.grokPlan?.percent == 10)
        #expect(rig.store.claudeQuotaShown && rig.store.grokQuotaShown)
    }

    // In the app a Settings flip applies twice at once (the menu's callback and the defaults notification).
    // Only one refresh may result.
    @Test func concurrentApplyRefreshesOnce() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport, prefs: Self.consentedHidden.merging([Prefs.showGrok: true]) { $1 })
        rig.prefs.set(true, forKey: Prefs.showClaude)

        let first = Task { await rig.services.applyQuotaVisibility() }
        let second = Task { await rig.services.applyQuotaVisibility() }
        let both = Task { await first.value; await second.value }
        guard await transport.awaitRequests(1, from: both) else { Issue.record("showing never refreshed"); return }
        #expect(!(await transport.waitForRequests(2, timeout: 0.3)), "a second refresh started")
        transport.respond(.claudeUsage)
        #expect(await transport.join(both), "task did not finish; it likely sent an unexpected extra request")

        #expect(transport.started == 1)
        #expect(rig.claude.reads == 1)
        #expect(rig.store.claudeLimits?.session?.percent == 42)
    }

    // 4. Off → on without consent: nothing is read, and consent is not granted.
    @Test func showingWithoutConsentDoesNothing() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, grokExpiresIn: -3600,
                          prefs: [Prefs.showClaude: false, Prefs.showGrok: false])

        await rig.show(Prefs.showClaude, true)
        await rig.show(Prefs.showGrok, true)

        #expect(rig.claude.reads == 0 && rig.auth.reads == 0)
        #expect(transport.requests.isEmpty && rig.runner.calls.isEmpty)
        #expect(!rig.prefs.bool(forKey: Prefs.claudeLimits) && !rig.prefs.bool(forKey: Prefs.grokCredits))
        #expect(!rig.store.claudeLimitsEnabled && !rig.store.grokEnabled)
    }

    // 5. Claude hidden while a request is in flight: its late success, error or 429 is dropped. With `reshow`,
    // the gauge comes back before the late answer; only the resumed request's answer is published.
    @Test(arguments: [FakeTransport.Response.claudeUsage, .json("{}", status: 500), .json("{}", status: 429)], [false, true])
    func hidingDropsInFlightClaude(_ late: FakeTransport.Response, reshow: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport, prefs: [Prefs.claudeLimits: true])

        let inFlight = Task { await rig.services.refreshClaude(force: true) }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        await rig.show(Prefs.showClaude, false)
        var resumed: Task<Void, Never>?
        if reshow {
            rig.prefs.set(true, forKey: Prefs.showClaude)
            let resume = Task { await rig.services.applyQuotaVisibility() }
            resumed = resume
            guard await transport.awaitRequests(2, from: resume) else { Issue.record("showing again never refreshed"); return }
        }
        transport.respond(late)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.claudeLimits == nil && rig.store.claudeError == nil && !rig.store.claudeAvailable)
        if let resumed {
            transport.respond(.json(#"{"limits":[{"kind":"session","percent":7}]}"#))
            #expect(await transport.join(resumed), "task did not finish; it likely sent an unexpected extra request")
            #expect(rig.store.claudeLimits?.session?.percent == 7 && rig.store.claudeError == nil)
        }
        #expect(transport.started == (reshow ? 2 : 1))
    }

    // 5. Grok hidden while the billing request is in flight: the late result is dropped.
    @Test(arguments: [FakeTransport.Response.grokBilling, .json("{}", status: 500)])
    func hidingDropsInFlightGrok(_ late: FakeTransport.Response) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport, prefs: [Prefs.grokCredits: true])

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        await rig.show(Prefs.showGrok, false)
        transport.respond(late)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.grokPlan == nil && rig.store.grokError == nil && !rig.store.grokAvailable)
        #expect(transport.started == 1 && rig.runner.calls.isEmpty)
    }

    // 6. Grok hidden while the first request is pending, which then returns 401: no `grok models`, no further key
    // read, no retry. With `reshow`, the gauge comes back first; the stale fetch still stops.
    @Test(arguments: [false, true])
    func hidingBeforeGrok401SkipsRecovery(reshow: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport, prefs: [Prefs.grokCredits: true])

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        let reads = rig.auth.reads
        rig.prefs.set(false, forKey: Prefs.showGrok)
        await rig.services.applyQuotaVisibility()
        var resumed: Task<Void, Never>?
        if reshow {
            rig.prefs.set(true, forKey: Prefs.showGrok)
            let resume = Task { await rig.services.applyQuotaVisibility() }
            resumed = resume
            guard await transport.awaitRequests(2, from: resume) else { Issue.record("showing again never refreshed"); return }
        }
        transport.respond(.unauthorized)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.runner.calls.isEmpty)
        #expect(rig.auth.reads == reads + (reshow ? 1 : 0)) // only the resumed fetch's own read
        #expect(transport.started == (reshow ? 2 : 1))
        if let resumed {
            transport.respond(.grokBilling)
            #expect(await transport.join(resumed), "task did not finish; it likely sent an unexpected extra request")
            #expect(rig.store.grokPlan?.percent == 10)
        }
    }

    // 6. Grok hidden while `grok models` runs for an expired key: no key read or request afterwards. Showing it
    // again resumes collection but keeps the 10-minute `grok models` throttle.
    @Test func hidingDuringGrokModelsStopsAndKeepsThrottle() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let runner = FakeProcessRunner(pausing: true)
        let rig = try Rig(transport: transport, grokExpiresIn: -3600, runner: runner, prefs: [Prefs.grokCredits: true])

        let inFlight = Task { await rig.services.refreshGrok() }
        let running = await runner.waitUntilRunning()
        await rig.show(Prefs.showGrok, false)
        runner.resume()
        await inFlight.value // bounded: the paused run gives up after 2 s

        #expect(running, "`grok models` never started")
        #expect(rig.auth.reads == 1)
        #expect(transport.requests.isEmpty)
        #expect(runner.calls.count == 1)

        await rig.show(Prefs.showGrok, true)

        #expect(runner.calls.count == 1) // throttled: still within 10 minutes
        #expect(transport.requests.count == 1)
        #expect(rig.store.grokPlan?.percent == 10)
    }

    // 8. Claude and Grok switches are independent of each other and of consent.
    @Test func switchesAreIsolated() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: Self.consented)
        await rig.refreshAll(force: false)

        await rig.show(Prefs.showClaude, false)
        await rig.refreshAll(force: true)
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.claudeLimits == nil)
        #expect(transport.hosts.filter { $0 == Hosts.anthropic }.count == 1)
        #expect(transport.hosts.filter { $0 == Hosts.grok }.count == 2)

        await rig.show(Prefs.showClaude, true)
        await rig.show(Prefs.showGrok, false)
        await rig.refreshAll(force: true)
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.grokPlan == nil)
        #expect(transport.hosts.filter { $0 == Hosts.grok }.count == 2)

        // Consent changes leave the switches alone, and the switches leave consent alone.
        await rig.services.applyClaudeLimitsChoice(false)
        await rig.services.applyGrokChoice(false)
        #expect(rig.prefs.bool(forKey: Prefs.showClaude) && !rig.prefs.bool(forKey: Prefs.showGrok))
        #expect(rig.store.claudeQuotaShown && !rig.store.grokQuotaShown)
        #expect(rig.claude.reads == 3 && rig.runner.calls.isEmpty)
    }

    // Enabling consent while the gauge is hidden records consent but collects nothing until it is shown.
    @Test func consentWhileHiddenWaitsForSwitch() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: [Prefs.showClaude: false, Prefs.showGrok: false])

        await rig.services.applyClaudeLimitsChoice(true)
        await rig.services.applyGrokChoice(true)

        #expect(rig.store.claudeLimitsEnabled && rig.store.grokEnabled)
        #expect(rig.claude.reads == 0 && rig.auth.reads == 0 && transport.requests.isEmpty)
        #expect(!rig.prefs.bool(forKey: Prefs.showClaude) && !rig.prefs.bool(forKey: Prefs.showGrok))
    }

    // 9. Local Claude and Grok token/cost accounting continues while quota polling is paused.
    @Test func localUsageCountsWhilePaused() async throws {
        let transport = FakeTransport([Hosts.pricing: [.pricingTable]])
        let rig = try Rig(transport: transport, prefs: Self.consentedHidden)
        await rig.services.start()?.value

        await rig.refreshAll(force: true)
        let usage = await refreshLedger(rig.services.ledger)
        rig.store.grokUsage = usage.grok

        #expect(transport.hosts == [Hosts.pricing])
        #expect(usage.claude.today.tokens == 150)
        #expect(usage.claude.today.cost > 0)
        #expect(rig.store.localGrokUsage?.today.tokens == 150 && rig.store.localGrokUsage?.today.cost == 0.25)
    }

    // 10. Upgrade: saved switches are honored at launch; absent keys mean "shown"; launch applies no extra refresh.
    @Test func savedPreferencesAtLaunch() async throws {
        let transport = FakeTransport(Self.both)
        let rig = try Rig(transport: transport, prefs: [Prefs.claudeLimits: true, Prefs.grokCredits: true,
                                                        Prefs.showClaude: false])

        #expect(!rig.store.claudeQuotaShown && rig.store.grokQuotaShown)
        await rig.services.applyQuotaVisibility()
        #expect(transport.requests.isEmpty)

        await rig.refreshAll(force: true)
        #expect(rig.claude.reads == 0)
        #expect(transport.hosts == [Hosts.grok])
    }
}
