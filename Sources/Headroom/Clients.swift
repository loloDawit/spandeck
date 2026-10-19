import Foundation

/// How SpanDeck identifies itself to the provider quota endpoints (R9). It names this app and says the integration is
/// unofficial. It never names an official client, and carries no version (the bundle still reports upstream Headroom's),
/// user, machine, install or credential details. If a provider rejects it, the request fails like any other; there is
/// no fallback to another identity.
enum ProviderRequest {
    static let userAgent = "SpanDeck (unofficial quota monitor)"
}

// MARK: - Claude plan limits

struct LimitEntry: Identifiable {
    var id: String
    var name: String
    /// nil when the provider didn't report a usable percent (F-2, #4): unavailable, never 0%.
    var percent: Double?
    var resetsAt: Date?
    /// Length of the window, used to draw the pace marker.
    var window: TimeInterval?
    var note: String?
}

struct ClaudeLimits {
    var session: LimitEntry?
    var weekly: LimitEntry?
    var model: LimitEntry?
    var all: [LimitEntry]
    var plan: String?
    var fetchedAt: Date
}

// F-3 (#4, #7; METRIC_CONTRACT.md §3): a last-known percent describes its window only until that window resets. After
// the reset it says nothing about the new window, so it's unavailable until a refresh answers, never shown as current.
extension LimitEntry {
    /// This limit as it may be shown at `now`. `stale`: the last refresh failed, so this value is kept from an earlier
    /// one; a limit with no reset time has no proven window then, so it's unavailable too (contract §3, *Stale rule*).
    func current(at now: Date, stale: Bool) -> LimitEntry {
        let over = resetsAt.map { $0 <= now } ?? stale
        guard over, percent != nil else { return self }
        var e = self
        e.percent = nil
        e.note = LimitText.windowReset
        return e
    }
}

extension ClaudeLimits {
    func current(at now: Date, stale: Bool) -> ClaudeLimits {
        var l = self
        l.session = session?.current(at: now, stale: stale)
        l.weekly = weekly?.current(at: now, stale: stale)
        l.model = model?.current(at: now, stale: stale)
        l.all = all.map { $0.current(at: now, stale: stale) }
        return l
    }
}

extension GrokPlan {
    /// Whether this plan may still describe the billing period current at `now` (F-3). `stale`: kept through a failed
    /// refresh; without an end date its period is unproven then, so it isn't current (contract §3, *Stale rule*).
    func isCurrent(at now: Date, stale: Bool) -> Bool {
        periodEnd.map { now < $0 } ?? !stale
    }
}

enum ClientError: LocalizedError {
    case notLoggedIn(String)
    /// The tool is not installed or has no account; the UI hides that provider.
    case notConfigured
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notLoggedIn(let m): return m
        case .notConfigured: return "Not set up"
        // A 401 doesn't say why (expired, revoked or otherwise rejected), so the message doesn't guess (R9).
        case .http(401): return "Claude rejected the sign-in (HTTP 401); sign in again in Claude Code if this continues. Retrying every 5 min"
        case .http(429): return "Rate limited, backing off"
        case .http(let c): return "HTTP \(c)"
        case .badResponse: return "Unexpected response"
        }
    }
}

private func getJSON(_ url: URL, headers: [String: String], via transport: HTTPTransport) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    let (data, resp) = try await transport.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw ClientError.http(code) }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClientError.badResponse }
    return json
}

/// Reads plan limits with the OAuth token Claude Code keeps in the login keychain.
/// The token is never refreshed or stored here; Claude Code owns its rotation.
final class ClaudeLimitsClient {
    private struct Creds { var token: String; var expiresAt: Date?; var plan: String? }

    private let store: CredentialStore
    private let transport: HTTPTransport

    init(credentials: CredentialStore, transport: HTTPTransport) {
        self.store = credentials
        self.transport = transport
    }

