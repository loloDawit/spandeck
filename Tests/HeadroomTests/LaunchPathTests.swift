import Foundation
import Testing
@testable import Headroom

/// Drives the launch path against fakes (#12). These tests pin down *current* inherited behavior, including
/// behavior the #3 audit flags as wrong; each such assertion names the remediation that will flip it.
/// Nothing here touches the real Keychain, network, login items, home directory or standard defaults.
@MainActor
struct LaunchPathTests {
    private func refresh(_ ledger: Ledger) async -> (claude: UsageSummary, grok: UsageSummary) {
        await withCheckedContinuation { c in
            ledger.refresh(windowStart: nil, progress: { _ in }, completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
        }
    }

    // Acceptance 1: the default launch performs exactly the side effects listed in audit §6.
    @Test func defaultLaunchSideEffects() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage], Hosts.pricing: [.pricingTable]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let login = FakeLoginItem()
        let runner = FakeProcessRunner()
        let env = box.environment(transport: transport, runner: runner, credentials: creds, loginItem: login)
        let services = ProviderServices(store: Store(), env: env)

        await services.start()?.value
        await services.refreshClaude()
        await services.refreshGrok()
        _ = await refresh(services.ledger)

        // Login item registered without asking (#4, R1).
        #expect(login.registers == 1)
        #expect(box.defaults.bool(forKey: "didRegisterLoginItem"))
        // Keychain read and unofficial endpoint with no opt-in (#4, R2).
        #expect(creds.reads == 1)
        #expect(transport.hosts.sorted() == [Hosts.anthropic, Hosts.pricing])
        #expect(transport.unexpected.isEmpty)
        let usage = try #require(transport.requests.first { $0.url?.host == Hosts.anthropic })
        #expect(usage.url?.path == "/api/oauth/usage")
        #expect(usage.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-NOT-A-TOKEN")
        #expect(usage.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        // Borrowed Claude Code identity (#4, R9).
        #expect(usage.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1 headroom")
        #expect(services.store.claudeLimits?.session?.percent == 42)
        // No Grok install in the sandbox: no Grok request, no subprocess.
        #expect(runner.calls.isEmpty)
        #expect(!services.store.grokAvailable)
        // Price table cached inside the sandbox.
        #expect(FileManager.default.fileExists(atPath: box.appSupport.appendingPathComponent("pricing.json").path))

        // Relaunch: no second registration, and a fresh price table means no second download.
        let relaunch = ProviderServices(store: Store(), env: env)
        #expect(relaunch.start() == nil)
        #expect(login.registers == 1)
        #expect(transport.hosts.filter { $0 == Hosts.pricing }.count == 1)
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

    // Acceptance 2: display toggles only hide gauges; collection continues (#4, R3 will flip this).
    // R3 must read the toggles from `env.defaults` (`.standard` in `live`), not `Prefs`, or this test cannot flip.
    @Test func displayTogglesDoNotGateCollection() async throws {
        let box = try Sandbox()
        box.defaults.set(false, forKey: Prefs.showClaude)
        box.defaults.set(false, forKey: Prefs.showGrok)
        try box.write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"}}"#)
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage],
                                       Hosts.grok: [.json(#"{"config":{"creditUsagePercent":10}}"#)]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: creds))

        await services.refreshClaude()
        await services.refreshGrok()

        #expect(creds.reads == 1)
        #expect(transport.hosts.sorted() == [Hosts.anthropic, Hosts.grok])
        let grok = try #require(transport.requests.first { $0.url?.host == Hosts.grok })
        #expect(grok.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-GROK-KEY")
        #expect(services.store.grokPlan?.percent == 10)
    }

    // Acceptance 3: a failed Grok refresh is reported as "not configured" (#4, R5 will flip this).
    @Test func grokRefreshFailureLooksNotConfigured() async throws {
        let box = try Sandbox()
        try box.write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"}}"#)
        let bin = try box.write(".grok/bin/grok", "", executable: true)
        let transport = FakeTransport([Hosts.grok: [.unauthorized]])
        let runner = FakeProcessRunner()
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, runner: runner))

        await services.refreshGrok()

        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.path == bin.path)
        #expect(runner.calls.first?.args == ["models"])
        #expect(transport.hosts == [Hosts.grok, Hosts.grok])
        #expect(!services.store.grokAvailable)
        #expect(services.store.grokError == nil)
    }

    // Acceptance 4: the ledger cache keeps transcript paths (#5, R8) but never transcript content.
    @Test func ledgerCacheKeepsPathsNotContent() async throws {
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
        #expect(files.keys.contains { $0.hasSuffix("-Users-synthetic-proj/s1.jsonl") })
        #expect(!String(decoding: cache, as: UTF8.self).contains(canary))
    }

    // Acceptance 5: prices download at launch; offline, unpriced models add $0 to totals (#7, R7 will flip this).
    @Test func offlinePricingCountsAsZero() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                      Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
        let transport = FakeTransport() // every host offline
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport))

        await services.start()?.value
        #expect(transport.hosts == [Hosts.pricing])
        let s = await refresh(services.ledger).claude
        #expect(s.today.tokens == 150)
        #expect(s.today.cost == 0)
        #expect(s.models.first?.cost == nil)
    }

    @Test func pricedModelsAreCosted() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                      Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport([Hosts.pricing: [.pricingTable]])))

        await services.start()?.value
        let s = await refresh(services.ledger).claude
        // 100 input * 1e-6 + 50 output * 2e-6
        #expect(abs(s.today.cost - 0.0002) < 1e-12)
        #expect(s.models.first?.cost != nil)
    }
}

/// Acceptance 6: real side-effecting APIs are reachable only from `AppEnvironment.live`, so tests built on
/// `Sandbox` cannot touch the real Keychain, network, login items or home directory.
struct SeamBoundaryTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Headroom")
    private static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    private func files(in dir: URL, mentioning needle: String) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
        return Set(try names.filter { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8).contains(needle) })
    }

    @Test(arguments: [
        ("SMAppService", ["Dependencies.swift"]),
        ("URLSession", ["Dependencies.swift"]),
        ("/usr/bin/security", ["Dependencies.swift"]),
        ("runProcess(", ["Dependencies.swift", "Util.swift"]),
        ("appSupportDir", ["Dependencies.swift", "Util.swift"]),
        // Hover.swift: debug-only log behind the `debugHover` default; out of scope for #12.
        ("homeDir", ["Dependencies.swift", "Util.swift", "Hover.swift"]),
    ])
    func sideEffectsOnlyInLiveEnvironment(_ needle: String, _ allowed: [String]) throws {
        #expect(try files(in: Self.sources, mentioning: needle) == Set(allowed))
    }

    @Test(arguments: ["AppEnvironment.live", "Pricing.shared", "homeDir", "appSupportDir", "SMAppService", "runProcess("])
    func testsNeverUseLiveDependencies(_ needle: String) throws {
        let offenders = try files(in: Self.tests, mentioning: needle).subtracting(["LaunchPathTests.swift"])
        #expect(offenders.isEmpty)
    }
}
