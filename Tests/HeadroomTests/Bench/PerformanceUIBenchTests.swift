import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Headroom

/// #88 UI measurement: the main thread around the post-refresh publish (B2), with and without a popover view
/// hierarchy, and the popover's first render as a distribution over fresh processes (B11). `scripts/bench-ui.sh` runs
/// it, one mode per process, on a data folder that `PerformanceMemoryBenchTests` `gen` and `cold` prepared:
/// - `probe`: what the test process provides (a running main run loop; whether a hosting view updates by itself);
/// - `first`: a warm start through `ProviderServices.refreshUsage`, then the popover's first render in this process,
///   then `SPANDECK_BENCH_REOPEN` (default 20) re-opens, each a new view tree as `togglePopover` builds one.
///   `SPANDECK_BENCH_UI_FIRST` picks how the first render is made: `hosting` (an `NSHostingController` in a window
///   that is never shown, as the app's popover hosts it) or `image` (`ImageRenderer`, as #85 measured it);
/// - `publish`: refresh ticks with the popover closed (no view tree, as after `popoverDidClose`) and open (a tree in
///   a window that is never shown), with nothing new and with 10 new messages; sample ticks with it open; and a cold
///   scan with it open. It appends to the dataset, so it runs last.
///
/// **Main-thread hold** is measured from the main run loop: observers record each busy span, from waking
/// (`afterWaiting`, first) to going back to sleep (`beforeWaiting`, last). A span holds everything the main thread did
/// in between, including SwiftUI's update pass, which runs before the run loop sleeps. A probe view observing the same
/// store marks the spans in which SwiftUI re-evaluated views.
///
/// Synthetic data only: the dataset is `BenchDataset`'s and the system, limit and plan values are `SnapshotFixture`'s.
/// Preferences go in the volatile argument domain, as `--snapshot` does: nothing is written to the user's settings.
/// No app launch, no window shown on screen, no credential, no request.
@Suite(.serialized, .enabled(if: BenchDataset.uiMode != nil))
struct PerformanceUIBenchTests {
    private static let env = ProcessInfo.processInfo.environment

