import Foundation

// MARK: - Claude plan limits

struct LimitEntry: Identifiable {
    var id: String
    var name: String
    var percent: Double
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
        case .http(401): return "Token expired, will retry"
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
            "User-Agent": "claude-code/2.1 headroom",
        ], via: transport)

        var result = ClaudeLimits(all: [], plan: creds.plan, fetchedAt: Date())
        let limits = json["limits"] as? [[String: Any]] ?? []
        let shares = json["weekly_scoped_shares"] as? [[String: Any]] ?? []

        for (i, l) in limits.enumerated() {
            let kind = l.string("kind") ?? "limit"
            let scopeName = l.dict("scope")?.dict("model")?.string("display_name")
                ?? l.dict("scope")?.dict("surface")?.string("display_name")
            var entry = LimitEntry(id: "\(kind)-\(i)", name: kind, percent: l.double("percent") ?? 0,
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
                if let share = shares.first(where: { $0.int("limit_index") == i }),
                   let used = share.double("used_percent_of_weekly"), let allow = share.double("allowance_percent_of_weekly") {
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
            let e = LimitEntry(id: "five_hour", name: "Session (5h)", percent: fh.double("utilization") ?? 0,
                               resetsAt: ISO.parse(fh.string("resets_at")), window: 5 * 3600)
            result.session = e
            result.all.insert(e, at: 0)
        }
        if result.weekly == nil, let sd = json.dict("seven_day") {
            let e = LimitEntry(id: "seven_day", name: "Weekly", percent: sd.double("utilization") ?? 0,
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
    var products: [(name: String, percent: Double)]
    var fetchedAt: Date
}

/// Reads Grok credit usage with the token the grok CLI stores in ~/.grok/auth.json.
/// When the token has expired, `grok models` is run once to let the CLI refresh it
/// (the CLI owns the file and its lock; this client never writes it).
final class GrokClient {
    private let grokHome: URL
    private let transport: HTTPTransport
    private let runner: ProcessRunner
    private var lastRefresh: Date?

    init(home: URL, transport: HTTPTransport, runner: ProcessRunner) {
        self.grokHome = home.appendingPathComponent(".grok")
        self.transport = transport
        self.runner = runner
    }

    private func auth() -> (key: String, expires: Date?)? {
        guard let data = try? Data(contentsOf: grokHome.appendingPathComponent("auth.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for case let entry as [String: Any] in json.values {
            if let key = entry.string("key"), !key.isEmpty { return (key, ISO.parse(entry.string("expires_at"))) }
        }
        return nil
    }

    private func refreshToken() async {
        if let last = lastRefresh, Date().timeIntervalSince(last) < 600 { return }
        lastRefresh = Date()
        let bin = grokHome.appendingPathComponent("bin/grok").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        let runner = runner
        await Task.detached(priority: .utility) {
            // Exit status is ignored, so a failed refresh later surfaces as "not configured" (#4, R5).
            _ = runner.run(bin, ["models"], timeout: 45, captureOutput: false)
        }.value
    }

    func fetch() async throws -> GrokPlan {
        guard var a = auth() else { throw ClientError.notConfigured }
        if let exp = a.expires, exp < Date().addingTimeInterval(60) {
            await refreshToken()
            a = auth() ?? a
        }
        do {
            return try await request(a.key)
        } catch ClientError.http(401) {
            await refreshToken()
            guard let fresh = auth() else { throw ClientError.notConfigured }
            do {
                return try await request(fresh.key)
            } catch ClientError.http(let code) where [401, 402, 403, 404].contains(code) {
                // Logged in but no plan with billing access.
                throw ClientError.notConfigured
            }
        } catch ClientError.http(let code) where [402, 403, 404].contains(code) {
            throw ClientError.notConfigured
        }
    }

    private func request(_ key: String) async throws -> GrokPlan {
        let json = try await getJSON(URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
            "User-Agent": "grok-cli headroom",
        ], via: transport)
        guard let c = json.dict("config") else { throw ClientError.badResponse }
        let period = c.dict("currentPeriod")
        let type = (period?.string("type") ?? "").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "").lowercased()
        let products = (c["productUsage"] as? [[String: Any]] ?? []).compactMap { p -> (String, Double)? in
            guard let n = p.string("product") else { return nil }
            return (n, p.double("usagePercent") ?? 0)
        }
        return GrokPlan(percent: c.double("creditUsagePercent") ?? 0,
                        periodStart: ISO.parse(period?.string("start") ?? c.string("billingPeriodStart")),
                        periodEnd: ISO.parse(period?.string("end") ?? c.string("billingPeriodEnd")),
                        periodName: type.isEmpty ? "period" : type,
                        products: products, fetchedAt: Date())
    }
}
