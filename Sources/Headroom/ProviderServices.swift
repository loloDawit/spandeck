import Foundation

/// Launch-time side effects and provider refreshes, split out of the app delegate so tests can drive them
/// against an `AppEnvironment` of fakes. Behavior matches the inherited Headroom launch path.
/// Refreshes run on the main actor because they publish to the `Store`.
final class ProviderServices {
    let store: Store
    let pricing: Pricing
    let ledger: Ledger
    private let claudeClient: ClaudeLimitsClient
    private let grokClient: GrokClient
    private let preferences: PreferenceStore
    private let now: @Sendable () -> Date
    private var claudeBackoffUntil = Date.distantPast
    /// R9: after a provider rejects the credential, no credential read or request until the pause ends. Unlike the 429
    /// backoff, `force` doesn't skip it and consent or switch changes don't clear it, so nothing resends a rejected
    /// credential sooner. Only a newer, current 401 sets it; a success clears it. Kept in memory only.
    static let claudeAuthPause: TimeInterval = 300
    /// Matches the `grok models` throttle (10 min), which stays separate.
    static let grokAuthPause: TimeInterval = 600
    private var claudeAuthPausedUntil = Date.distantPast
    private var grokAuthPause: (until: Date, failure: GrokError)?
    /// Counts Claude refreshes started; only the newest one may publish, so an older 401 can't pause collection after a
    /// newer success (R9).
    private var claudeRefreshesStarted = 0
    /// Bumped on every consent or menu-bar switch change, so a request started under an earlier choice can't publish its result.
    private var claudeConsentGeneration = 0
    private var grokConsentGeneration = 0
    /// Counts Grok refreshes started; only the newest one may publish, so an older response can't override it (#21).
    private var grokRefreshesStarted = 0
    /// Last applied state of the menu-bar switches, so only real changes pause or resume collection (#19).
    private var claudeShown: Bool
    private var grokShown: Bool

    init(store: Store, env: AppEnvironment) {
        self.store = store
        pricing = Pricing(file: env.appSupport.appendingPathComponent("pricing.json"), transport: env.pricingTransport)
        ledger = Ledger(home: env.home, appSupport: env.appSupport, pricing: pricing)
        claudeClient = ClaudeLimitsClient(credentials: env.credentials, transport: env.providerTransport)
        grokClient = GrokClient(home: env.home, credentials: env.grokCredentials, transport: env.providerTransport,
                                runner: env.processRunner, now: env.now)
        preferences = env.preferences
        now = env.now
        claudeShown = preferences.bool(forKey: Prefs.showClaude, default: true)
        grokShown = preferences.bool(forKey: Prefs.showGrok, default: true)
        store.claudeLimitsEnabled = preferences.bool(forKey: Prefs.claudeLimits)
        store.grokEnabled = preferences.bool(forKey: Prefs.grokCredits)
        store.claudeQuotaShown = claudeShown
        store.grokQuotaShown = grokShown
    }

    // MARK: Menu-bar switches (#19, R3)
    //
    // Consent (`claude.limits.enabled`, `grok.enabled`) is permission to use a provider's credential. The menu-bar
    // switches (`show.claude`, `show.grok`) decide whether that permission is used: hiding a gauge pauses its quota
    // polling, showing it again resumes polling only if consent was already given. Neither setting changes the other,
    // and neither affects local transcript usage.

    /// Whether Claude plan limits are collected: consent given and the gauge not hidden.
    var claudeCollecting: Bool { claudeLimitsEnabled && preferences.bool(forKey: Prefs.showClaude, default: true) }
    /// Whether Grok credits are collected: consent given and the gauge not hidden.
    var grokCollecting: Bool { grokEnabled && preferences.bool(forKey: Prefs.showGrok, default: true) }

    enum QuotaSwitch { case claude, grok }