    @MainActor @Test func ui() async throws {
        let mode = try #require(BenchDataset.uiMode)
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging(SnapshotFixture.preferences) { _, new in new },
                                   forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let out = URL(fileURLWithPath: Self.env["SPANDECK_BENCH_OUT"] ?? NSTemporaryDirectory())
        if mode == "probe" {
            try Self.write(try await Self.probe(), to: out.appendingPathComponent("ui-probe.json"))
            return
        }
        let d = try #require(BenchDataset.selected)
        let root = URL(fileURLWithPath: try #require(Self.env["SPANDECK_BENCH_HOME"]))
        try #require(BenchDataset.isBenchDataFolder(root), "SPANDECK_BENCH_HOME must be <package>/.build/bench/data-<letters>")
        let box = try Sandbox()
        var e = box.environment(transport: FakeTransport())
        e.home = root.appendingPathComponent("home")
        e.appSupport = root.appendingPathComponent("support")
        var report: [String: Any] = ["dataset": d.name, "mode": mode]
        switch mode {
        case "first":
            let variant = Self.env["SPANDECK_BENCH_UI_FIRST"] ?? "hosting"
            try #require(["hosting", "image"].contains(variant))
            report["variant"] = variant
            report.merge(try await Self.first(env: e, variant: variant)) { a, _ in a }
            let tag = Self.env["SPANDECK_BENCH_UI_RUN"] ?? "0"
            try Self.write(report, to: out.appendingPathComponent("\(d.name)-ui-first-\(variant)-\(tag).json"))
        default: // publish
            report.merge(try await Self.publish(env: e, root: root)) { a, _ in a }
            try Self.write(report, to: out.appendingPathComponent("\(d.name)-ui-publish.json"))
        }
    }

    // MARK: Modes

    @MainActor static func probe() async throws -> [String: Any] {
        var out: [String: Any] = Self.runLoopFacts()
        let spans = RunLoopSpans()
        spans.start()
        defer { spans.stop() }
        let store = SnapshotFixture.store(now: Date())
        let host = NSHostingController(rootView: Color.clear.background(BodyProbe(store: store, spans: spans)))
        let window = Self.window()
        window.contentViewController = host
        host.view.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let bodies0 = spans.bodiesTotal
        store.usageUpdated = Date()
        out["view_needs_layout_right_after_a_publish"] = host.view.needsLayout
        out["bodies_right_after_a_publish"] = spans.bodiesTotal - bodies0
        try await Task.sleep(nanoseconds: 100_000_000)
        out["bodies_100ms_after_a_publish"] = spans.bodiesTotal - bodies0
        store.usageUpdated = Date(); store.usageCacheIssue = "synthetic"; store.indexing = "synthetic"
        try await Task.sleep(nanoseconds: 100_000_000)
        out["bodies_100ms_after_3_publishes_in_one_turn"] = spans.bodiesTotal - bodies0 - 1
        out["bodies_counted_inside_a_span"] = spans.bodiesInSpans
        out["window_visible"] = window.isVisible
        return out
    }

    /// A warm start with the popover closed, then the first render in this process, then re-opens.
    @MainActor static func first(env e: AppEnvironment, variant: String) async throws -> [String: Any] {
        let services = ProviderServices(store: Store(), env: e)
        services.start()
        Self.populate(services.store)
        let spans = RunLoopSpans()
        spans.start()
        spans.watch(services.store)
        defer { spans.stop() }
        let warm = try await Self.tick(services, spans: spans)
        try #require(services.store.claudeUsage != nil, "the warm start published no usage")
        var out: [String: Any] = ["warm_start": warm]
        let reopen = Int(Self.env["SPANDECK_BENCH_REOPEN"] ?? "") ?? 20
        let window = Self.window()
        switch variant {
        case "hosting":
            out["first"] = try await Self.open(services.store, in: window, spans: spans)
            var opens: [[String: Double]] = [], closes: [Double] = []
            for _ in 0..<reopen {
                closes.append(Self.ms { window.contentViewController = nil })
                try await Task.sleep(nanoseconds: 50_000_000)
                opens.append(try await Self.open(services.store, in: window, spans: spans))
            }
            out["reopen_total_ms"] = Bench.stats(opens.compactMap { $0["total_ms"] })
            out["reopen_layout_ms"] = Bench.stats(opens.compactMap { $0["layout_ms"] })
            out["reopen_deferred_max_span_ms"] = Bench.stats(opens.compactMap { $0["deferred_max_span_ms"] })
            out["close_ms"] = Bench.stats(closes)
        default:
            let actions = Self.actions()
            func render() -> Double {
                Self.ms { _ = ImageRenderer(content: PopoverView(store: services.store, actions: actions)).cgImage }
            }
            out["first"] = ["total_ms": render()]
            var again: [Double] = []
            for _ in 0..<reopen { again.append(render()) }
            out["reopen_total_ms"] = Bench.stats(again)
        }
        return out
    }

    @MainActor static func publish(env e: AppEnvironment, root: URL) async throws -> [String: Any] {
        let services = ProviderServices(store: Store(), env: e)
        services.start()
        let store = services.store
        Self.populate(store)
        let spans = RunLoopSpans()
        spans.start()
        spans.watch(store)
        defer { spans.stop() }
        var out: [String: Any] = [:]
        _ = try await Self.tick(services, spans: spans) // warm start, not reported here
        let ticks = Int(Self.env["SPANDECK_BENCH_TICKS"] ?? "") ?? 30
        let window = Self.window()
        var seq = 0
        func open() -> NSView {
            let host = NSHostingController(rootView: PopoverView(store: store, actions: Self.actions())
                .background(BodyProbe(store: store, spans: spans)))
            host.sizingOptions = .preferredContentSize
            window.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            return host.view
        }
        func series(_ name: String, newMessages: Int) async throws {
            if newMessages > 0 {
                // The first change after a start saves the whole cache (§4.3); take it untimed, as scenario 4 does.
                try BenchDataset.append(home: e.home, count: newMessages, now: Date(), seq: &seq)
                _ = try await Self.tick(services, spans: spans)
            }
            var xs: [[String: Double]] = []
            for _ in 0..<ticks {
                if newMessages > 0 { try BenchDataset.append(home: e.home, count: newMessages, now: Date(), seq: &seq) }
                xs.append(try await Self.tick(services, spans: spans))
            }
            out[name] = Self.collate(xs)
        }

        // Noise floor: the quiet main thread, popover closed, then open.
        out["quiet_closed"] = try await Self.quiet(spans)
        try await series("tick_closed_nothing_new", newMessages: 0)
        try await series("tick_closed_10_new", newMessages: 10)
        let view = open()
        try await Task.sleep(nanoseconds: 300_000_000)
        out["quiet_open"] = try await Self.quiet(spans)
        try await series("tick_open_nothing_new", newMessages: 0)
        try await series("tick_open_10_new", newMessages: 10)

        // The 1 s sample tick (`AppDelegate.sample`): three histories, the strip, with the popover open.
        var samples: [[String: Double]] = []
        let sampler = SystemSampler()
        _ = sampler.cpu()
        for _ in 0..<(2 * ticks) {
            let since = spans.mark()
            let t0 = DispatchTime.now().uptimeNanoseconds
            store.record(cpu: sampler.cpu(), gpu: sampler.gpu(), memory: sampler.memory())
            _ = StatusRenderer.render(store)
            let t1 = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: 150_000_000)
            var s = spans.summary(since: since)
            s["work_ms"] = Double(t1 - t0) / 1e6
            samples.append(s)
        }
        out["sample_tick_open"] = Self.collate(samples)

        // The same tick with the update pass forced in steps, to split it: the view graph and layout
        // (`layoutSubtreeIfNeeded`, where the hosting view applies the change), then drawing (`displayIfNeeded` and a
        // transaction flush). `residual_span_ms` is what the run loop still did afterwards.
        var forced: [[String: Double]] = []
        for _ in 0..<ticks {
            let since = spans.mark()
            let b0 = spans.bodiesTotal
            store.record(cpu: sampler.cpu(), gpu: sampler.gpu(), memory: sampler.memory())
            let t0 = DispatchTime.now().uptimeNanoseconds
            view.layoutSubtreeIfNeeded()
            let t1 = DispatchTime.now().uptimeNanoseconds
            let b1 = spans.bodiesTotal
            view.displayIfNeeded()
            CATransaction.flush()
            let t2 = DispatchTime.now().uptimeNanoseconds
            try await Task.sleep(nanoseconds: 150_000_000)
            let after = spans.spans(since: since).filter { $0.start > t2 }
            forced.append(["layout_ms": Double(t1 - t0) / 1e6, "display_ms": Double(t2 - t1) / 1e6,
                           "bodies_in_layout": Double(b1 - b0), "bodies_after": Double(spans.bodiesTotal - b1),
                           "residual_span_ms": after.map(\.ms).max() ?? 0])
        }
        out["sample_tick_open_forced"] = Self.collate(forced)

        // A cold scan with the popover open: indexing progress and the final publish, against a new support folder.
        let coldSupport = root.appendingPathComponent("support-ui-cold")
        try? FileManager.default.removeItem(at: coldSupport)
        try FileManager.default.createDirectory(at: coldSupport, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: coldSupport) }
        var ce = e
        ce.appSupport = coldSupport
        let cold = ProviderServices(store: store, env: ce)
        cold.start()
        let since = spans.mark()
        let indexing = IndexingCounter(store)
        let scan = await Bench.measure { _ = await cold.refreshUsage(windowStart: nil) }
        try await Task.sleep(nanoseconds: 300_000_000)
        var c = spans.summary(since: since)
        c["scan_wall_s"] = scan.wall
        c["indexing_publishes"] = Double(indexing.count)
        out["cold_scan_open"] = c
        out["cold_scan_spans_ms"] = Bench.stats(spans.spans(since: since).map(\.ms))
        withExtendedLifetime(indexing) {}

