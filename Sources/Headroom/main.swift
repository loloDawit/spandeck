import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = Store()
    private let sampler = SystemSampler()
    /// Lazy so the live environment (and its Application Support mkdir) is built during launch, as before.
    private lazy var env = AppEnvironment.live
    private lazy var services = ProviderServices(store: store, env: env)
    private var ledger: Ledger { services.ledger }
    private let keepAwake = KeepAwake()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var sampleTimer: Timer?
    private var timers: [Timer] = []
    private var tick = 0
    private var ledgerBusy = false
    private var currentInterval = 0.0
    private var snapshotDir: URL?
    private var hover: HoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            hover = HoverController(store: store, button: button)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        services.start()

        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshotDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }

        startSampling()
        sample()
        refreshLimits()
        refreshUsage()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshLimits() },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshUsage() },
        ]
        timers.forEach { $0.tolerance = 2 }
        if snapshotDir != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.writeSnapshots() }
        }

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if Prefs.sampleInterval != currentInterval { startSampling() }
            syncAwake()
            redraw()
            // Best-effort catch-up for switch changes made outside the Settings menu; a no-op if nothing changed.
            applyQuotaVisibility()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLimits()
            self?.refreshUsage()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ledger.flush()
        keepAwake.release()
    }

    // MARK: Sampling

    private func startSampling() {
        sampleTimer?.invalidate()
        currentInterval = Prefs.sampleInterval
        let t = Timer(timeInterval: currentInterval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = currentInterval * 0.1
        RunLoop.main.add(t, forMode: .common)
        sampleTimer = t
    }

    private func sample() {
        store.record(cpu: sampler.cpu(), gpu: sampler.gpu(), memory: sampler.memory())
        // Battery changes slowly and reading the smart battery registry is the costliest probe.
        if tick % max(1, Int(5 / currentInterval)) == 0 { store.battery = sampler.battery() }
        tick += 1
        syncAwake()
        redraw()
    }

    private func redraw() {
        statusItem.button?.image = StatusRenderer.render(store)

    }

    // MARK: Limits and usage

    private func refreshLimits(force: Bool = false) {
        Task { @MainActor in
            await services.refreshClaude(force: force)
            redraw()
        }
        Task { @MainActor in
            await services.refreshGrok()
            redraw()
        }
    }

    /// Called by the Settings switch on the main thread right after it writes the preference (#19). The change is
    /// recorded before this returns, so in-flight results are invalidated even if the switch goes back on at once;
    /// only the resume refresh runs later.
    private func quotaSwitchChanged(_ provider: ProviderServices.QuotaSwitch, _ on: Bool) {
        let resume = MainActor.assumeIsolated { services.recordQuotaShown(provider, on) }
        redraw()
        guard resume else { return }
        Task { @MainActor in
            await services.resumeQuota(provider)
            redraw()
        }
    }

    /// Explicit price download from the popover (R6). Usage is recomputed with the new prices once it succeeds.
    private func updatePricing() {
        Task { @MainActor in
            await services.updatePricing()
            refreshUsage()
        }
    }

    /// Catches switch changes made outside the Settings menu (best effort, see `ProviderServices.applyQuotaVisibility`).
    private func applyQuotaVisibility() {
        Task { @MainActor in
            await services.applyQuotaVisibility()
            redraw()
        }
    }

    private func setClaudeLimits(_ on: Bool) {
        Task { @MainActor in
            await services.applyClaudeLimitsChoice(on)
            redraw()
        }
    }

    private func setGrokCredits(_ on: Bool) {
        Task { @MainActor in
            await services.applyGrokChoice(on)
            redraw()
        }
    }

    private func refreshUsage() {
        guard !ledgerBusy else { return }
        ledgerBusy = true
        let windowStart = store.claudeLimits?.session?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) }
        ledger.refresh(windowStart: windowStart, progress: { [weak self] msg in
            DispatchQueue.main.async { self?.store.indexing = msg }
        }, completion: { [weak self] claude, grok, lastActivity in
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.claudeUsage = claude
                self.store.grokUsage = grok
                self.store.usageUpdated = Date()
                self.ledgerBusy = false
                self.keepAwake.agentActivity = lastActivity
                self.syncAwake()
            }
        })
    }

    // MARK: Keep awake

    private func setAwake(_ session: AwakeSession) {
        keepAwake.set(session)
        syncAwake()
        redraw()
    }

    /// Mirrors the assertion state into the store, publishing only on change so the popover is not re-rendered.
    private func syncAwake() {
        keepAwake.update()
        let until = keepAwake.manual ? keepAwake.until : nil
        if store.awakeUntil != until { store.awakeUntil = until }
        if store.awakeForAgents != keepAwake.agentsWorking { store.awakeForAgents = keepAwake.agentsWorking }
    }

    // MARK: Popover

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        // Option-click toggles keep awake without opening the dashboard.
        // Read the live key state: the status item may be hosted outside the app, so the current event can lack modifiers.
        if NSEvent.modifierFlags.contains(.option) {
            setAwake(keepAwake.manual ? .off : .indefinitely)
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        hover?.hide()
        let view = PopoverView(store: store, actions: PopoverActions(
            refresh: { [weak self] in
                self?.refreshLimits(force: true)
                self?.refreshUsage()
            },
            quit: { NSApp.terminate(nil) },
            keepAwake: { [weak self] in self?.setAwake($0) },
            loginItem: env.loginItem,
            setClaudeLimits: { [weak self] on in self?.setClaudeLimits(on) },
            setGrokCredits: { [weak self] on in self?.setGrokCredits(on) },
            quotaSwitchChanged: { [weak self] provider, on in self?.quotaSwitchChanged(provider, on) },
            updatePricing: { [weak self] in self?.updatePricing() }))
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree so nothing renders while the popover is hidden.
        popover.contentViewController = nil
    }
}

// MARK: - Snapshot mode (`Headroom --snapshot <dir>`): renders the strip and popover to PNGs, then exits.

extension AppDelegate {
    @MainActor fileprivate func writeSnapshots() {
        guard let dir = snapshotDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let strip = StatusRenderer.render(store)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let scale: CGFloat = 4
            let size = NSSize(width: strip.size.width * scale, height: strip.size.height * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                strip.draw(in: NSRect(origin: .zero, size: size))
            }
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("strip-\(name).png"))
        }
        print("strip width pt:", strip.size.width)

        let view = PopoverView(store: store, actions: PopoverActions(refresh: {}, quit: {}, keepAwake: { _ in }, loginItem: env.loginItem, setClaudeLimits: { _ in },
                                                              setGrokCredits: { _ in }, quotaSwitchChanged: { _, _ in },
                                                              updatePricing: {}))
            .background(Color(nsColor: NSColor(white: 0.13, alpha: 1)))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let cg = renderer.cgImage {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("popover.png"))
        }
        ledger.flush()
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