    /// Records one switch change synchronously, as it happens. Every change bumps that provider's generation at once,
    /// so switching off and back on before anything else runs still drops requests already in flight. Hiding clears
    /// shown plan data. Returns true when the switch was just turned on; the caller then calls `resumeQuota`.
    @MainActor @discardableResult
    func recordQuotaShown(_ provider: QuotaSwitch, _ on: Bool) -> Bool {
        switch provider {
        case .claude:
            guard on != claudeShown else { return false }
            claudeShown = on
            claudeConsentGeneration += 1
            store.claudeQuotaShown = on
            if !on { clearClaude() }
        case .grok:
            guard on != grokShown else { return false }
            grokShown = on
            grokConsentGeneration += 1
            store.grokQuotaShown = on
            if !on { clearGrok() }
        }
        return on
    }

    /// One refresh after a switch was turned on. Collects only under existing consent; the Claude 429 backoff, the
    /// 401 pauses and the `grok models` throttle still apply.
    @MainActor func resumeQuota(_ provider: QuotaSwitch) async {
        switch provider {
        case .claude: await refreshClaude()
        case .grok: await refreshGrok()
        }
    }

    /// Best-effort catch-up for switch changes made outside the Settings menu (for example `defaults write`): compares
    /// the stored preferences with the last recorded state. It sees only the current value, so an off-and-on that
    /// happened entirely between two calls is not noticed; the Settings menu records each change itself.
    @MainActor func applyQuotaVisibility() async {
        let resumeClaude = recordQuotaShown(.claude, preferences.bool(forKey: Prefs.showClaude, default: true))
        let resumeGrok = recordQuotaShown(.grok, preferences.bool(forKey: Prefs.showGrok, default: true))
        if resumeClaude { await resumeQuota(.claude) }
        if resumeGrok { await resumeQuota(.grok) }
    }

    @MainActor private func clearClaude() {
        store.claudeLimits = nil
        store.claudeError = nil
        store.claudeAvailable = false
    }

    @MainActor private func clearGrok() {
        store.grokPlan = nil
        store.grokFailure = nil
        store.grokAvailable = false
    }

    /// Grok credits need the Grok CLI's API key, its billing endpoint and possibly running `grok models`,
    /// so they stay off until the user opts in (#17). Local Grok usage files are read either way.
    var grokEnabled: Bool { preferences.bool(forKey: Prefs.grokCredits) }

    /// Records the user's choice. Turning it off clears shown plan data. The `grok models` throttle is kept across
    /// changes, so toggling consent can't run the CLI more than once every 10 minutes.
    @MainActor func setGrokEnabled(_ on: Bool) {
        grokConsentGeneration += 1
        preferences.set(on, forKey: Prefs.grokCredits)
        store.grokEnabled = on
        store.grokConsentRequested = false
        guard !on else { return }
        clearGrok()
    }

    /// Applies the user's choice from the consent card or Settings. Enabling refreshes Grok only (#17).
    @MainActor func applyGrokChoice(_ on: Bool) async {
        setGrokEnabled(on)
        if on { await refreshGrok() }
    }

    /// Claude plan limits need the Claude Code OAuth token from the Keychain and an unofficial endpoint,
    /// so they stay off until the user opts in (#15).
    var claudeLimitsEnabled: Bool { preferences.bool(forKey: Prefs.claudeLimits) }

    /// Records the user's choice. Turning it off clears what was shown and any 429 backoff, but not a 401 pause.
    @MainActor func setClaudeLimitsEnabled(_ on: Bool) {
        claudeConsentGeneration += 1
        preferences.set(on, forKey: Prefs.claudeLimits)
        store.claudeLimitsEnabled = on
        guard !on else { return }
        clearClaude()
        claudeBackoffUntil = .distantPast
    }

    /// Applies the user's choice from the consent card or Settings. Enabling refreshes Claude only; it must not
    /// trigger other providers' credential reads (#15).
    @MainActor func applyClaudeLimitsChoice(_ on: Bool) async {
        setClaudeLimitsEnabled(on)
        if on { await refreshClaude(force: true) }
    }