        window.contentViewController = nil
        return out
    }

    // MARK: Pieces

    /// One `refreshUsage`, then 200 ms for the update pass and the run loop to sleep. `publish_ms` is from the
    /// `claudeUsage` assignment to the return: the four assignments and what they run synchronously.
    /// `max_span_ms` is the longest main-thread busy span in the tick.
    @MainActor static func tick(_ services: ProviderServices, spans: RunLoopSpans) async throws -> [String: Double] {
        let since = spans.mark()
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = await services.refreshUsage(windowStart: nil)
        let t1 = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: 200_000_000)
        var s = spans.summary(since: since)
        s["refresh_wall_ms"] = Double(t1 - t0) / 1e6
        if let p = spans.usageAssigned(since: since) { s["publish_ms"] = Double(t1 - p) / 1e6 }
        return s
    }

    /// One second with nothing to do: the observers' own floor.
    @MainActor static func quiet(_ spans: RunLoopSpans) async throws -> [String: Double] {
        let since = spans.mark()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return Bench.stats(spans.spans(since: since).map(\.ms))
    }

    /// Opens the popover's view tree as `togglePopover` does (a new `PopoverView` in a new `NSHostingController`
    /// sized to its content), in a window that is never shown. Layout and display are forced, since a hidden window
    /// isn't laid out on its own; then 300 ms for any deferred work.
    @MainActor static func open(_ store: Store, in window: NSWindow, spans: RunLoopSpans) async throws -> [String: Double] {
        let since = spans.mark()
        let t0 = DispatchTime.now().uptimeNanoseconds
        let host = NSHostingController(rootView: PopoverView(store: store, actions: Self.actions()))
        host.sizingOptions = .preferredContentSize
        let t1 = DispatchTime.now().uptimeNanoseconds
        window.contentViewController = host
        let t2 = DispatchTime.now().uptimeNanoseconds
        host.view.layoutSubtreeIfNeeded()
        let t3 = DispatchTime.now().uptimeNanoseconds
        host.view.displayIfNeeded()
        CATransaction.flush()
        let t4 = DispatchTime.now().uptimeNanoseconds
        try await Task.sleep(nanoseconds: 300_000_000)
        let later = spans.spans(since: since).filter { $0.start > t4 }
        func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }
        return ["construct_ms": ms(t0, t1), "attach_ms": ms(t1, t2), "layout_ms": ms(t2, t3), "display_ms": ms(t3, t4),
                "total_ms": ms(t0, t4), "deferred_max_span_ms": later.map(\.ms).max() ?? 0,
                "width": Double(host.view.fittingSize.width), "height": Double(host.view.fittingSize.height)]
    }

    /// The system, limit and plan values of `SnapshotFixture` (full histories: three 150-point charts), so the popover
    /// renders all of its cards. Usage comes from the ledger.
    @MainActor static func populate(_ s: Store) {
        let f = SnapshotFixture.store(now: Date())
        s.cpu = f.cpu; s.cpuHistory = f.cpuHistory; s.gpu = f.gpu; s.gpuHistory = f.gpuHistory
        s.memory = f.memory; s.memHistory = f.memHistory; s.battery = f.battery
        s.claudeLimits = f.claudeLimits; s.claudeLimitsEnabled = true; s.claudeAvailable = true
        s.grokEnabled = true; s.grokAvailable = true; s.grokPlan = f.grokPlan
    }

    @MainActor static func actions() -> PopoverActions {
        PopoverActions(refresh: {}, quit: {}, keepAwake: { _ in }, loginItem: FakeLoginItem(), setClaudeLimits: { _ in },
                       setGrokCredits: { _ in }, quotaSwitchChanged: { _, _ in }, updatePricing: {}, clearUsageCache: {})
    }

    /// Never ordered in: nothing is shown on screen.
    @MainActor static func window() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless],
                         backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    static func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// Per-tick figures as distributions, key by key.
    static func collate(_ xs: [[String: Double]]) -> [String: Any] {
        var keys = Set<String>()
        xs.forEach { keys.formUnion($0.keys) }
        var out: [String: Any] = [:]
        for k in keys { out[k] = Bench.stats(xs.compactMap { $0[k] }) }
        return out
    }

    private static func runLoopFacts() -> [String: Any] {
        ["main_thread": Thread.isMainThread, "main_run_loop_mode": RunLoop.main.currentMode?.rawValue ?? "none"]
    }

    static func write(_ report: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}

