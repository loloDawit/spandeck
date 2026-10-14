import Foundation
import Testing
@testable import Headroom

/// Grok credits are opt-in (#17): without consent the app never reads `~/.grok/auth.json`, calls the billing
/// endpoint or runs `grok models`, while local Grok usage files are still counted. All fixtures are synthetic.
@MainActor
struct GrokConsentTests {
    private struct Rig {
        let box: Sandbox
        let auth: CountingGrokAuth
        let runner = FakeProcessRunner()
        let claude = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services: ProviderServices

        init(transport: HTTPTransport, expiresIn: TimeInterval? = nil) throws {
            box = try Sandbox()
            try box.installGrok(expiresIn: expiresIn)
            auth = CountingGrokAuth(home: box.home)
            services = ProviderServices(store: Store(), env: box.environment(
                transport: transport, runner: runner, credentials: claude, grokCredentials: auth))
        }

        var store: Store { services.store }
    }

    // Acceptance 1: default launch with Grok installed does no credential work but still counts local usage.
    @Test func defaultLaunchDoesNoGrokCredentialWork() async throws {
        let transport = FakeTransport([Hosts.pricing: [.pricingTable]])
        let rig = try Rig(transport: transport, expiresIn: -3600) // expired key: would normally run `grok models`
        let before = try rig.box.grokFiles()

        await rig.services.start()?.value
        await rig.services.refreshClaude()
        await rig.services.refreshGrok()
        rig.store.grokUsage = await refreshLedger(rig.services.ledger).grok

        #expect(rig.auth.reads == 0)
        #expect(rig.runner.calls.isEmpty)
        #expect(transport.hosts == [Hosts.pricing])
        #expect(!rig.store.grokEnabled && rig.store.grokPlan == nil && !rig.store.grokAvailable)
        // Local usage accounting is independent of consent.
        #expect(rig.store.localGrokUsage?.today.tokens == 150)
        #expect(rig.store.localGrokUsage?.today.cost == 0.25)
        #expect(try rig.box.grokFiles() == before)
    }