    /// Loads prices, possibly starting a download (returned for tests). The login item is never registered here:
    /// launch at login is only enabled from Settings, and an existing registration is left as it is (#15).
    @discardableResult
    func start() -> Task<Void, Never>? {
        pricing.load()
    }

    /// Fetches Claude plan limits if the user opted in and the gauge isn't hidden, unless paused after a 401 or backing
    /// off after a 429. `force` (manual refresh, enabling consent) skips the 429 backoff only: never the 401 pause, the
    /// consent or the menu-bar switch check.
    @MainActor func refreshClaude(force: Bool = false) async {
        guard claudeCollecting else { return }
        guard now() >= claudeAuthPausedUntil else {
            // No Keychain read or request. Show the rejection again in case hiding or consent changes cleared it.
            store.claudeError = ClientError.http(401).localizedDescription
            store.claudeAvailable = true
            return
        }
        guard force || now() >= claudeBackoffUntil else { return }
        let generation = claudeConsentGeneration
        claudeRefreshesStarted += 1
        let refresh = claudeRefreshesStarted
        let result: Result<ClaudeLimits, Error>
        do { result = .success(try await claudeClient.fetch()) } catch { result = .failure(error) }
        // Drop the result if the user changed their choice while the request was in flight (even off and on again),
        // or if a newer refresh started meanwhile: that one publishes instead.
        guard claudeCollecting, generation == claudeConsentGeneration, refresh == claudeRefreshesStarted else { return }
        do {
            store.claudeLimits = try result.get()
            store.claudeError = nil
            store.claudeAvailable = true
            claudeAuthPausedUntil = .distantPast
        } catch ClientError.notConfigured {
            store.claudeAvailable = false
            store.claudeLimits = nil
        } catch {
            store.claudeAvailable = true
            store.claudeError = error.localizedDescription
            if case ClientError.http(429) = error { claudeBackoffUntil = now().addingTimeInterval(300) }
            if case ClientError.http(401) = error { claudeAuthPausedUntil = now().addingTimeInterval(Self.claudeAuthPause) }
        }
    }

    /// Fetches Grok credits if the user opted in and the gauge isn't hidden, unless paused after the key was still
    /// rejected following recovery (R9). Hiding it mid-fetch stops the fetch at its next step, like withdrawing consent.
    @MainActor func refreshGrok() async {
        guard grokCollecting else { return }
        if let pause = grokAuthPause, now() < pause.until {
            // No key read, `grok models` run or request. Show the rejection again in case hiding or consent cleared it.
            store.grokFailure = pause.failure
            store.grokPlan = nil
            store.grokAvailable = false
            return
        }
        let generation = grokConsentGeneration
        grokRefreshesStarted += 1
        let refresh = grokRefreshesStarted
        let isCurrent = { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return self.grokCollecting && self.grokConsentGeneration == generation
        }
        let result: Result<GrokPlan, Error>
        do { result = .success(try await grokClient.fetch(stillAllowed: { await MainActor.run { isCurrent() } })) } catch { result = .failure(error) }
        // Drop the result if the user changed their choice while the request was in flight (even off and on again),
        // or if a newer refresh started meanwhile: that one publishes instead.
        guard isCurrent(), refresh == grokRefreshesStarted else { return }
        switch result {
        case .success(let plan):
            store.grokPlan = plan
            store.grokFailure = nil
            store.grokAvailable = true
            grokAuthPause = nil
        case .failure(let error):
            // Every failure is shown; none hides Grok once the user opted in (#21). Only a temporary failure keeps
            // the last plan, which the UI labels stale.
            let failure = error as? GrokError ?? .unexpectedResponse
            store.grokFailure = failure
            if case .authRejected = failure { grokAuthPause = (now().addingTimeInterval(Self.grokAuthPause), failure) }
            if !failure.isTemporary {
                store.grokPlan = nil
                store.grokAvailable = false
            }
        }
    }
}