/// Busy spans of the main run loop: from waking (`afterWaiting`, observed first) to going back to sleep
/// (`beforeWaiting`, observed last). Main-thread only.
@MainActor final class RunLoopSpans {
    struct Span {
        var start: UInt64
        var end: UInt64
        var bodies: Int
        var publishes: Int
        /// The span in which `claudeUsage` was assigned: the post-refresh publish.
        var usage: Bool
        var ms: Double { Double(end - start) / 1e6 }
    }

    private(set) var all: [Span] = []
    private(set) var bodiesTotal = 0
    private(set) var bodiesInSpans = 0
    private var busySince: UInt64?
    private var bodies = 0, publishes = 0, usage = false
    private var usageTimes: [UInt64] = []
    private var observers: [CFRunLoopObserver] = []
    private var sinks: [AnyCancellable] = []

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.begin() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.end() }
        }
        observers = [wake!, sleep!]
        observers.forEach { CFRunLoopAddObserver(CFRunLoopGetMain(), $0, .commonModes) }
    }

    func stop() {
        observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
        observers = []
    }

    /// Counts `objectWillChange` on `store` (it fires synchronously, at each `@Published` assignment), and times
    /// each `claudeUsage` assignment, the first of the four `refreshUsage` makes after a refresh.
    func watch(_ store: Store) {
        sinks = [
            store.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.publishes += 1 } },
            store.$claudeUsage.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.usage = true
                    self?.usageTimes.append(DispatchTime.now().uptimeNanoseconds)
                }
            },
        ]
    }

    func body() {
        bodies += 1
        bodiesTotal += 1
        if busySince != nil { bodiesInSpans += 1 }
    }

    private func begin() {
        busySince = DispatchTime.now().uptimeNanoseconds
        bodies = 0
        publishes = 0
        usage = false
    }

    private func end() {
        guard let s = busySince else { return }
        all.append(Span(start: s, end: DispatchTime.now().uptimeNanoseconds, bodies: bodies, publishes: publishes,
                        usage: usage))
        busySince = nil
    }

    func mark() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    func spans(since t: UInt64) -> [Span] { all.filter { $0.end >= t } }
    func usageAssigned(since t: UInt64) -> UInt64? { usageTimes.first { $0 >= t } }

    /// After `t`: the longest busy span; the span of the post-refresh publish (with the update pass that follows it
    /// before the run loop sleeps); the longest other span with a SwiftUI update; and counts.
    func summary(since t: UInt64) -> [String: Double] {
        let ss = spans(since: t)
        let updates = ss.filter { $0.bodies > 0 }
        return ["max_span_ms": ss.map(\.ms).max() ?? 0,
                "publish_span_ms": ss.filter(\.usage).map(\.ms).max() ?? 0,
                "other_update_span_ms": updates.filter { !$0.usage }.map(\.ms).max() ?? 0,
                "update_spans": Double(updates.count), "publishes": Double(ss.map(\.publishes).reduce(0, +)),
                "busy_ms": ss.map(\.ms).reduce(0, +)]
    }
}

/// Re-evaluated whenever the store publishes, in the same update pass as `PopoverView`: it marks that pass. Zero size.
private struct BodyProbe: View {
    @ObservedObject var store: Store
    let spans: RunLoopSpans
    var body: some View {
        spans.body()
        return Color.clear.frame(width: 0, height: 0)
    }
}

/// Counts distinct `indexing` values published during a cold scan.
@MainActor private final class IndexingCounter {
    private var sink: AnyCancellable?
    private(set) var count = 0
    init(_ store: Store) {
        sink = store.$indexing.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.count += 1 } }
    }
}

extension BenchDataset {
    /// `probe`, `first` or `publish` when `PerformanceUIBenchTests` should run (`SPANDECK_BENCH_UI` set; `first` and
    /// `publish` also need a dataset and `SPANDECK_BENCH_HOME`); nil otherwise.
    static var uiMode: String? {
        let e = ProcessInfo.processInfo.environment
        guard let m = e["SPANDECK_BENCH_UI"], ["probe", "first", "publish"].contains(m) else { return nil }
        if m != "probe", selected == nil || e["SPANDECK_BENCH_HOME"] == nil { return nil }
        return m
    }
}