    private func credentials() -> Creds? {
        guard let data = store.claudeCredentialJSON(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json.dict("claudeAiOauth"),
              let token = oauth.string("accessToken") else { return nil }
        let exp = oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return Creds(token: token, expiresAt: exp, plan: Self.planName(oauth.string("subscriptionType"), oauth.string("rateLimitTier")))
    }

    private static func planName(_ sub: String?, _ tier: String?) -> String? {
        guard let sub else { return nil }
        var name = sub.prefix(1).uppercased() + sub.dropFirst()
        if let tier, let r = tier.range(of: #"\d+x"#, options: .regularExpression) { name += " " + tier[r] }
        return name
    }

    func fetch() async throws -> ClaudeLimits {
        guard let creds = credentials() else { throw ClientError.notConfigured }
        if let exp = creds.expiresAt, exp < Date() { throw ClientError.notLoggedIn("Token expired, run Claude Code to refresh") }

        let json = try await getJSON(URL(string: "https://api.anthropic.com/api/oauth/usage")!, headers: [
            "Authorization": "Bearer \(creds.token)",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": ProviderRequest.userAgent,
        ], via: transport)

        var result = ClaudeLimits(all: [], plan: creds.plan, fetchedAt: Date())
        let limits = json["limits"] as? [[String: Any]] ?? []
        let shares = json["weekly_scoped_shares"] as? [[String: Any]] ?? []

        for (i, l) in limits.enumerated() {
            let kind = l.string("kind") ?? "limit"
            let scopeName = l.dict("scope")?.dict("model")?.string("display_name")
                ?? l.dict("scope")?.dict("surface")?.string("display_name")
            var entry = LimitEntry(id: "\(kind)-\(i)", name: kind, percent: l.percent("percent"),
                                   resetsAt: ISO.parse(l.string("resets_at")))
            switch kind {
            case "session":
                entry.name = "Session (5h)"
                entry.window = 5 * 3600
                result.session = entry
            case "weekly_all":
                entry.name = "Weekly"
                entry.window = 7 * 86400
                result.weekly = entry
            default:
                entry.name = "Weekly " + (scopeName ?? kind.replacingOccurrences(of: "_", with: " "))
                entry.window = kind.hasPrefix("weekly") ? 7 * 86400 : nil
                if let share = shares.first(where: { $0.optionalInt("limit_index") == i }),
                   let used = share.percent("used_percent_of_weekly"), let allow = share.percent("allowance_percent_of_weekly") {
                    entry.note = "\(Int(used))% of weekly used, \(Int(allow))% allowed"
                }
                if result.model == nil || scopeName?.localizedCaseInsensitiveContains("fable") == true {
                    result.model = entry
                }
            }
            result.all.append(entry)
        }

        // Older response shape without the `limits` array.
        if result.session == nil, let fh = json.dict("five_hour") {
            let e = LimitEntry(id: "five_hour", name: "Session (5h)", percent: fh.percent("utilization"),
                               resetsAt: ISO.parse(fh.string("resets_at")), window: 5 * 3600)
            result.session = e
            result.all.insert(e, at: 0)
        }
        if result.weekly == nil, let sd = json.dict("seven_day") {
            let e = LimitEntry(id: "seven_day", name: "Weekly", percent: sd.percent("utilization"),
                               resetsAt: ISO.parse(sd.string("resets_at")), window: 7 * 86400)
            result.weekly = e
            result.all.append(e)
        }
        return result
    }
}

// MARK: - Grok plan usage

struct GrokPlan {
    var percent: Double
    var periodStart: Date?
    var periodEnd: Date?
    var periodName: String
    /// A product's percent is nil when it wasn't reported usably (F-2, #4).
    var products: [(name: String, percent: Double?)]
    var fetchedAt: Date
}

/// Outcome of the most recent `grok models` run, used to explain a rejected login (#21). Exit status 0 doesn't prove
/// the key works; only a successful request does.
enum GrokRefresh: Equatable {
    case succeeded
    /// Non-zero exit, killed by the 45 s timeout, or couldn't be launched (nil).
    case failed(status: Int32?)
    /// No executable at `~/.grok/bin/grok`.
    case cliMissing
}

/// Why Grok credits couldn't be fetched (#21). Each case maps to one UI message; nothing here carries the key,
/// a response body or CLI output.
enum GrokError: Error, Equatable {
    /// `~/.grok/auth.json` is absent or unreadable.
    case notConfigured
    /// `~/.grok/auth.json` exists but isn't JSON or holds no non-empty `key`.
    case invalidCredentials
    /// Still 401 after the recovery attempt. nil: no `grok models` outcome is known.
    case authRejected(GrokRefresh?)
    /// HTTP 402 or 403. The response doesn't say why.
    case accessDenied(Int)
    /// HTTP 404.
    case endpointUnavailable
    case rateLimited
    case serverError(Int)
    /// The request didn't complete (offline, timeout, connection lost).
    case network
    /// HTTP 200 with a body that isn't the expected billing JSON.
    case unexpectedResponse
    /// Any other HTTP status.
    case http(Int)

    /// Failures expected to clear on their own; the last plan may be kept, labelled stale.
    var isTemporary: Bool {
        switch self {
        case .rateLimited, .serverError, .network: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .notConfigured: return "Grok CLI not signed in"
        case .invalidCredentials: return "Grok login unreadable"
        case .authRejected: return "Grok rejected the saved login"
        case .accessDenied(let code): return "Grok credits not available (HTTP \(code))"
        case .endpointUnavailable: return "Grok credits endpoint not found (HTTP 404)"
        case .rateLimited: return "Rate limited by Grok (HTTP 429)"
        case .serverError(let code): return "Grok service error (HTTP \(code))"
        case .network: return "Couldn't reach Grok"
        case .unexpectedResponse: return "Unexpected response from Grok"
        case .http(let code): return "Grok request failed (HTTP \(code))"
        }
    }

    var guidance: String {
        switch self {
        case .notConfigured:
            return "No login found in ~/.grok/auth.json. Sign in with the Grok CLI, then refresh."
        case .invalidCredentials:
            return "~/.grok/auth.json has no usable key. Sign in again with the Grok CLI."
        case .authRejected(let refresh):
            let why: String
            switch refresh {
            case .succeeded?: why = "`grok models` ran, but the key was still rejected."
            case .failed(let status?)?: why = "`grok models` couldn't refresh it (exit status \(status))."
            case .failed(nil)?: why = "`grok models` couldn't be run to refresh it."
            case .cliMissing?: why = "No Grok CLI at ~/.grok/bin/grok to refresh it."
            case nil: why = "The key was rejected."
            }
            return why + " Sign in again with the Grok CLI. Retrying every 10 min."
        case .accessDenied:
            return "The billing endpoint refused access; the response doesn't say why. It may depend on your account or plan."
        case .endpointUnavailable:
            return "The unofficial billing endpoint may have changed or isn't available for this account."
        case .rateLimited, .serverError:
            return "Temporary. Will retry on the next refresh."
        case .network:
            return "Check your connection. Will retry on the next refresh."
        case .unexpectedResponse:
            return "The unofficial billing endpoint may have changed."
        case .http:
            return "Will retry on the next refresh."
        }
    }
}

/// Reads Grok credit usage with the token the grok CLI stores in ~/.grok/auth.json.
/// When the token has expired or is rejected, `grok models` is run to let the CLI refresh it
/// (the CLI owns the file and its lock; this client never writes it).
final class GrokClient {
    private let grokHome: URL
    private let credentials: GrokCredentialSource
    private let transport: HTTPTransport
    private let runner: ProcessRunner
    private let refreshLock = NSLock()
    private let now: @Sendable () -> Date
    private var lastRefresh: Date?
    private var lastRefreshOutcome: GrokRefresh?

    /// A 401 before recovery; becomes `GrokError.authRejected` if recovery doesn't help.
    private struct Unauthorized: Error {}

    init(home: URL, credentials: GrokCredentialSource, transport: HTTPTransport, runner: ProcessRunner,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.grokHome = home.appendingPathComponent(".grok")
        self.credentials = credentials
        self.transport = transport
        self.runner = runner
        self.now = now
    }

    private func auth() throws -> (key: String, expires: Date?) {
        guard let data = credentials.grokAuthJSON() else { throw GrokError.notConfigured }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GrokError.invalidCredentials }
        for case let entry as [String: Any] in json.values {
            if let key = entry.string("key"), !key.isEmpty { return (key, ISO.parse(entry.string("expires_at"))) }
        }
        throw GrokError.invalidCredentials
    }

    /// Runs `grok models` at most once every 10 minutes. A throttled call reports the most recent run's outcome
    /// (nil if that run hasn't finished yet).
    private func refreshToken() async -> GrokRefresh? {
        let throttled: GrokRefresh?? = refreshLock.withLock {
            if let last = lastRefresh, now().timeIntervalSince(last) < 600 { return .some(lastRefreshOutcome) }
            lastRefresh = now()
            return .none
        }
        if case .some(let previous) = throttled { return previous }
        let bin = grokHome.appendingPathComponent("bin/grok").path
        let outcome: GrokRefresh
        if FileManager.default.isExecutableFile(atPath: bin) {
            let runner = runner
            // Output is never captured: it could contain account details. Only the exit status is kept.
            let result = await Task.detached(priority: .utility) {
                runner.run(bin, ["models"], timeout: 45, captureOutput: false)
            }.value
            outcome = result.map { $0.status == 0 ? .succeeded : .failed(status: $0.status) } ?? .failed(status: nil)
        } else {
            outcome = .cliMissing
        }
        refreshLock.withLock { lastRefreshOutcome = outcome }
        return outcome
    }

    /// `stillAllowed` is checked before every key read, every `grok models` run and immediately before every
    /// request, so withdrawing consent stops the fetch at the next step (#17). A request already sent can't be recalled.
    /// Throws `GrokError`, or `CancellationError` once `stillAllowed` is false.
    func fetch(stillAllowed: () async -> Bool) async throws -> GrokPlan {
        func checkAllowed() async throws { if !(await stillAllowed()) { throw CancellationError() } }
        try await checkAllowed()
        var a = try auth()
        if let exp = a.expires, exp < Date().addingTimeInterval(60) {
            try await checkAllowed()
            _ = await refreshToken()
            try await checkAllowed()
            // Keep the old key if the file can't be read now; the request decides.
            if let fresh = try? auth() { a = fresh }
        }
        do {
            try await checkAllowed()
            return try await request(a.key)
        } catch is Unauthorized {
            try await checkAllowed()
            let refresh = await refreshToken()
            try await checkAllowed()
            let fresh = try auth()
            do {
                try await checkAllowed()
                return try await request(fresh.key)
            } catch is Unauthorized {
                throw GrokError.authRejected(refresh)
            }
        }
    }

    private func request(_ key: String) async throws -> GrokPlan {
        var req = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
            "User-Agent": ProviderRequest.userAgent,
        ].forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await transport.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GrokError.network
        }
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401: throw Unauthorized()
        case let code where code == 402 || code == 403: throw GrokError.accessDenied(code)
        case 404: throw GrokError.endpointUnavailable
        case 429: throw GrokError.rateLimited
        case let code where (500...599).contains(code): throw GrokError.serverError(code)
        case let code: throw GrokError.http(code)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let c = json.dict("config") else { throw GrokError.unexpectedResponse }
        // A missing, non-numeric or out-of-range usage figure is a malformed answer, not 0% used (#21, F-2).
        guard let used = c.percent("creditUsagePercent") else { throw GrokError.unexpectedResponse }
        let period = c.dict("currentPeriod")
        let type = (period?.string("type") ?? "").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "").lowercased()
        let products = (c["productUsage"] as? [[String: Any]] ?? []).compactMap { p -> (String, Double?)? in
            guard let n = p.string("product") else { return nil }
            return (n, p.percent("usagePercent"))
        }
        return GrokPlan(percent: used,
                        periodStart: ISO.parse(period?.string("start") ?? c.string("billingPeriodStart")),
                        periodEnd: ISO.parse(period?.string("end") ?? c.string("billingPeriodEnd")),
                        periodName: type.isEmpty ? "period" : type,
                        products: products, fetchedAt: Date())
    }
}
