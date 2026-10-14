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
    private var claudeBackoffUntil = Date.distantPast
    /// Bumped on every consent change, so a request started under an earlier choice can't publish its result.
    private var claudeConsentGeneration = 0
    private var grokConsentGeneration = 0

    init(store: Store, env: AppEnvironment) {
        self.store = store
        pricing = Pricing(file: env.appSupport.appendingPathComponent("pricing.json"), transport: env.pricingTransport)
        ledger = Ledger(home: env.home, appSupport: env.appSupport, pricing: pricing)
        claudeClient = ClaudeLimitsClient(credentials: env.credentials, transport: env.providerTransport)
        grokClient = GrokClient(home: env.home, credentials: env.grokCredentials, transport: env.providerTransport,
                                runner: env.processRunner)
        preferences = env.preferences
        store.claudeLimitsEnabled = preferences.bool(forKey: Prefs.claudeLimits)
        store.grokEnabled = preferences.bool(forKey: Prefs.grokCredits)
    }

    /// Grok credits need the Grok CLI's API key, its billing endpoint and possibly running `grok models`,
    /// so they stay off until the user opts in (#17). Local Grok usage files are read either way.
    var grokEnabled: Bool { preferences.bool(forKey: Prefs.grokCredits) }

    /// Records the user's choice. Turning it off clears shown plan data; any change resets the CLI refresh throttle.
    @MainActor func setGrokEnabled(_ on: Bool) {
        grokConsentGeneration += 1
        preferences.set(on, forKey: Prefs.grokCredits)
        store.grokEnabled = on
        store.grokConsentRequested = false
        grokClient.resetRefreshThrottle()
        guard !on else { return }
        store.grokPlan = nil
        store.grokError = nil
        store.grokAvailable = false
    }

    /// Applies the user's choice from the consent card or Settings. Enabling refreshes Grok only (#17).
    @MainActor func applyGrokChoice(_ on: Bool) async {
        setGrokEnabled(on)
        if on { await refreshGrok() }
    }

    /// Claude plan limits need the Claude Code OAuth token from the Keychain and an unofficial endpoint,
    /// so they stay off until the user opts in (#15).
    var claudeLimitsEnabled: Bool { preferences.bool(forKey: Prefs.claudeLimits) }

    /// Records the user's choice. Turning it off clears what was shown and any backoff.
    @MainActor func setClaudeLimitsEnabled(_ on: Bool) {
        claudeConsentGeneration += 1
        preferences.set(on, forKey: Prefs.claudeLimits)
        store.claudeLimitsEnabled = on
        guard !on else { return }
        store.claudeLimits = nil
        store.claudeError = nil
        store.claudeAvailable = false
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

    /// Fetches Claude plan limits if the user opted in, unless backing off after a 429. `force` (manual refresh,
    /// wake) skips the backoff but never the consent check. Not gated by the display toggle (#4, R3).
    @MainActor func refreshClaude(force: Bool = false) async {
        guard claudeLimitsEnabled else { return }
        guard force || Date() >= claudeBackoffUntil else { return }
        let generation = claudeConsentGeneration
        let result: Result<ClaudeLimits, Error>
        do { result = .success(try await claudeClient.fetch()) } catch { result = .failure(error) }
        // Drop the result if the user changed their choice while the request was in flight (even off and on again).
        guard claudeLimitsEnabled, generation == claudeConsentGeneration else { return }
        do {
            store.claudeLimits = try result.get()
            store.claudeError = nil
            store.claudeAvailable = true
        } catch ClientError.notConfigured {
            store.claudeAvailable = false
            store.claudeLimits = nil
        } catch {
            store.claudeAvailable = true
            store.claudeError = error.localizedDescription
            if case ClientError.http(429) = error { claudeBackoffUntil = Date().addingTimeInterval(300) }
        }
    }

    /// Fetches Grok credits if the user opted in. Not gated by the display toggle (#4, R3).
    @MainActor func refreshGrok() async {
        guard grokEnabled else { return }
        let generation = grokConsentGeneration
        let isCurrent = { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return self.grokEnabled && self.grokConsentGeneration == generation
        }
        let result: Result<GrokPlan, Error>
        do { result = .success(try await grokClient.fetch(stillAllowed: { await MainActor.run { isCurrent() } })) } catch { result = .failure(error) }
        // Drop the result if the user changed their choice while the request was in flight (even off and on again).
        guard isCurrent() else { return }
        do {
            store.grokPlan = try result.get()
            store.grokError = nil
            store.grokAvailable = true
        } catch ClientError.notConfigured {
            store.grokAvailable = false
            store.grokPlan = nil
        } catch {
            store.grokError = error.localizedDescription
        }
    }
}
