import Foundation
import AppKit
import SwiftUI

struct Point: Identifiable {
    let id: Int
    let t: Date
    let v: Double
}

enum Prefs {
    static let showCPU = "show.cpu"
    static let showGPU = "show.gpu"
    static let showMem = "show.mem"
    static let showBattery = "show.battery"
    static let showClaude = "show.claude"
    static let showGrok = "show.grok"
    static let interval = "interval"
    static let awakeForAgents = "awake.agents"
    static let awakeDisplay = "awake.display"
    /// Consent to read the Claude Code login from the Keychain for plan limits (#15). Off unless the user enables it.
    static let claudeLimits = "claude.limits.enabled"
    /// Consent to read the Grok CLI's key, call its billing endpoint and run `grok models` (#17). Off by default.
    static let grokCredits = "grok.enabled"

    static func register() {
        UserDefaults.standard.register(defaults: [
            showCPU: true, showGPU: false, showMem: true, showBattery: false,
            showClaude: true, showGrok: true, interval: 1.0,
            awakeForAgents: false, awakeDisplay: false,
        ])
    }

    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static var sampleInterval: Double { max(0.5, UserDefaults.standard.double(forKey: interval)) }
}

enum Palette {
    static let cpu = NSColor(srgbRed: 0.33, green: 0.74, blue: 0.98, alpha: 1)
    static let gpu = NSColor(srgbRed: 0.69, green: 0.52, blue: 1.00, alpha: 1)
    static let mem = NSColor(srgbRed: 0.36, green: 0.85, blue: 0.60, alpha: 1)
    static let battery = NSColor(srgbRed: 0.98, green: 0.80, blue: 0.30, alpha: 1)
    static let claude = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let grok = NSColor(srgbRed: 0.62, green: 0.66, blue: 0.74, alpha: 1)

    static func severity(_ pct: Double?, base: NSColor) -> NSColor {
        guard let pct else { return base }
        return pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : base
    }

    static func familyColor(_ family: String, index: Int) -> Color {
        switch family {
        case "Opus": return Color(nsColor: claude)
        case "Fable": return Color(nsColor: gpu)
        case "Sonnet": return Color(nsColor: cpu)
        case "Haiku": return Color(nsColor: mem)
        case "Mythos": return Color(nsColor: battery)
        case "Grok": return Color(nsColor: grok)
        default:
            // Anything else (Grok models, older ids) gets a distinct color by position.
            let others: [NSColor] = [.systemTeal, .systemPink, .systemYellow, .systemIndigo]
            return Color(nsColor: others[index % others.count])
        }
    }
}

final class Store: ObservableObject {
    static let historyLength = 150

    @Published var cpu: CPUSample?
    @Published var cpuHistory: [Point] = []
    @Published var gpu: Double?
    @Published var gpuHistory: [Point] = []
    @Published var memory: MemSample?
    @Published var memHistory: [Point] = []
    @Published var battery: BatterySample?

    @Published var claudeLimits: ClaudeLimits?
    @Published var claudeError: String?
    @Published var claudeUsage: UsageSummary?
    /// Whether the user has opted in to Claude plan limits; mirrors `Prefs.claudeLimits`.
    @Published var claudeLimitsEnabled = false
    /// Whether the user has opted in to Grok credits; mirrors `Prefs.grokCredits`.
    @Published var grokEnabled = false
    /// Whether the menu-bar switch for each provider's quota is on; mirrors `Prefs.showClaude` / `Prefs.showGrok`.
    /// Off pauses that provider's quota polling (#19).
    @Published var claudeQuotaShown = true
    @Published var grokQuotaShown = true
    /// UI only: the user asked (from Settings) to see the Grok consent card.
    @Published var grokConsentRequested = false
    /// Claude starts hidden and appears once its account answers. For Grok: a plan (current or stale) is available.
    @Published var claudeAvailable = false
    @Published var grokAvailable = false
    @Published var grokPlan: GrokPlan?
    /// Why the last Grok refresh failed (#21); nil after a success. With a temporary failure `grokPlan` is the last
    /// good plan, shown as stale.
    @Published var grokFailure: GrokError?
    @Published var grokUsage: UsageSummary?
    @Published var indexing: String?
    @Published var usageUpdated: Date?
    /// Which prices cost estimates use (R6). Starts unavailable until `ProviderServices.start()` loads them.
    @Published var pricing = PricingInfo.unavailable
    /// The user's explicit price download: running, and why the last one failed.
    @Published var pricingUpdating = false
    @Published var pricingError: PricingUpdateError?
    /// Keep awake: end of the manual session (.distantFuture = indefinitely), and whether working agents hold it.
    @Published var awakeUntil: Date?
    @Published var awakeForAgents = false
    var awake: Bool { awakeUntil != nil || awakeForAgents }

    /// Grok token usage from local session files, shown whenever there is any. Independent of Grok credits
    /// consent (#17), which only covers the credential-based plan data.
    var localGrokUsage: UsageSummary? {
        guard let u = grokUsage, u.month.tokens > 0 else { return nil }
        return u
    }

    private var seq = 0

    func record(cpu c: CPUSample?, gpu g: Double?, memory m: MemSample?) {
        let now = Date()
        seq += 1
        if let c { cpu = c; append(&cpuHistory, Point(id: seq, t: now, v: c.total)) }
        if let g { gpu = g; append(&gpuHistory, Point(id: seq, t: now, v: g)) }
        if let m { memory = m; append(&memHistory, Point(id: seq, t: now, v: m.percent)) }
    }

    private func append(_ arr: inout [Point], _ p: Point) {
        arr.append(p)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }
}