    // Acceptance 2: manual refresh and wake call `refreshGrok()`; while off it does nothing, however often.
    @Test func refreshWhileDisabledDoesNothing() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport, expiresIn: -3600)

        for _ in 0..<3 { await rig.services.refreshGrok() }

        #expect(rig.auth.reads == 0)
        #expect(transport.requests.isEmpty)
        #expect(rig.runner.calls.isEmpty)
    }

    // Acceptance 3: enabling reads the key and calls billing, persists, and leaves Claude alone.
    @Test func enablingGrokReadsOnlyGrokAndPersists() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport)
        let before = try rig.box.grokFiles()

        await rig.services.applyGrokChoice(true)

        #expect(rig.auth.reads >= 1)
        #expect(transport.hosts == [Hosts.grok])
        let billing = try #require(transport.requests.first)
        #expect(billing.url?.path == "/v1/billing")
        #expect(billing.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-GROK-KEY")
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokAvailable)
        #expect(rig.claude.reads == 0)
        #expect(rig.runner.calls.isEmpty)
        #expect(rig.box.preferences.bool(forKey: Prefs.grokCredits))
        #expect(try rig.box.grokFiles() == before)

        let relaunch = ProviderServices(store: Store(), env: rig.box.environment(transport: transport))
        #expect(relaunch.store.grokEnabled)
    }

    // An expired key with consent: `grok models` runs once before the request (inherited behavior, now opt-in).
    @Test func enabledExpiredKeyRunsGrokModelsOnce() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport, expiresIn: -3600)

        await rig.services.applyGrokChoice(true)

        #expect(rig.runner.calls.map(\.args) == [["models"]])
        #expect(transport.requests.count == 1)
    }

    // Acceptance 4: disabling clears plan data and stops all further Grok credential access.
    @Test func disablingClearsAndStops() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport)
        await rig.services.applyGrokChoice(true)
        let reads = rig.auth.reads

        await rig.services.applyGrokChoice(false)
        await rig.services.refreshGrok()

        #expect(rig.store.grokPlan == nil && rig.store.grokError == nil && !rig.store.grokAvailable)
        #expect(!rig.store.grokEnabled && !rig.box.preferences.bool(forKey: Prefs.grokCredits))
        #expect(rig.auth.reads == reads)
        #expect(transport.requests.count == 1)
        #expect(rig.claude.reads == 0)
    }

    // Acceptance 5: a result that arrives after the user turned Grok off is dropped.
    @Test func lateResultAfterDisableIsDropped() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)
        rig.services.setGrokEnabled(true)

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        rig.services.setGrokEnabled(false)
        transport.respond(.grokBilling)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.grokPlan == nil && !rig.store.grokAvailable)
    }

    // Off and on again while a request is pending: the old success or failure is still dropped.
    @Test(arguments: [FakeTransport.Response.grokBilling, .json("{}", status: 500)])
    func lateResultAfterReenableIsDropped(_ late: FakeTransport.Response) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)
        rig.services.setGrokEnabled(true)

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        rig.services.setGrokEnabled(false)
        rig.services.setGrokEnabled(true)
        transport.respond(late)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.grokPlan == nil && rig.store.grokError == nil)
        let next = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: next) else { Issue.record("next refresh never started"); return }
        transport.respond(.grokBilling)
        #expect(await transport.join(next), "task did not finish; it likely sent an unexpected extra request")
        #expect(rig.store.grokPlan?.percent == 10)
    }

    // Acceptance 6: consent withdrawn while the first request is pending, which then returns 401:
    // the stale fetch must not run `grok models` or retry, whether or not Grok was re-enabled meanwhile.
    @Test(arguments: [false, true])
    func withdrawnMidFetchSkipsGrokModels(reenable: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)
        rig.services.setGrokEnabled(true)

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        rig.services.setGrokEnabled(false)
        if reenable { rig.services.setGrokEnabled(true) }
        transport.respond(.unauthorized)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.runner.calls.isEmpty)
        #expect(transport.started == 1)
        #expect(rig.store.grokPlan == nil && rig.store.grokError == nil)
    }

    // Two refreshes in flight when the user turns Grok off: neither publishes or runs anything.
    @Test func concurrentInFlightRefreshesAreDropped() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)
        rig.services.setGrokEnabled(true)

        let a = Task { await rig.services.refreshGrok() }
        let b = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: Task { await a.value; await b.value }) else {
            Issue.record("both refreshes should have started a request"); return
        }
        rig.services.setGrokEnabled(false)
        transport.respond(.grokBilling)
        transport.respond(.unauthorized)
        #expect(await transport.join(a), "task did not finish; it likely sent an unexpected extra request")
        #expect(await transport.join(b), "task did not finish; it likely sent an unexpected extra request")

        #expect(rig.store.grokPlan == nil && !rig.store.grokAvailable)
        #expect(rig.runner.calls.isEmpty)
        #expect(transport.started == 2)
    }

    // A new consent isn't throttled by `grok models` runs from an earlier one.
    @Test func reenableResetsCLIRefreshThrottle() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport)

        await rig.services.applyGrokChoice(true)
        #expect(rig.runner.calls.count == 1)
        await rig.services.refreshGrok()
        #expect(rig.runner.calls.count == 1) // still throttled within one consent

        await rig.services.applyGrokChoice(false)
        await rig.services.applyGrokChoice(true)
        #expect(rig.runner.calls.count == 2)
    }

    // With Claude already enabled, agreeing to Grok's consent must not trigger a Claude read or request.
    @Test func enablingGrokDoesNotRefreshClaude() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling], Hosts.anthropic: [.claudeUsage]])
        let rig = try Rig(transport: transport)
        rig.services.setClaudeLimitsEnabled(true)

        await rig.services.applyGrokChoice(true)

        #expect(rig.claude.reads == 0)
        #expect(transport.hosts == [Hosts.grok])
    }

    // Provider isolation the other way: enabling Claude does no Grok work (already covered in LaunchPathTests),
    // and turning Claude off leaves Grok's consent and data alone.
    @Test func claudeChoiceLeavesGrokAlone() async throws {
        let transport = FakeTransport([Hosts.grok: [.grokBilling], Hosts.anthropic: [.claudeUsage]])
        let rig = try Rig(transport: transport)
        await rig.services.applyGrokChoice(true)

        await rig.services.applyClaudeLimitsChoice(true)
        await rig.services.applyClaudeLimitsChoice(false)

        #expect(rig.store.grokEnabled && rig.store.grokPlan?.percent == 10)
        #expect(transport.hosts.filter { $0 == Hosts.grok }.count == 1)
    }
}
