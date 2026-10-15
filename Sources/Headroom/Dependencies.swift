import Foundation
import ServiceManagement

// MARK: - Side-effect seams
//
// Everything that touches the Keychain, the network, child processes, login items or the user's home
// directory goes through these protocols, so tests can run the launch path against fakes.
// `AppEnvironment.live` is the only place the real implementations are created.

protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

protocol ProcessRunner: Sendable {
    /// Runs a binary and returns its exit status and stdout, or nil if it could not be launched.
    func run(_ path: String, _ args: [String], timeout: TimeInterval, captureOutput: Bool) -> (status: Int32, output: Data)?
}

struct SystemProcessRunner: ProcessRunner {
    func run(_ path: String, _ args: [String], timeout: TimeInterval, captureOutput: Bool) -> (status: Int32, output: Data)? {
        runProcess(path, args, timeout: timeout, captureOutput: captureOutput)
    }
}

protocol CredentialStore {
    /// The raw credential JSON Claude Code keeps in the login keychain, or nil if absent or unreadable.
    func claudeCredentialJSON() -> Data?
}

struct KeychainCredentialStore: CredentialStore {
    let runner: ProcessRunner
    func claudeCredentialJSON() -> Data? {
        guard let out = runner.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                                   timeout: 10, captureOutput: true),
              out.status == 0 else { return nil }
        return out.output
    }
}

protocol GrokCredentialSource {
    /// The raw contents of the Grok CLI's `~/.grok/auth.json`, or nil if absent or unreadable. Never written.
    func grokAuthJSON() -> Data?
}

struct GrokAuthFile: GrokCredentialSource {
    let home: URL
    func grokAuthJSON() -> Data? {
        try? Data(contentsOf: home.appendingPathComponent(".grok/auth.json"))
    }
}

protocol LoginItemService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

struct MainAppLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

protocol PreferenceStore: AnyObject {
    func bool(forKey key: String) -> Bool
    func set(_ value: Bool, forKey key: String)
    /// The stored value, or nil if never set (registered defaults count as set for `UserDefaults`).
    func object(forKey key: String) -> Any?
}

extension PreferenceStore {
    /// A switch whose meaning is "on unless the user turned it off", such as the menu-bar gauges.
    func bool(forKey key: String, default fallback: Bool) -> Bool { object(forKey: key) as? Bool ?? fallback }
}

extension UserDefaults: PreferenceStore {}

// MARK: - Environment

struct AppEnvironment {
    /// Provider quota endpoints (Anthropic, Grok).
    var providerTransport: HTTPTransport
    /// The explicit download of the pinned LiteLLM price file (R6); never used at launch.
    var pricingTransport: HTTPTransport
    var processRunner: ProcessRunner
    var credentials: CredentialStore
    var grokCredentials: GrokCredentialSource
    var loginItem: LoginItemService
    var preferences: PreferenceStore
    var home: URL
    var appSupport: URL
    /// Time source for retry pauses (Claude 401/429, Grok 401), the `grok models` throttle and the retrieval time of a
    /// price download, so tests can control time. Credential expiry checks still use the system clock.
    var now: @Sendable () -> Date = { Date() }

    /// How many live environments were made; snapshot tests check that a snapshot run makes none (R10).
    private(set) static var realEnvironmentsMade = 0

    static var live: AppEnvironment {
        realEnvironmentsMade += 1
        let providerSession: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            return URLSession(configuration: c)
        }()
        // No cookies or disk cache; a finite timeout. Only ever asked for the pinned price file.
        let pricingSession: URLSession = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.timeoutIntervalForResource = 60
            c.requestCachePolicy = .reloadIgnoringLocalCacheData
            c.httpCookieAcceptPolicy = .never
            c.httpShouldSetCookies = false
            return URLSession(configuration: c)
        }()
        let runner = SystemProcessRunner()
        return AppEnvironment(
            providerTransport: URLSessionTransport(session: providerSession),
            pricingTransport: URLSessionTransport(session: pricingSession),
            processRunner: runner,
            credentials: KeychainCredentialStore(runner: runner),
            grokCredentials: GrokAuthFile(home: homeDir),
            loginItem: MainAppLoginItem(),
            preferences: UserDefaults.standard,
            home: homeDir,
            appSupport: appSupportDir)
    }
}
