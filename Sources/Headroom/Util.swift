import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return String(format: "%.2fB", d / 1e9) }
        if d >= 1e6 { return String(format: "%.1fM", d / 1e6) }
        if d >= 1e3 { return String(format: "%.1fK", d / 1e3) }
        return "\(n)"
    }

    static func usd(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        // A real but tiny cost isn't shown as $0.00, which reads as free (R7).
        if v > 0 && v < 0.005 { return "<$0.01" }
        if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    /// A cost with its coverage (R7): "$4.25" when complete, "≥$4.25" when only part is known (the known part, plus
    /// any P9 minimum, is a lower bound), "~$4.25" when it's provisional because cache-write quantities disagree (P9,
    /// #58: no bound is claimed), "n/a" when none of it is known. No usage, or a cost that really is zero, is "$0.00".
    static func cost(_ c: CostEstimate) -> String {
        switch c.coverage {
        case .complete: return usd(c.known)
        case .partial: return c.isProvisional ? "~" + approximate(c.amount) : "≥" + lowerBound(c.amount)
        case .unavailable: return "n/a"
        }
    }

    /// `cost` in words, for VoiceOver: symbols like ≥ and ~ don't read well aloud.
    static func spokenCost(_ c: CostEstimate) -> String {
        switch c.coverage {
        case .complete: return usd(c.known)
        case .partial: return c.isProvisional ? "about \(approximate(c.amount)), provisional" : "at least \(lowerBound(c.amount))"
        case .unavailable: return "cost not available"
        }
    }

    /// The known part of a partial cost, rounded down so it stays a lower bound. Below a cent it keeps its first
    /// significant digit ("$0.003") instead of reading as $0.00.
    static func lowerBound(_ v: Double) -> String { significant(v, .down) }

    /// A provisional amount (P9, #58), rounded rather than rounded down since it isn't a bound, and kept to its first
    /// significant digit below a cent ("$0.0008") so the cache-write costs P9 deals in don't read as "<$0.01".
    static func approximate(_ v: Double) -> String { significant(v, .plain) }

    private static func significant(_ v: Double, _ mode: NSDecimalNumber.RoundingMode) -> String {
        // Rounds the value's decimal form in Decimal arithmetic: scaling the Double (v * 1000) can land on either
        // side of a decimal boundary, and nudging it up to compensate can show more than is known.
        func down(_ digits: Int, per unit: Decimal = 1) -> Double {
            var d = (Decimal(string: v.description, locale: Locale(identifier: "en_US_POSIX")) ?? 0) / unit, r = Decimal()
            NSDecimalRound(&r, &d, digits, mode)
            return NSDecimalNumber(decimal: r).doubleValue
        }
        if v >= 1000 { return String(format: "$%.1fk", down(1, per: 1000)) }
        if v >= 100 { return String(format: "$%.0f", down(0)) }
        if v >= 0.01 || v <= 0 { return String(format: "$%.2f", max(down(2), 0)) }
        // Grok reports in 1e-10 USD ticks, so 10 digits always keeps a reported amount.
        let digits = min(Int((-log10(v)).rounded(.up)), 10)
        return String(format: "$%.\(digits)f", down(digits))
    }

    /// Spelled out, for help text and accessibility. The unknown part may be a model without a price (Claude) or a
    /// turn the Grok CLI reported no cost for, so the wording doesn't say which.
    static func costDetail(_ c: CostEstimate) -> String {
        switch c.coverage {
        case .complete: return "\(usd(c.known)) estimated"
        case .partial:
            // Known, minimum and unknown parts are named apart (P9, #58); a minimum is never called known, and isn't
            // a minimum when quantities disagree.
            var parts = ["\(lowerBound(c.known)) known"]
            if c.minimumTokens > 0 {
                parts.append(c.isProvisional
                    ? "\(approximate(c.minimum)) more for \(tokens(c.minimumTokens)) cache-write tokens of unknown tier, if the "
                        + "logged cache-write totals are right"
                    : "at least \(lowerBound(c.minimum)) for \(tokens(c.minimumTokens)) cache-write tokens of unknown tier")
            }
            if c.unknownTokens > 0 { parts.append("cost unknown for \(tokens(c.unknownTokens)) tokens") }
            if c.disputedTokens > 0 {
                parts.append("cost unknown for \(tokens(c.disputedTokens)) provisional cache-write tokens")
            }
            return (c.isProvisional ? "Provisional estimate, not a lower bound: " : "Partial estimate: ")
                + parts.joined(separator: "; ")
        case .unavailable: return "Cost unavailable: cost unknown for \(tokens(c.unknownTokens.saturatingAdd(c.disputedTokens))) tokens"
        }
    }

    static func gb(_ b: UInt64) -> String {
        String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "--" }
        return "\(Int(v.rounded()))%"
    }

    static func until(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    static func ago(_ date: Date?) -> String {
        guard let date else { return "never" }
        let s = Int(-date.timeIntervalSinceNow)
        if s < 5 { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }

    static func duration(minutes m: Int) -> String {
        "\(m / 60):" + String(format: "%02d", m % 60)
    }
}

enum ISO {
    private static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parses ISO 8601 timestamps with any number of fractional digits and either Z or +hh:mm.
    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = frac.date(from: s) ?? plain.date(from: s) { return d }
        guard let dot = s.firstIndex(of: ".") else { return nil }
        let rest = s[s.index(after: dot)...]
        let end = rest.firstIndex(where: { !$0.isNumber }) ?? s.endIndex
        return plain.date(from: String(s[..<dot]) + String(s[end...]))
    }
}

let appSupportDir: URL = {
    let u = AppIdentity.applicationSupport(in: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    // Owner-only (0700), checked again before every cache write (R8). A failure is reported by the ledger, which then
    // keeps usage in memory only.
    try? PrivateDirectory(url: u).prepare()
    return u
}()

let homeDir = FileManager.default.homeDirectoryForCurrentUser

/// Runs a binary and returns its exit status and stdout. Kills it after `timeout` seconds.
@discardableResult
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 10, captureOutput: Bool = true) -> (status: Int32, output: Data)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if p.isRunning { p.terminate() }
    }
    let data = captureOutput ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

extension Dictionary where Key == String, Value == Any {
    func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    /// nil when the key is missing or not a number (JSON booleans are rejected), so absent data isn't read as 0.
    func optionalInt(_ k: String) -> Int? {
        guard let n = self[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }
    func double(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func string(_ k: String) -> String? { self[k] as? String }
}
