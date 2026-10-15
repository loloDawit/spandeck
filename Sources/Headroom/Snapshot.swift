import AppKit
import SwiftUI

enum BuildConfig {
    #if DEBUG
    static let isDebug = true
    #else
    static let isDebug = false
    #endif
}

/// `Headroom --snapshot <folder>` (R10): renders the menu-bar strip and the popover to PNG files, for screenshots and
/// UI checks, then exits. Debug builds only, and only from a synthetic store: the decision is made before the app
/// delegate exists, so a snapshot run never builds the live environment, scans transcripts, reads credentials, runs
/// the Grok CLI, makes requests, samples the system or touches login items. Release builds refuse the argument and
/// write nothing.
enum SnapshotMode {
    enum Decision: Equatable {
        case normal
        case snapshot(URL)
        case rejected(String)
    }

    static let releaseRefusal = "--snapshot is only available in debug builds. Nothing was written."
    static let missingFolder = "--snapshot needs an output folder: --snapshot <folder>. Nothing was written."

    static func decide(arguments: [String], debugBuild: Bool) -> Decision {
        guard let i = arguments.firstIndex(of: "--snapshot") else { return .normal }
        guard debugBuild else { return .rejected(releaseRefusal) }
        guard i + 1 < arguments.count, !arguments[i + 1].isEmpty, !arguments[i + 1].hasPrefix("-") else {
            return .rejected(missingFolder)
        }
        return .snapshot(URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL)
    }

    /// Handles a snapshot or rejected request and returns the process exit code, or nil for a normal launch.
    static func run(arguments: [String], debugBuild: Bool = BuildConfig.isDebug,
                    log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }) -> Int32? {
        switch decide(arguments: arguments, debugBuild: debugBuild) {
        case .normal:
            return nil
        case .rejected(let why):
            log(why)
            return 64 // EX_USAGE
        case .snapshot(let folder):
            #if DEBUG
            return MainActor.assumeIsolated { SnapshotRenderer.write(to: folder, log: log) }
            #else
            _ = folder
            log(releaseRefusal)
            return 64
            #endif
        }
    }
}

#if DEBUG
/// Renders the synthetic store. Nothing here reads the user's data; preferences are overridden in memory only.
@MainActor
enum SnapshotRenderer {
    static let fileNames = ["strip-light.png", "strip-dark.png", "popover.png"]

    static func write(to folder: URL, now: Date = Date(), log: (String) -> Void) -> Int32 {
        if let problem = SnapshotOutput.check(folder) {
            log("--snapshot: \(problem). Nothing was written.")
            return 73 // EX_CANTCREAT
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging(SnapshotFixture.preferences) { _, new in new },
                                   forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }

        guard let images = render(SnapshotFixture.store(now: now)) else {
            log("--snapshot: rendering failed. Nothing was written.")
            return 70 // EX_SOFTWARE
        }
        do {
            try SnapshotOutput.write(images, in: folder)
        } catch {
            log("--snapshot: couldn't write to \(folder.path): \(error). Nothing was written.")
            return 73
        }
        log("--snapshot: wrote \(images.map(\.name).joined(separator: ", ")) (synthetic data) to \(folder.path)")
        return 0
    }

    static func render(_ store: Store) -> [(name: String, data: Data)]? {
        var out: [(String, Data)] = []
        let strip = StatusRenderer.render(store)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let scale: CGFloat = 4
            let size = NSSize(width: strip.size.width * scale, height: strip.size.height * scale)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let look = NSAppearance(named: appearance) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            look.performAsCurrentDrawingAppearance {
                (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                strip.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
            out.append(("strip-\(name).png", png))
        }

        let view = PopoverView(store: store, actions: PopoverActions(
            refresh: {}, quit: {}, keepAwake: { _ in }, loginItem: SnapshotLoginItem(), setClaudeLimits: { _ in },
            setGrokCredits: { _ in }, quotaSwitchChanged: { _, _ in }, updatePricing: {}, clearUsageCache: {}))
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        out.append(("popover.png", png))
        return out
    }
}

/// Never registers anything; the Settings menu only reads `isEnabled`.
struct SnapshotLoginItem: LoginItemService {
    var isEnabled: Bool { false }
    func register() throws {}
    func unregister() throws {}
}

/// Synthetic data for snapshots. Every value is a constant or derived from `now`; model names say "example".
@MainActor
enum SnapshotFixture {
    static let preferences: [String: Any] = [
        Prefs.showCPU: true, Prefs.showGPU: true, Prefs.showMem: true, Prefs.showBattery: true,
        Prefs.showClaude: true, Prefs.showGrok: true, Prefs.interval: 1.0,
        Prefs.awakeForAgents: false, Prefs.awakeDisplay: false,
    ]
    static let claudeModels = ["claude-example-opus", "claude-example-sonnet"]
    static let grokModel = "grok-example"
    static let plan = "Example plan"

