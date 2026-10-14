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
    }

    /// Loads prices, possibly starting a download (returned for tests). The login item is never registered here:
    /// launch at login is only enabled from Settings, and an existing registration is left as it is (#15).
    @discardableResult
    func start() -> Task<Void, Never>? {
        pricing.load()
    }

    /// Fetches Claude plan limits unless backing off after a 429. Not gated by the display toggle (#4, R3).
    @MainActor func refreshClaude(force: Bool = false) async {
        guard force || Date() >= claudeBackoffUntil else { return }
        do {
            store.claudeLimits = try await claudeClient.fetch()
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
