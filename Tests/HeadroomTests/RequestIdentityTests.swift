import Foundation
import Testing
@testable import Headroom

/// R9: provider requests identify SpanDeck honestly, and a rejected credential (HTTP 401) pauses that provider's quota
/// collection instead of being resent on every refresh. Claude pauses 5 min after a 401; Grok pauses 10 min after the
/// key is still rejected following its recovery. Time is synthetic (`TestClock`); nothing sleeps for minutes. All
/// fixtures are synthetic.
@MainActor
struct RequestIdentityTests {
    private struct Rig {
        let box: Sandbox
        let clock = TestClock()
        let auth: CountingGrokAuth
        let runner: FakeProcessRunner
        let claude = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services: ProviderServices

        /// Claude and Grok installed (canary credentials, one local usage file each), both opted in, switches on.
        @MainActor init(transport: HTTPTransport, runner: FakeProcessRunner = FakeProcessRunner()) throws {
            box = try Sandbox()
            try box.installGrok()
            try box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                          Sandbox.transcriptLine(model: "claude-test-1", id: "1", canary: "x") + "\n")
            box.preferences.set(true, forKey: Prefs.claudeLimits)
            box.preferences.set(true, forKey: Prefs.grokCredits)
            auth = CountingGrokAuth(home: box.home)
            self.runner = runner
            services = ProviderServices(store: Store(), env: box.environment(
                transport: transport, runner: runner, credentials: claude, grokCredentials: auth, clock: clock))
        }

        var store: Store { services.store }

        /// Flips a menu-bar switch the way the Settings menu does, including the resume refresh.
        @MainActor func show(_ provider: ProviderServices.QuotaSwitch, _ on: Bool) async {
            box.preferences.set(on, forKey: provider == .claude ? Prefs.showClaude : Prefs.showGrok)
            if services.recordQuotaShown(provider, on) { await services.resumeQuota(provider) }
        }

        /// Every way the app asks for a Claude refresh: timer/wake (unforced), manual refresh (forced), switch off and
        /// on, consent off and on (forced).
        @MainActor func everyClaudeTrigger() async {
            await services.refreshClaude()
            await services.refreshClaude(force: true)
            await show(.claude, false)
            await show(.claude, true)
            await services.applyClaudeLimitsChoice(false)
            await services.applyClaudeLimitsChoice(true)
        }