    static func store(now: Date) -> Store {
        let s = Store()
        func history(_ base: Double, _ swing: Double) -> [Point] {
            (0..<Store.historyLength).map { i in
                Point(id: i, t: now.addingTimeInterval(Double(i - Store.historyLength)),
                      v: base + swing * sin(Double(i) / 9))
            }
        }
        s.cpu = CPUSample(total: 23, user: 15, system: 8, cores: [31, 22, 18, 26, 12, 40, 9, 28])
        s.cpuHistory = history(23, 8)
        s.gpu = 12
        s.gpuHistory = history(12, 6)
        let gib: UInt64 = 1 << 30
        s.memory = MemSample(used: 18 * gib, total: 32 * gib, app: 12 * gib, wired: 3 * gib, compressed: 2 * gib,
                             cached: 6 * gib, swapUsed: 0, pressure: 1)
        s.memHistory = history(56, 3)
        s.battery = BatterySample(percent: 82, charging: false, pluggedIn: false, charged: false, minutesToEmpty: 340,
                                  minutesToFull: nil, watts: -7.5, adapterWatts: nil, cycles: 120, health: 96,
                                  temperature: 31)

        let session = LimitEntry(id: "session", name: "Session", percent: 42, resetsAt: now.addingTimeInterval(2 * 3600),
                                 window: 5 * 3600)
        let weekly = LimitEntry(id: "weekly", name: "Weekly", percent: 27, resetsAt: now.addingTimeInterval(4 * 86400),
                                window: 7 * 86400)
        s.claudeLimits = ClaudeLimits(session: session, weekly: weekly, model: nil, all: [session, weekly], plan: plan,
                                      fetchedAt: now)
        s.claudeLimitsEnabled = true
        s.claudeAvailable = true
        s.grokEnabled = true
        s.grokAvailable = true
        s.grokPlan = GrokPlan(percent: 18, periodStart: now.addingTimeInterval(-10 * 86400),
                              periodEnd: now.addingTimeInterval(20 * 86400), periodName: "Monthly",
                              products: [(name: "Example product", percent: 18)], fetchedAt: now)

        s.claudeUsage = usage(now: now, models: claudeModels, perDay: [420_000, 180_000], price: 4e-6, window: true)
        s.grokUsage = usage(now: now, models: [grokModel], perDay: [60_000], price: 2e-6, window: false)
        s.usageUpdated = now
        s.pricing = PricingInfo(source: .bundled, revision: PricingSnapshot.pin.revision, retrieved: PricingSnapshot.retrieved)
        return s
    }

    /// Fourteen days of steady usage, the same every day.
    private static func usage(now: Date, models: [String], perDay: [Int], price: Double, window: Bool) -> UsageSummary {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var s = UsageSummary(monthStart: cal.date(byAdding: .day, value: -29, to: today)!)
        if window { s.window = Totals() }
        for d in 0..<14 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            for (model, tokens) in zip(models, perDay) {
                let cost = CostEstimate(known: Double(tokens) * price, knownTokens: tokens)
                s.bars.append(DayBar(day: day, family: modelFamily(model), tokens: tokens, cost: cost))
                s.month.tokens += tokens; s.month.cost += cost
                if d < 7 { s.week.tokens += tokens; s.week.cost += cost }
                if d == 0 {
                    s.today.tokens += tokens; s.today.cost += cost
                    if window { s.window!.tokens += tokens / 2; s.window!.cost += CostEstimate(known: cost.known / 2, knownTokens: tokens / 2) }
                }
            }
        }
        s.bars.sort { ($0.day, $0.family) < ($1.day, $1.family) }
        s.models = zip(models, perDay).map { model, tokens in
            ModelRow(model: model, tokens: tokens * 14, cost: CostEstimate(known: Double(tokens * 14) * price, knownTokens: tokens * 14))
        }
        return s
    }
}

/// The output folder must already exist as a real folder (not a symlink), and is never created or chmodded. Images
/// go to temporary files first (O_EXCL, O_NOFOLLOW) and are renamed into place only once all were written, so a
/// failure leaves nothing behind and a symlink at a file name is replaced, never followed.
enum SnapshotOutput {
    static func check(_ folder: URL) -> String? {
        var st = stat()
        guard lstat(folder.path, &st) == 0 else { return "the output folder doesn't exist (\(String(cString: strerror(errno))))" }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "the output path is a link or not a folder" }
        guard access(folder.path, W_OK | X_OK) == 0 else { return "the output folder isn't writable" }
        return nil
    }

    static func write(_ files: [(name: String, data: Data)], in folder: URL) throws {
        var temps: [(temp: String, final: String)] = []
        var done = false
        defer { if !done { temps.forEach { unlink($0.temp) } } }
        for file in files {
            let temp = folder.appendingPathComponent(".\(file.name).tmp-\(UUID().uuidString)").path
            let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            temps.append((temp, folder.appendingPathComponent(file.name).path))
            let ok = file.data.withUnsafeBytes { buf -> Bool in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    offset += n
                }
                return true
            }
            let code = errno
            close(fd)
            guard ok else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        for t in temps {
            guard rename(t.temp, t.final) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        done = true
    }
}
#endif
