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
    /// Quitting stops the ledger and saves off the main thread (#86). Made at the first quit request.
    private var shutdown: ShutdownCoordinator?

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var sampleTimer: Timer?
    private var timers: [Timer] = []
    private var tick = 0
    private var currentInterval = 0.0
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

        startSampling()
        sample()
        refreshLimits()
        refreshUsage()
        timers = [
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refreshLimits() },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshUsage() },
        ]
        timers.forEach { $0.tolerance = 2 }

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

    /// #86: the ledger stops at its next checkpoint and saves on its own queue while AppKit keeps the event loop
    /// running; the quit goes ahead once that's done, or after the timeout. Quitting is never cancelled: a save that
    /// failed or didn't finish leaves the previous cache, and the next launch reads the rest from the transcripts.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Asked again after the reply: the ledger is already stopped and saved, so quit at once. Asked again while
        // the quit is under way: the one pending termination is resolved by the reply already registered, so no
        // second reply is registered (AppKit pairs one reply with one `.terminateLater`).
        if let shutdown { return shutdown.outcome == nil ? .terminateLater : .terminateNow }
        let ledger = ledger
        let shutdown = ShutdownCoordinator(stop: { done in ledger.requestStop(completion: done) })
        self.shutdown = shutdown
        shutdown.begin { outcome in
            if outcome == .failed || outcome == .timedOut {
                // No path, id or count: only that the usage cache wasn't saved, so the previous one is kept.
                NSLog("SpanDeck: usage cache not saved at quit (%@); the previous cache is kept", "\(outcome)")
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The ledger already stopped and saved (or timed out) in `applicationShouldTerminate`; nothing waits here.
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
        let windowStart = store.claudeLimits?.session?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) }
        Task { @MainActor in
            guard let lastActivity = await services.refreshUsage(windowStart: windowStart) else { return }
            keepAwake.agentActivity = lastActivity
            syncAwake()
        }
    }

    /// Settings ▸ Clear cached usage data, confirmed (R8). Usage is rebuilt from the transcripts right after.
    private func clearUsageCache() {
        Task { @MainActor in
            await services.clearUsageCache()
            refreshUsage()
        }
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
            updatePricing: { [weak self] in self?.updatePricing() },
            clearUsageCache: { [weak self] in self?.clearUsageCache() }))
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        // Drop the SwiftUI tree so nothing renders while the popover is hidden.
        popover.contentViewController = nil
        // A clear that wasn't confirmed is dropped, and its result is only shown while the popover is open (R8).
        store.usageCacheClearRequested = false
        if !store.usageCacheClearing { store.usageCacheResult = nil }
    }
}

// `--snapshot <folder>` (R10) is handled here, before the app delegate or any live service exists: debug builds
// render a synthetic store and exit, release builds refuse it. See `SnapshotMode`.
if let code = SnapshotMode.run(arguments: CommandLine.arguments) { exit(code) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
