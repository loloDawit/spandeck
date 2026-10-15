import Foundation
import Testing
@testable import Headroom

/// Drives the launch path against fakes (#12). These tests pin down current behavior. Assertions on behavior the
/// #3 audit flags as wrong name the remediation that will flip them; R1 and R2 were flipped by #15.
/// Nothing here touches the real Keychain, network, login items, home directory or persistent preferences.
@MainActor
struct LaunchPathTests {
    private func refresh(_ ledger: Ledger) async -> (claude: UsageSummary, grok: UsageSummary) {
        await withCheckedContinuation { c in
            ledger.refresh(windowStart: nil, progress: { _ in }, completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
        }
    }

    // Acceptance 1: the default launch performs only the side effects below (audit §6 as amended by #15).
    @Test func defaultLaunchSideEffects() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage], Hosts.pricing: [.pricingTable]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let login = FakeLoginItem()
        let runner = FakeProcessRunner()
        let env = box.environment(transport: transport, runner: runner, credentials: creds, loginItem: login)
        let services = ProviderServices(store: Store(), env: env)

        services.start()
        await services.refreshClaude()
        await services.refreshGrok()
        _ = await refresh(services.ledger)

        // Launch at login is opt-in from Settings only (#15).
        #expect(login.registers == 0)
        // No Keychain read and no Anthropic request without opt-in (#15). No price download either (R6): prices
        // come from the built-in snapshot.
        #expect(creds.reads == 0)
        #expect(transport.requests.isEmpty)
        #expect(services.store.pricing.source == .bundled && services.store.pricing.revision == PricingSnapshot.pin.revision)
        #expect(transport.unexpected.isEmpty)
        #expect(!services.store.claudeLimitsEnabled)
        #expect(services.store.claudeLimits == nil && !services.store.claudeAvailable)
        // No Grok install in the sandbox: no Grok request, no subprocess.
        #expect(runner.calls.isEmpty)
        #expect(!services.store.grokAvailable)
        // Nothing about prices is written (R6).
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.appSupport.path).allSatisfy { !$0.hasPrefix("pricing") })

        // Relaunch: still no registration and no download.
        let relaunch = ProviderServices(store: Store(), env: env)
        relaunch.start()
        #expect(login.registers == 0)
        #expect(transport.requests.isEmpty)
    }

    // Manual refresh and wake pass `force`, which skips the 429 backoff but must never skip consent.
    @Test func forcedRefreshWithoutConsentReadsNothing() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: creds))

        await services.refreshClaude(force: true)

        #expect(creds.reads == 0)
        #expect(transport.requests.isEmpty)
    }

    // After opting in: the Keychain is read and the unofficial endpoint called; the choice survives a relaunch.
    @Test func enablingClaudeLimitsReadsAndPersists() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let env = box.environment(transport: transport, credentials: creds)
        let services = ProviderServices(store: Store(), env: env)

        services.setClaudeLimitsEnabled(true)
        await services.refreshClaude(force: true)

        #expect(box.preferences.bool(forKey: Prefs.claudeLimits))
        #expect(services.store.claudeLimitsEnabled)
        #expect(creds.reads == 1)
        let usage = try #require(transport.requests.first { $0.url?.host == Hosts.anthropic })
        #expect(usage.url?.path == "/api/oauth/usage")
        #expect(usage.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-NOT-A-TOKEN")
        #expect(usage.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        // SpanDeck's own identity, not Claude Code's (R9).
        #expect(usage.value(forHTTPHeaderField: "User-Agent") == ProviderRequest.userAgent)
        #expect(services.store.claudeLimits?.session?.percent == 42)
        #expect(services.store.claudeAvailable)

        let relaunch = ProviderServices(store: Store(), env: env)
        #expect(relaunch.store.claudeLimitsEnabled)
    }

    // Turning limits off clears what was shown and stops further reads.
    @Test func disablingClaudeLimitsClearsAndStops() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: creds))
        services.setClaudeLimitsEnabled(true)
        await services.refreshClaude()
        #expect(services.store.claudeLimits != nil)

        services.setClaudeLimitsEnabled(false)
        await services.refreshClaude(force: true)

        #expect(!box.preferences.bool(forKey: Prefs.claudeLimits))
        #expect(services.store.claudeLimits == nil && services.store.claudeError == nil)
        #expect(!services.store.claudeAvailable && !services.store.claudeLimitsEnabled)
        #expect(creds.reads == 1)
        #expect(transport.requests.count == 1)
    }

    // A request started before the user turned limits off must not publish anything afterwards.
    @Test func lateResultAfterDisableIsDropped() async throws {
        let box = try Sandbox()
        let transport = DeferredTransport()
        defer { transport.close() }
        let services = ProviderServices(store: Store(), env: box.environment(
            transport: transport, credentials: FakeCredentialStore(FakeCredentialStore.synthetic())))
        services.setClaudeLimitsEnabled(true)

        let inFlight = Task { await services.refreshClaude(force: true) }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        services.setClaudeLimitsEnabled(false)
        transport.respond(.claudeUsage)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(services.store.claudeLimits == nil && !services.store.claudeAvailable)
    }

    // Off and on again while a request is pending: the old request's success, error or 429 is still dropped.
    @Test(arguments: [FakeTransport.Response.claudeUsage, .json("{}", status: 500), .json("{}", status: 429)])
    func lateResultAfterReenableIsDropped(_ late: FakeTransport.Response) async throws {
        let box = try Sandbox()
        let transport = DeferredTransport()
        defer { transport.close() }
        let services = ProviderServices(store: Store(), env: box.environment(
            transport: transport, credentials: FakeCredentialStore(FakeCredentialStore.synthetic())))
        services.setClaudeLimitsEnabled(true)

        let inFlight = Task { await services.refreshClaude(force: true) }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        services.setClaudeLimitsEnabled(false)
        services.setClaudeLimitsEnabled(true)
        transport.respond(late)
        #expect(await transport.join(inFlight), "task did not finish; it likely sent an unexpected extra request")

        #expect(services.store.claudeLimits == nil)
        #expect(services.store.claudeError == nil)
        // No stale 429 backoff: an unforced refresh still goes out.
        let next = Task { await services.refreshClaude() }
        guard await transport.awaitRequests(2, from: next) else {
            Issue.record("unforced refresh was suppressed by a stale backoff")
            return
        }
        transport.respond(.claudeUsage)
        #expect(await transport.join(next), "task did not finish; it likely sent an unexpected extra request")
        #expect(services.store.claudeLimits?.session?.percent == 42)
    }

    // The harness itself: a timeout closes the transport, so a request that starts late, or a task that never
    // sends one, ends promptly instead of hanging the run.
    @Test func deferredTransportTimeoutTerminates() async throws {
        let clock = Date()
        let url = URL(string: "https://example.invalid")!

        let idle = DeferredTransport()
        let quiet = Task<Void, Never> {}
        #expect(await idle.awaitRequests(1, from: quiet, timeout: 0.05) == false)

        let transport = DeferredTransport()
        let late = Task { () -> Bool in (try? await transport.data(for: URLRequest(url: url))) == nil }
        #expect(await transport.waitForRequests(1))
        transport.close()
        #expect(await late.value, "pending request should fail on close")
        #expect(await Task { (try? await transport.data(for: URLRequest(url: url))) == nil }.value,
                "requests after close should fail immediately")

        #expect(Date().timeIntervalSince(clock) < 1)
    }

    // Agreeing to Claude's consent refreshes Claude only: no Grok credential read, request or subprocess.
    @Test func enablingClaudeDoesNotTouchGrok() async throws {
        let box = try Sandbox()
        try box.write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"}}"#)
        try box.write(".grok/bin/grok", "", executable: true)
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage], Hosts.grok: [.unauthorized]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let runner = FakeProcessRunner()
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, runner: runner, credentials: creds))

        await services.applyClaudeLimitsChoice(true)

        #expect(creds.reads == 1)
        #expect(transport.hosts == [Hosts.anthropic])
        #expect(runner.calls.isEmpty)
        #expect(services.store.claudeLimits?.session?.percent == 42)

        await services.applyClaudeLimitsChoice(false)
        #expect(creds.reads == 1 && transport.requests.count == 1)
        #expect(services.store.claudeLimits == nil && !services.store.claudeLimitsEnabled)
    }

    // A login item the user (or an older Headroom build) already registered is neither re-registered nor removed.
    @Test func existingLoginItemIsLeftAlone() async throws {
        let box = try Sandbox()
        let login = FakeLoginItem(enabled: true)
        let env = box.environment(transport: FakeTransport([Hosts.pricing: [.pricingTable]]), loginItem: login)

        ProviderServices(store: Store(), env: env).start()

        #expect(login.isEnabled)
        #expect(login.registers == 0 && login.unregisters == 0)
    }

    @Test func keychainStoreUsesSecurityCLI() {
        let runner = FakeProcessRunner()
        runner.result = (0, Data("{}".utf8))
        #expect(KeychainCredentialStore(runner: runner).claudeCredentialJSON() == Data("{}".utf8))
        #expect(runner.calls.map(\.path) == ["/usr/bin/security"])
        #expect(runner.calls.first?.args == ["find-generic-password", "-s", "Claude Code-credentials", "-w"])

        runner.result = (44, Data())
        #expect(KeychainCredentialStore(runner: runner).claudeCredentialJSON() == nil)
    }

    // Acceptance 2, flipped by R3 (#19): with consent, hidden menu-bar gauges pause quota collection.
    // The toggles are read from `env.preferences`. More cases in QuotaVisibilityTests.
    @Test func displayTogglesGateCollection() async throws {
        let box = try Sandbox()
        box.preferences.set(false, forKey: Prefs.showClaude)
        box.preferences.set(false, forKey: Prefs.showGrok)
        try box.write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"}}"#)
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage],
                                       Hosts.grok: [.json(#"{"config":{"creditUsagePercent":10}}"#)]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: creds))
        services.setClaudeLimitsEnabled(true)
        services.setGrokEnabled(true)

        await services.refreshClaude(force: true)
        await services.refreshGrok()

        #expect(creds.reads == 0)
        #expect(transport.requests.isEmpty)
        #expect(services.store.grokPlan == nil && services.store.claudeLimits == nil)
    }

    // Acceptance 3, flipped by R5 (#21): a login still rejected after `grok models` is an auth failure that stays
    // visible, not "not configured". More cases in GrokErrorStateTests.
    @Test func grokRefreshFailureIsAuthFailure() async throws {
        let box = try Sandbox()
        try box.write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"}}"#)
        let bin = try box.write(".grok/bin/grok", "", executable: true)
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let runner = FakeProcessRunner()
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, runner: runner))
        services.setGrokEnabled(true)

        await services.refreshGrok()

        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.path == bin.path)
        #expect(runner.calls.first?.args == ["models"])
        #expect(transport.hosts == [Hosts.grok, Hosts.grok])
        #expect(services.store.grokFailure == .authRejected(.succeeded))
        #expect(GrokSection.select(services.store) == .failure(.authRejected(.succeeded)))
    }

    // Acceptance 4, flipped by R8: the ledger cache keeps neither transcript paths nor content (#5, #33).
    @Test func ledgerCacheKeepsNoPathsOrContent() async throws {
        let box = try Sandbox()
        let canary = "CANARY-PROMPT-7f3a"
        try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                      Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: canary) + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))

        let summary = await refresh(services.ledger)
        #expect(summary.claude.today.tokens == 150)

        let cache = try Data(contentsOf: box.appSupport.appendingPathComponent("claude-ledger.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: cache) as? [String: Any])
        let files = try #require(json["files"] as? [String: Any])
        #expect(files.count == 1 && !files.keys.contains { $0.contains("synthetic-proj") || $0.contains("s1.jsonl") })
        let text = String(decoding: cache, as: UTF8.self)
        #expect(!text.contains(canary) && !text.contains("synthetic-proj") && !text.contains("msg_1") && !text.contains("req_1"))
    }

    // Acceptance 5, flipped by R6: launch downloads nothing; offline, a model in the built-in snapshot is priced.
    @Test func offlineStartupUsesBundledPricing() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                      Sandbox.transcriptLine(model: "claude-haiku-4-5-20251001", id: "1", canary: "x") + "\n")
        let transport = FakeTransport() // every host offline
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport))

        services.start()
        #expect(transport.requests.isEmpty)
        let s = await refresh(services.ledger).claude
        #expect(s.today.tokens == 150)
        // 100 input * 1e-6 + 50 output * 5e-6 at the snapshot's claude-haiku-4-5 prices.
        #expect(abs(s.today.cost.known - 0.00035) < 1e-12 && s.today.cost.coverage == .complete)
        #expect(s.models.first?.cost.value != nil)
    }

    // Flipped by R7: a model without a listed price makes the cost unavailable, never $0; its tokens still count.
    @Test func unpricedModelIsUnavailableNotZero() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                      Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))

        services.start()
        let s = await refresh(services.ledger).claude
        #expect(s.today.tokens == 150)
        #expect(s.today.cost == CostEstimate(known: 0, knownTokens: 0, unknownTokens: 150))
        #expect(s.today.cost.coverage == .unavailable && Fmt.cost(s.today.cost) == "n/a")
        #expect(s.models.first?.cost.coverage == .unavailable)
    }
}