        /// Every way the app asks for a Grok refresh: timer, manual refresh and wake (all unforced), switch off and on,
        /// consent off and on.
        @MainActor func everyGrokTrigger() async {
            await services.refreshGrok()
            await show(.grok, false)
            await show(.grok, true)
            await services.applyGrokChoice(false)
            await services.applyGrokChoice(true)
        }
    }

    private static func count(_ transport: FakeTransport, _ host: String) -> Int { transport.hosts.filter { $0 == host }.count }

    // MARK: Request identity

    @Test func bothProvidersSendHonestUserAgent() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage], Hosts.grok: [.grokBilling]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshClaude()
        await rig.services.refreshGrok()

        #expect(Set(transport.hosts) == [Hosts.anthropic, Hosts.grok] && transport.requests.count == 2)
        for request in transport.requests {
            let ua = try #require(request.value(forHTTPHeaderField: "User-Agent"))
            #expect(ua == ProviderRequest.userAgent)
            #expect(request.httpMethod == "GET")
        }
        let claude = try #require(transport.requests.first { $0.url?.host == Hosts.anthropic })
        #expect(claude.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-NOT-A-TOKEN")
        #expect(claude.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        let grok = try #require(transport.requests.first { $0.url?.host == Hosts.grok })
        #expect(grok.value(forHTTPHeaderField: "Authorization") == "Bearer CANARY-GROK-KEY")
    }

    @Test func userAgentNamesSpanDeckOnly() {
        let ua = ProviderRequest.userAgent
        #expect(ua.hasPrefix("SpanDeck") && ua.localizedCaseInsensitiveContains("unofficial"))
        // No official client's name.
        for official in ["claude", "anthropic", "grok", "xai", "cli", "headroom"] {
            #expect(!ua.localizedCaseInsensitiveContains(official), "\(official)")
        }
        // A fixed string: nothing about the user, the machine, the install, a version or a credential is added at
        // runtime. The pin also catches any later change to the identity.
        #expect(ua == "SpanDeck (unofficial quota monitor)")
        #expect(!ua.contains(NSHomeDirectory()) && !ua.contains("CANARY") && !ua.contains("/"))
        let hasDigits = ua.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
        #expect(!hasDigits)
    }

    // MARK: Claude 401 pause

    @Test func claude401IsShownWithoutClaimingExpiry() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.unauthorized]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshClaude()

        let error = try #require(rig.store.claudeError)
        #expect(rig.store.claudeAvailable && error.contains("HTTP 401"))
        #expect(error.localizedCaseInsensitiveContains("sign in again in Claude Code"))
        #expect(!error.localizedCaseInsensitiveContains("expired") && !error.contains("CANARY"))
        #expect(transport.requests.count == 1 && rig.claude.reads == 1)
    }

    @Test func claude401PausesEveryTrigger() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.unauthorized, .claudeUsage]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()
        let error = try #require(rig.store.claudeError)

        rig.clock.advance(ProviderServices.claudeAuthPause - 1)
        await rig.everyClaudeTrigger()

        #expect(transport.requests.count == 1 && rig.claude.reads == 1) // no Keychain read or request
        #expect(rig.store.claudeError == error && rig.store.claudeAvailable) // still shown after switch/consent changes
        #expect(rig.store.claudeLimitsEnabled && rig.store.claudeQuotaShown) // the pause never changes consent or switches
    }

    @Test func claudeResumesAfterPauseAndSuccessClearsIt() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.unauthorized, .claudeUsage]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()

        rig.clock.advance(ProviderServices.claudeAuthPause)
        await rig.services.refreshClaude()
        #expect(transport.requests.count == 2)
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.claudeError == nil)

        await rig.services.refreshClaude() // no pause left after the success
        #expect(transport.requests.count == 3)
    }

    @Test func claude429BackoffUnchanged() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.json("{}", status: 429), .claudeUsage]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()
        #expect(rig.store.claudeError == "Rate limited, backing off")

        await rig.services.refreshClaude()
        #expect(transport.requests.count == 1) // unforced: backing off
        await rig.services.refreshClaude(force: true)
        #expect(transport.requests.count == 2) // forced still skips the 429 backoff

        let again = FakeTransport([Hosts.anthropic: [.json("{}", status: 429), .claudeUsage]])
        let other = try Rig(transport: again)
        await other.services.refreshClaude()
        other.clock.advance(299)
        await other.services.refreshClaude()
        #expect(again.requests.count == 1)
        other.clock.advance(1)
        await other.services.refreshClaude()
        #expect(again.requests.count == 2 && other.store.claudeError == nil)
    }

    // MARK: Grok 401 pause

    @Test func grok401RecoveredDoesNotPause() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized, .grokBilling]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshGrok()
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil && rig.runner.calls.count == 1)
        await rig.services.refreshGrok()

        #expect(transport.requests.count == 3)
    }

    @Test func grokStillRejectedPausesEveryTrigger() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized, .unauthorized, .grokBilling]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshGrok()
        #expect(rig.store.grokFailure == .authRejected(.succeeded))
        #expect(transport.requests.count == 2 && rig.runner.calls.count == 1)
        let reads = rig.auth.reads

        rig.clock.advance(ProviderServices.grokAuthPause - 1)
        await rig.everyGrokTrigger()

        #expect(transport.requests.count == 2 && rig.auth.reads == reads && rig.runner.calls.count == 1)
        #expect(rig.store.grokFailure == .authRejected(.succeeded) && rig.store.grokPlan == nil)
        #expect(GrokSection.select(rig.store) == .failure(.authRejected(.succeeded)))
        #expect(GrokError.authRejected(.succeeded).guidance.contains("10 min"))

        rig.clock.advance(1)
        await rig.services.refreshGrok()
        #expect(transport.requests.count == 3 && rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil)
        await rig.services.refreshGrok() // cleared by the success
        #expect(transport.requests.count == 4)
    }

    /// The `grok models` throttle is separate from the pause and still limits runs to one per 10 minutes.
    @Test func grokCLIThrottleIntact() async throws {
        let transport = FakeTransport([Hosts.grok: [.unauthorized, .grokBilling, .unauthorized, .unauthorized, .unauthorized]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshGrok() // 401, `grok models`, recovered
        #expect(rig.runner.calls.count == 1 && rig.store.grokFailure == nil)

        rig.clock.advance(120)
        await rig.services.refreshGrok() // 401, throttled (no run), 401: rejected, paused
        #expect(rig.runner.calls.count == 1 && rig.store.grokFailure == .authRejected(.succeeded))
        #expect(transport.requests.count == 4)

        rig.clock.advance(ProviderServices.grokAuthPause)
        await rig.services.refreshGrok() // pause and throttle both over: one new run
        #expect(rig.runner.calls.count == 2 && transport.requests.count == 6)
    }

    @Test(arguments: [(FakeTransport.Response.json("{}", status: 403), GrokError.accessDenied(403)),
                      (.json("{}", status: 404), .endpointUnavailable), (.json("{}", status: 429), .rateLimited),
                      (.json("{}", status: 500), .serverError(500)), (.timeout, .network)])
    func otherGrokFailuresKeepTheirClassAndDontPause(_ response: FakeTransport.Response, _ expected: GrokError) async throws {
        let transport = FakeTransport([Hosts.grok: [response]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshGrok()
        #expect(rig.store.grokFailure == expected)
        await rig.services.refreshGrok()

        #expect(transport.requests.count == 2 && rig.runner.calls.isEmpty)
    }

    @Test(arguments: [403, 404, 500])
    func otherClaudeFailuresDontPause(_ status: Int) async throws {
        let transport = FakeTransport([Hosts.anthropic: [.json("{}", status: status)]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshClaude()
        #expect(rig.store.claudeError == "HTTP \(status)")
        await rig.services.refreshClaude()

        #expect(transport.requests.count == 2)
    }

    // MARK: Consent, visibility and stale results

    /// During a pause, consent off or a hidden gauge still means nothing is collected or shown.
    @Test func pauseNeverOverridesConsentOrSwitch() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.unauthorized], Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()
        await rig.services.refreshGrok()
        let requests = transport.requests.count

        rig.services.setClaudeLimitsEnabled(false)
        rig.services.setGrokEnabled(false)
        await rig.services.refreshClaude(force: true)
        await rig.services.refreshGrok()
        #expect(rig.store.claudeError == nil && !rig.store.claudeAvailable)
        #expect(rig.store.grokFailure == nil && GrokSection.select(rig.store) == nil)

        rig.services.setClaudeLimitsEnabled(true)
        rig.services.setGrokEnabled(true)
        await rig.show(.claude, false)
        await rig.show(.grok, false)
        await rig.services.refreshClaude(force: true)
        await rig.services.refreshGrok()
        #expect(rig.store.claudeError == nil && rig.store.grokFailure == nil)
        #expect(GrokSection.select(rig.store) == .paused)

        #expect(transport.requests.count == requests && !rig.store.claudeQuotaShown && !rig.store.grokQuotaShown)
    }

    /// Switch or consent turned off and on while the 401 is in flight: the late 401 publishes nothing and starts no pause.
    @Test(arguments: [false, true])
    func lateClaude401AfterOffOnStartsNoPause(consent: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let inFlight = Task { await rig.services.refreshClaude() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        if consent {
            rig.services.setClaudeLimitsEnabled(false)
            rig.services.setClaudeLimitsEnabled(true)
        } else {
            rig.box.preferences.set(false, forKey: Prefs.showClaude)
            rig.services.recordQuotaShown(.claude, false)
            rig.box.preferences.set(true, forKey: Prefs.showClaude)
            rig.services.recordQuotaShown(.claude, true)
        }
        #expect(transport.respond(.unauthorized))
        #expect(await transport.join(inFlight))
        #expect(rig.store.claudeError == nil)

        let next = Task { await rig.services.refreshClaude() }
        #expect(await transport.awaitRequests(2, from: next), "a stale 401 paused Claude")
        #expect(transport.respond(.claudeUsage))
        #expect(await transport.join(next))
        #expect(rig.store.claudeLimits?.session?.percent == 42)
    }

    @Test(arguments: [false, true])
    func lateGrokRejectionAfterOffOnStartsNoPause(consent: Bool) async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let inFlight = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: inFlight) else { Issue.record("refresh never started a request"); return }
        #expect(transport.respond(.unauthorized))
        guard await transport.awaitRequests(2, from: inFlight) else { Issue.record("no retry after recovery"); return }
        if consent {
            rig.services.setGrokEnabled(false)
            rig.services.setGrokEnabled(true)
        } else {
            rig.box.preferences.set(false, forKey: Prefs.showGrok)
            rig.services.recordQuotaShown(.grok, false)
            rig.box.preferences.set(true, forKey: Prefs.showGrok)
            rig.services.recordQuotaShown(.grok, true)
        }
        #expect(transport.respond(.unauthorized))
        #expect(await transport.join(inFlight))
        #expect(rig.store.grokFailure == nil)

        let next = Task { await rig.services.refreshGrok() }
        #expect(await transport.awaitRequests(3, from: next), "a stale rejection paused Grok")
        #expect(transport.respond(.grokBilling))
        #expect(await transport.join(next))
        #expect(rig.store.grokPlan?.percent == 10)
    }

    /// Overlapping Claude refreshes (timer and manual): the newer one succeeds first, then the older one gets a 401.
    @Test func olderClaude401CannotPauseAfterNewerSuccess() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let first = Task { await rig.services.refreshClaude() }
        guard await transport.awaitRequests(1, from: first) else { Issue.record("first refresh never started a request"); return }
        let second = Task { await rig.services.refreshClaude(force: true) }
        guard await transport.awaitRequests(2, from: second) else { Issue.record("second refresh never started a request"); return }
        #expect(transport.respond(.claudeUsage, newest: true))
        #expect(await transport.join(second))
        #expect(transport.respond(.unauthorized))
        #expect(await transport.join(first))
        #expect(rig.store.claudeLimits?.session?.percent == 42 && rig.store.claudeError == nil)

        let next = Task { await rig.services.refreshClaude() }
        #expect(await transport.awaitRequests(3, from: next), "the older 401 paused Claude")
        transport.close()
        _ = await next.value
    }

    /// Same for Grok: the older refresh's 401 arrives after a newer success. Superseded, it stops before its recovery
    /// (no `grok models`, key re-read or retry) and doesn't pause.
    @Test func olderGrokRejectionCannotPauseAfterNewerSuccess() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let first = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: first) else { Issue.record("first refresh never started a request"); return }
        let second = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: second) else { Issue.record("second refresh never started a request"); return }
        #expect(transport.respond(.grokBilling, newest: true))
        #expect(await transport.join(second))
        let reads = rig.auth.reads
        #expect(transport.respond(.unauthorized))
        #expect(await transport.join(first), "the superseded refresh sent a retry")
        #expect(transport.started == 2 && rig.runner.calls.isEmpty && rig.auth.reads == reads)
        #expect(rig.store.grokPlan?.percent == 10 && rig.store.grokFailure == nil)

        let next = Task { await rig.services.refreshGrok() }
        #expect(await transport.awaitRequests(3, from: next), "the older rejection paused Grok")
        transport.close()
        _ = await next.value
    }

    /// #25 review: A is in flight; B starts later, is rejected after recovery and pauses Grok; then A's first 401
    /// arrives. A must not re-read the key, run `grok models` or retry during the pause.
    @Test func olderGrokRefreshCannotRetryDuringNewerPause() async throws {
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport)

        let a = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(1, from: a) else { Issue.record("A never started a request"); return }
        let b = Task { await rig.services.refreshGrok() }
        guard await transport.awaitRequests(2, from: b) else { Issue.record("B never started a request"); return }
        #expect(transport.respond(.unauthorized, newest: true)) // B's first request
        guard await transport.awaitRequests(3, from: b) else { Issue.record("B never retried after recovery"); return }
        #expect(transport.respond(.unauthorized, newest: true)) // B's retry: rejected, paused
        #expect(await transport.join(b))
        #expect(rig.store.grokFailure == .authRejected(.succeeded) && rig.runner.calls.count == 1)
        let reads = rig.auth.reads

        #expect(transport.respond(.unauthorized)) // A's first request, answered during B's pause
        #expect(await transport.join(a), "A sent a retry during the pause")

        #expect(transport.started == 3 && rig.auth.reads == reads && rig.runner.calls.count == 1)
        #expect(rig.store.grokFailure == .authRejected(.succeeded))
        await rig.services.refreshGrok() // still paused
        #expect(transport.started == 3)
    }

    // MARK: Menu-bar gauge

    /// #25 review: limits kept through a 401 pause aren't drawn as current in the menu bar; the popover keeps them
    /// with the error and their fetch time.
    @Test func claudeGaugeBlankWhilePaused() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage, .unauthorized, .claudeUsage]])
        let rig = try Rig(transport: transport)

        await rig.services.refreshClaude()
        #expect(StatusRenderer.claudeGauge(rig.store) == [42, nil, nil])

        await rig.services.refreshClaude()
        #expect(rig.store.claudeError?.contains("HTTP 401") == true && rig.store.claudeLimits?.session?.percent == 42)
        #expect(StatusRenderer.claudeGauge(rig.store) == [nil, nil, nil])

        rig.clock.advance(ProviderServices.claudeAuthPause - 1)
        await rig.services.refreshClaude()
        #expect(StatusRenderer.claudeGauge(rig.store) == [nil, nil, nil] && transport.requests.count == 2)

        rig.clock.advance(1)
        await rig.services.refreshClaude()
        #expect(rig.store.claudeError == nil && StatusRenderer.claudeGauge(rig.store) == [42, nil, nil])
    }

    @Test(arguments: [429, 500])
    func claudeGaugeBlankOnOtherErrors(_ status: Int) async throws {
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage, .json("{}", status: status)]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()
        await rig.services.refreshClaude(force: true)

        #expect(rig.store.claudeLimits != nil && StatusRenderer.claudeGauge(rig.store) == [nil, nil, nil])
    }

    // MARK: Isolation and local usage

    @Test func pausesAreIndependent() async throws {
        let claudeRejected = FakeTransport([Hosts.anthropic: [.unauthorized], Hosts.grok: [.grokBilling]])
        let a = try Rig(transport: claudeRejected)
        await a.services.refreshClaude()
        await a.services.refreshGrok()
        await a.services.refreshGrok()
        #expect(Self.count(claudeRejected, Hosts.anthropic) == 1 && Self.count(claudeRejected, Hosts.grok) == 2)
        #expect(a.store.grokFailure == nil && a.runner.calls.isEmpty)

        let grokRejected = FakeTransport([Hosts.anthropic: [.claudeUsage], Hosts.grok: [.unauthorized]])
        let b = try Rig(transport: grokRejected)
        await b.services.refreshGrok()
        await b.services.refreshClaude()
        await b.services.refreshClaude()
        #expect(Self.count(grokRejected, Hosts.grok) == 2 && Self.count(grokRejected, Hosts.anthropic) == 2)
        #expect(b.store.claudeError == nil && b.claude.reads == 2)
    }

    @Test func localUsageUnaffectedDuringPauses() async throws {
        let transport = FakeTransport([Hosts.anthropic: [.unauthorized], Hosts.grok: [.unauthorized]])
        let rig = try Rig(transport: transport)
        await rig.services.refreshClaude()
        await rig.services.refreshGrok()

        let usage = await refreshLedger(rig.services.ledger)
        rig.store.grokUsage = usage.grok

        #expect(usage.claude.today.tokens == 150)
        #expect(rig.store.localGrokUsage?.today.tokens == 150 && rig.store.localGrokUsage?.today.cost == 0.25)
    }
}
