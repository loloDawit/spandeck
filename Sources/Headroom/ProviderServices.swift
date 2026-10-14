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

    init(store: Store, env: AppEnvironment) {
        self.store = store
        pricing = Pricing(file: env.appSupport.appendingPathComponent("pricing.json"), transport: env.pricingTransport)
        ledger = Ledger(home: env.home, appSupport: env.appSupport, pricing: pricing)
        claudeClient = ClaudeLimitsClient(credentials: env.credentials, transport: env.providerTransport)
        grokClient = GrokClient(home: env.home, transport: env.providerTransport, runner: env.processRunner)
        preferences = env.preferences
        store.claudeLimitsEnabled = preferences.bool(forKey: Prefs.claudeLimits)
    }

    /// Claude plan limits need the Claude Code OAuth token from the Keychain and an unofficial endpoint,
    /// so they stay off until the user opts in (#15).
    var claudeLimitsEnabled: Bool { preferences.bool(forKey: Prefs.claudeLimits) }

    /// Records the user's choice. Turning it off clears what was shown and any backoff.
    @MainActor func setClaudeLimitsEnabled(_ on: Bool) {
        preferences.set(on, forKey: Prefs.claudeLimits)
        store.claudeLimitsEnabled = on
        guard !on else { return }
        store.claudeLimits = nil
        store.claudeError = nil
        store.claudeAvailable = false
        claudeBackoffUntil = .distantPast
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
        let result: Result<ClaudeLimits, Error>
        do { result = .success(try await claudeClient.fetch()) } catch { result = .failure(error) }
        // The user may have turned limits off while the request was in flight.
        guard claudeLimitsEnabled else { return }
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

    @MainActor func refreshGrok() async {
        do {
            store.grokPlan = try await grokClient.fetch()
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