/// Acceptance 6: real side-effecting APIs are reachable only from the live `AppEnvironment`, so tests built on
/// `Sandbox` cannot touch the real Keychain, network, login items, preferences or home directory.
/// Needles are assembled from fragments so this file contains none of them literally and needs no exemption.
struct SeamBoundaryTests {
    private static func needle(_ parts: String...) -> String { parts.joined() }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Headroom")
    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    private func files(in dir: URL, mentioning needle: String) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return Set(try names.filter { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8).contains(needle) })
    }

    @Test(arguments: [
        (needle("SMApp", "Service"), ["Dependencies.swift"]),
        (needle("URL", "Session"), ["Dependencies.swift"]),
        (needle("/usr/bin/", "security"), ["Dependencies.swift"]),
        (needle("(\".grok/", "auth.json\")"), ["Dependencies.swift"]),
        (needle("run", "Process("), ["Dependencies.swift", "Util.swift"]),
        (needle("app", "SupportDir"), ["Dependencies.swift", "Util.swift"]),
        // Hover.swift: debug-only log behind the `debugHover` default; out of scope for #12.
        (needle("home", "Dir"), ["Dependencies.swift", "Util.swift", "Hover.swift"]),
    ])
    func sideEffectsOnlyInLiveEnvironment(_ needle: String, _ allowed: [String]) throws {
        #expect(try files(in: Self.sources, mentioning: needle) == Set(allowed))
    }

    @Test(arguments: [
        needle("AppEnvironment", ".live"), needle("Pricing", ".shared"), needle("home", "Dir"), needle("app", "SupportDir"),
        needle("SMApp", "Service"), needle("run", "Process("), needle("URL", "Session"), needle("UserDefaults", "("),
    ])
    func testsNeverUseLiveDependencies(_ needle: String) throws {
        // Every test file is scanned, including this one. KeepAwakeTests' use of the standard defaults
        // and real power assertions predates #12 and is not matched by these needles.
        #expect(try files(in: Self.tests, mentioning: needle).isEmpty)
    }
}
