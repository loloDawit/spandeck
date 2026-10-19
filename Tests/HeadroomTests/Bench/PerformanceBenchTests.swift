import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Headroom

/// #8 performance baseline on synthetic data. Skipped unless `SPANDECK_BENCH_DATASET` is `small`, `medium` or
/// `large`; `scripts/bench.sh` runs one dataset per process and writes `<dataset>.json` to `SPANDECK_BENCH_OUT`.
/// Everything runs in a `Sandbox`: no real transcript, credential, setting, network request or app launch.
/// The suite measures, it doesn't assert budgets: a slow machine must not fail CI, and the CI runner never sets
/// the variable.
@Suite(.serialized, .enabled(if: BenchDataset.selected != nil))
struct PerformanceBenchTests {
    private static var out: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SPANDECK_BENCH_OUT"] ?? NSTemporaryDirectory())
    }

    /// How many timed repetitions a scenario gets; first scans and rebuilds of the large set are the slow ones.
    private static func n(_ scenario: String, _ d: BenchDataset) -> Int {
        switch scenario {
        case "cold", "rebuild": return d.name == "small" ? 5 : 3
        case "warm", "wake": return 5
        case "full", "summary", "flush": return 10
        default: return 30
        }
    }

    private static func refresh(_ ledger: Ledger, window: Date? = nil) async -> (UsageSummary, UsageSummary) {
        await withCheckedContinuation { c in
            ledger.refresh(windowStart: window, progress: { _ in },
                           completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
        }
    }

    private static func readBytes(_ ledger: Ledger) async -> Int {
        await withCheckedContinuation { c in ledger.claudeReadStats { c.resume(returning: $0.bytes) } }
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    @MainActor @Test func baseline() async throws {
        let d = try #require(BenchDataset.selected)
        let box = try Sandbox()
        let clock = BenchClock()
        var report: [String: Any] = ["dataset": d.name]
        let footprintStart = Bench.footprint().now

        // Dataset (not timed as a scenario).
        let genT0 = Date()
        let shape = try d.write(home: box.home, now: clock.now)
        report["shape"] = ["bytes": shape.bytes, "lines": shape.lines, "transcripts": shape.files,
                           "messages": d.messages + d.bigFile, "grok_sessions": d.grokSessions,
                           "grok_turns": d.grokSessions * d.grokTurns, "generate_s": Date().timeIntervalSince(genT0)]

        let pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
        pricing.load()
        func freshSupport(_ tag: String) throws -> URL {
            let u = box.root.appendingPathComponent("support-\(tag)")
            try? FileManager.default.removeItem(at: u)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        func ledger(_ support: URL) -> Ledger {
            Ledger(home: box.home, appSupport: support, pricing: pricing, now: { clock.now })
        }

        // 1. Ledger cold start: no SpanDeck cache, first scan of everything. Not an app launch (no NSApplication,
        //    status item or run loop). The OS file cache may be warm: purging it needs root. Run 1 is reported apart.
        var cold: [Bench.Sample] = [], scanned = 0, tokens = 0
        for i in 0..<Self.n("cold", d) {
            let l = ledger(try freshSupport("cold\(i)"))
            cold.append(await Bench.measure { tokens = (await Self.refresh(l)).0.month.tokens })
            scanned = await Self.readBytes(l)
        }
        report["cold_first_scan"] = Bench.summary(cold).merging(["first_run_wall_s": cold[0].wall, "bytes_scanned": scanned,
                                                                 "month_tokens": tokens]) { a, _ in a }
        report["footprint_after_cold_bytes"] = Bench.footprint().now

        // The ledger every later scenario uses, with a saved cache.
        let support = try freshSupport("main")
        var main = ledger(support)
        _ = await Self.refresh(main)
        // The first refresh already saved the cache (a first save happens at once; later ones at most every
        // 10 minutes, and on quit). That save is inside the cold-scan figures.
        let cacheURL = support.appendingPathComponent(Ledger.cacheName)
        report["cache_bytes"] = Self.fileSize(cacheURL)

        // 2. Ledger warm start: a new ledger on the saved cache (load, then the first refresh's full scan). Not an app
        //    launch.
        var warm: [Bench.Sample] = []
        for _ in 0..<Self.n("warm", d) {
            let l = ledger(support)
            warm.append(await Bench.measure { _ = await Self.refresh(l) })
        }
        report["warm_launch"] = Bench.summary(warm)
        main = ledger(support)
        _ = await Self.refresh(main)

        // 3. The 10-second tick with nothing new (hot files only).
        var idle: [Bench.Sample] = []
        for _ in 0..<Self.n("tick", d) { idle.append(await Bench.measure { _ = await Self.refresh(main) }) }
        report["tick_no_change"] = Bench.summary(idle)

        // 4. Incremental: 10 new messages (40 lines) appended to the hot file, then the tick. A ledger that hasn't saved
        //    yet saves on its first change (`lastSave` is `.distantPast`), so one untimed tick takes that save first:
        //    the timed ticks then exclude saves by construction (B5), and `samples_with_a_save` checks it.
        var seq = 0, incr: [Bench.Sample] = []
        try BenchDataset.append(home: box.home, count: 10, now: clock.now, seq: &seq)
        let primingSave = await Bench.measure { _ = await Self.refresh(main) }
        for _ in 0..<Self.n("tick", d) {
            try BenchDataset.append(home: box.home, count: 10, now: clock.now, seq: &seq)
            incr.append(await Bench.measure { _ = await Self.refresh(main) })
        }
        let cacheSize = UInt64(Self.fileSize(cacheURL))
        report["tick_incremental_10_messages"] = Bench.summary(incr).merging([
            "samples_with_a_save": incr.filter { $0.written >= cacheSize / 2 }.count,
            "first_change_after_start_wall_s": primingSave.wall, "first_change_after_start_written_bytes": primingSave.written,
        ]) { a, _ in a }

        // 4b. Cache save: `flush()` after a change (what quit does, and every 10 minutes while running).
        var save: [Bench.Sample] = []
        for _ in 0..<Self.n("flush", d) {
            try BenchDataset.append(home: box.home, count: 10, now: clock.now, seq: &seq)
            _ = await Self.refresh(main)
            save.append(await Bench.measure { main.flush() })
        }
        report["cache_save"] = Bench.summary(save)

        // 5. The 5-minute full scan with nothing new (clock moved past 300 s each time).
        var full: [Bench.Sample] = []
        for _ in 0..<Self.n("full", d) {
            clock.advance(301)
            full.append(await Bench.measure { _ = await Self.refresh(main) })
        }
        report["full_scan_no_change"] = Bench.summary(full)

        // 6. Summary only: a new 5-hour window start forces the summary, with no new data.
        var summary: [Bench.Sample] = []
        for i in 0..<Self.n("summary", d) {
            let w = clock.now.addingTimeInterval(-5 * 3600 + Double(i * 60))
            summary.append(await Bench.measure { _ = await Self.refresh(main, window: w) })
        }
        report["summary_recompute"] = Bench.summary(summary)

        // 7. Simulated wake (the clock moves 8 h; the machine doesn't sleep): the next refresh is a full scan, the day may have changed, and the three
        //    newest files gained lines meanwhile (other sessions). The app calls refreshLimits and refreshUsage on wake.
        //    More than 10 minutes have passed with new data, so the refresh also saves the cache, as the app's would:
        //    `disk_written_bytes` shows it.
        var wake: [Bench.Sample] = []
        for _ in 0..<Self.n("wake", d) {
            clock.advance(8 * 3600)
            for k in 0..<3 { try BenchDataset.append(home: box.home, count: 5, now: clock.now, seq: &seq, newest: k) }
            wake.append(await Bench.measure { _ = await Self.refresh(main) })
        }
        report["wake_after_8h"] = Bench.summary(wake)

        // 8. Cache rebuild: Settings › Clear cached usage data, then the next refresh re-reads everything.
        var rebuild: [Bench.Sample] = []
        for _ in 0..<Self.n("rebuild", d) {
            let failure: LedgerClearFailure? = await withCheckedContinuation { c in main.clearCache { c.resume(returning: $0) } }
            #expect(failure == nil)
            rebuild.append(await Bench.measure { _ = await Self.refresh(main) })
        }
        report["rebuild_after_clear"] = Bench.summary(rebuild)

        // 9. Backpressure: 10 refreshes requested at once on the ledger queue (it's serial and doesn't coalesce).
        try BenchDataset.append(home: box.home, count: 10, now: clock.now, seq: &seq)
        let burst = await Bench.measure {
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<10 { g.addTask { _ = await Self.refresh(main) } }
            }
        }
        report["ledger_burst_10"] = ["wall_s": burst.wall, "cpu_s": burst.cpu]

        // 9b. Quit during a scan: `applicationWillTerminate` calls `flush()`, a `queue.sync` on the ledger's serial
        //     queue, so it waits for a scan in flight, on the main thread. Measured 50 ms into a cold scan.
        let quitting = ledger(try freshSupport("quit"))
        quitting.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in })
        try? await Task.sleep(nanoseconds: 50_000_000)
        let quit = await Bench.measure { quitting.flush() }
        report["quit_flush_during_cold_scan"] = ["wall_s": quit.wall]

        // 9c. Quit as the app does since #86, 50 ms into a cold scan: `ShutdownCoordinator.begin` asks the ledger to
        //     stop at its next checkpoint and save on its own queue, and replies once that's done (or after 5 s).
        //     Main-thread blocking is how long `begin` takes plus how late a 5 ms main-actor heartbeat runs meanwhile.
        //     Cancellation latency runs from `begin` to the stopped refresh's completion; the save from there to the
        //     ledger's stop result; total to the reply.
        @Sendable func ns() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
        let stoppingSupport = try freshSupport("quit-new")
        let stopping = ledger(stoppingSupport)
        let marks = Once()
        stopping.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in marks.set("stopped", ns()) })
        try? await Task.sleep(nanoseconds: 50_000_000)
        var quitLate: [Double] = []
        let quitBeat = Task { @MainActor in
            while !Task.isCancelled {
                let t0 = ns()
                try? await Task.sleep(nanoseconds: 5_000_000)
                quitLate.append(Double(ns() - t0) / 1e6 - 5)
            }
        }
        let coordinator = ShutdownCoordinator(stop: { done in
            stopping.requestStop { r in marks.set("saved", ns()); done(r) }
        })
        var outcome: ShutdownCoordinator.Outcome?
        let tBegin = ns()
        coordinator.begin { outcome = $0; marks.set("reply", ns()) }
        let beginMs = Double(ns() - tBegin) / 1e6
        while outcome == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        quitBeat.cancel()
        await quitBeat.value // its last, cancelled sleep is dropped below, and nothing appends after this
        if !quitLate.isEmpty { quitLate.removeLast() }
        // A mark that never came is reported as missing (null), never as 0 s, and the difference is signed, so a mark
        // earlier than its start can't trap (review of #90).
        func span(_ from: UInt64?, _ to: UInt64?) -> Any {
            if let from, let to { Double(Int64(bitPattern: to &- from)) / 1e9 } else { NSNull() }
        }
        // The cancellation latency only means something if the scan was still running when the quit began.
        let scanEndedFirst = (marks.get("stopped") ?? .max) < tBegin
        report["quit_coordinator_during_cold_scan"] = [
            "outcome": "\(outcome!)", "begin_ms": beginMs, "heartbeat_late_ms": Bench.stats(quitLate),
            "cancel_latency_s": scanEndedFirst ? NSNull() : span(tBegin, marks.get("stopped")),
            "scan_ended_before_quit": scanEndedFirst,
            "save_s": span(marks.get("stopped"), marks.get("saved")),
            "total_to_reply_s": span(tBegin, marks.get("reply")),
            "cache_bytes": Self.fileSize(stoppingSupport.appendingPathComponent(Ledger.cacheName)),
            "bytes_scanned_before_stop": await Self.readBytes(stopping),
        ]

        // 10. Main thread and the app-level guard: ProviderServices runs a cold scan while a main-actor heartbeat
        //     ticks every 5 ms; the largest lateness is how long the main thread was held. Ten more refreshes are
        //     requested while it runs; `refreshUsage` drops those (returns nil) instead of queueing them.
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        var lateness: [Double] = []
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                let t0 = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 5_000_000)
                lateness.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 - 5)
            }
        }
        var dropped = 0
        let scan = await Bench.measure {
            async let first = services.refreshUsage(windowStart: nil)
            try? await Task.sleep(nanoseconds: 20_000_000)
            for _ in 0..<10 where await services.refreshUsage(windowStart: nil) == nil { dropped += 1 }
            _ = await first
        }
        beat.cancel()
        await beat.value // drop the last, cancelled sleep; nothing appends after this
        if !lateness.isEmpty { lateness.removeLast() }
        report["main_thread_during_cold_scan"] = ["scan_wall_s": scan.wall, "heartbeat_late_ms": Bench.stats(lateness),
                                                  "overlapping_refreshes_dropped_of_10": dropped]

        // 11. Rendering on the main thread: the menu-bar strip (every sample tick, popover open or closed) and the
        //     popover (only while it's open, on each store change). Default preferences of the test process.
        let store = services.store
        store.claudeAvailable = true
        var strip: [Double] = []
        for _ in 0..<200 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = StatusRenderer.render(store)
            strip.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        let actions = PopoverActions(refresh: {}, quit: {}, keepAwake: { _ in }, loginItem: FakeLoginItem(),
                                     setClaudeLimits: { _ in }, setGrokCredits: { _ in }, quotaSwitchChanged: { _, _ in },
                                     updatePricing: {}, clearUsageCache: {})
        var popover: [Double] = []
        for _ in 0..<20 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let r = ImageRenderer(content: PopoverView(store: store, actions: actions))
            _ = r.cgImage
            popover.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        report["render_ms"] = ["menu_bar_strip": Bench.stats(strip), "popover_full_render": Bench.stats(popover)]

        // 12. Hardware sampling, once per sample tick (0.5–5 s; default 1 s). Battery is read every 5 s.
        let sampler = SystemSampler()
        _ = sampler.cpu()
        var probes: [String: Double] = [:]
        for (name, probe) in [("cpu", { _ = sampler.cpu() }), ("memory", { _ = sampler.memory() }),
                              ("gpu", { _ = sampler.gpu() }), ("battery", { _ = sampler.battery() })] as [(String, () -> Void)] {
            var xs: [Double] = []
            for _ in 0..<100 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                probe()
                xs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            probes[name] = Bench.stats(xs)["median"]
        }
        report["sampler_median_ms"] = probes

        // 12b. Hover panel: top consumers, on the main thread every refresh while a CPU, GPU, memory or battery
        //      hover is shown. Only timings are kept; no process name is recorded.
        let consumers = ConsumerSampler()
        var hover: [String: Double] = [:]
        for kind in [SegmentKind.cpu, .memory] {
            consumers.reset()
            _ = consumers.top(kind)
            var xs: [Double] = []
            for _ in 0..<20 {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = consumers.top(kind)
                xs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            }
            hover["\(kind)"] = Bench.stats(xs)["median"]
        }
        report["hover_top_consumers_median_ms"] = hover

        // 13. Idle at the app's cadence, optional (it takes real time): 1 s samples and strip redraws, a usage
        //     refresh every 10 s, nothing new. CPU is reported as a share of one core, minus a sleep-only control.
        if let secs = ProcessInfo.processInfo.environment["SPANDECK_BENCH_IDLE_SECONDS"].flatMap(Double.init), secs >= 10 {
            let control = await Bench.measure { try? await Task.sleep(nanoseconds: UInt64(secs * 1e9)) }
            let run = await Bench.measure {
                var t = 0
                while Double(t) < secs {
                    _ = sampler.cpu(); _ = sampler.gpu(); _ = sampler.memory()
                    if t % 5 == 0 { _ = sampler.battery() }
                    _ = StatusRenderer.render(store)
                    if t % 10 == 0 { _ = await Self.refresh(main) }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    t += 1
                }
            }
            report["idle_cadence"] = ["seconds": secs, "cpu_share_of_one_core": (run.cpu - control.cpu) / run.wall,
                                      "control_cpu_s": control.cpu, "disk_written_bytes": run.written]
        }

        // 9d. Quit with the whole cache to save: the worst case for the quit's duration (the main thread is still
        //     free). `main` holds every operation and has unsaved changes. Last, since a stopped ledger never scans
        //     again.
        try BenchDataset.append(home: box.home, count: 10, now: clock.now, seq: &seq)
        _ = await Self.refresh(main)
        let fullMarks = Once()
        var fullLate: [Double] = []
        let fullBeat = Task { @MainActor in
            while !Task.isCancelled {
                let t0 = ns()
                try? await Task.sleep(nanoseconds: 5_000_000)
                fullLate.append(Double(ns() - t0) / 1e6 - 5)
            }
        }
        let fullCoordinator = ShutdownCoordinator(stop: { done in main.requestStop { r in fullMarks.set("saved", ns()); done(r) } })
        var fullOutcome: ShutdownCoordinator.Outcome?
        let fullBegin = ns()
        fullCoordinator.begin { fullOutcome = $0; fullMarks.set("reply", ns()) }
        let fullBeginMs = Double(ns() - fullBegin) / 1e6
        while fullOutcome == nil { try? await Task.sleep(nanoseconds: 2_000_000) }
        fullBeat.cancel()
        await fullBeat.value
        if !fullLate.isEmpty { fullLate.removeLast() }
        report["quit_coordinator_full_cache"] = [
            "outcome": "\(fullOutcome!)", "begin_ms": fullBeginMs, "heartbeat_late_ms": Bench.stats(fullLate),
            "save_s": span(fullBegin, fullMarks.get("saved")), "total_to_reply_s": span(fullBegin, fullMarks.get("reply")),
            "cache_bytes": Self.fileSize(cacheURL),
        ]

        let fp = Bench.footprint()
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        report["memory_bytes"] = ["footprint_at_start": footprintStart, "footprint_end": fp.now,
                                  "footprint_peak": fp.peak, "max_rss": Int(ru.ru_maxrss)]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        try data.write(to: Self.out.appendingPathComponent("\(d.name).json"))
    }
}
