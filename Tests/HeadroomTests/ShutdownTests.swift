import Foundation
import Testing
@testable import Headroom

/// #86: quitting stops a scan at a safe checkpoint (between files, or between fully counted lines), then saves on the
/// ledger queue, so the main thread is never held. Every interruption must resume to exactly what an uninterrupted
/// scan gives: the same saved cache (file marks, operations, links, buckets, identity, flaws, unread records), the
/// same hourly usage and the same summaries. All data is synthetic.
/// Serialized, and on small datasets: these tests scan for real, and running them alongside the timing-sensitive
/// concurrency tests starves those (#46).
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ShutdownTests {
    // MARK: Rig

    /// One home of synthetic transcripts and any number of ledgers over it. Every support folder shares one key, so two
    /// ledgers that counted the same things save identical caches.
    final class Rig: @unchecked Sendable {
        let box: Sandbox
        let pricing: Pricing
        let clock: TestClock
        let calendar: Calendar
        private let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        private var supports = 0

        init(now: Date = Date(), calendar: Calendar = .current) throws {
            box = try Sandbox()
            pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
            clock = TestClock(now)
            self.calendar = calendar
        }

        /// A new support folder holding only the shared key.
        func support() throws -> URL {
            supports += 1
            let url = box.root.appendingPathComponent("support-\(supports)")
            try PrivateDirectory(url: url).write(key, to: Ledger.keyName, excludedFromBackup: true)
            return url
        }

        func ledger(_ support: URL, storage: PrivateDirectory? = nil) -> Ledger {
            let clock = clock, calendar = calendar
            return Ledger(home: box.home, appSupport: support, pricing: pricing, storage: storage,
                          now: { clock.now }, calendar: { calendar })
        }

        /// The synthetic dataset of the #8 benchmark, scaled down: `files` transcripts of 4-line messages, one bigger
        /// hot file, and Grok sessions.
        func writeDataset(files: Int = 4, messages: Int = 80, bigFile: Int = 240, grokSessions: Int = 3) throws {
            try BenchDataset(name: "test", files: files, messages: messages, bigFile: bigFile, grokSessions: grokSessions,
                             grokTurns: 10).write(home: box.home, now: clock.now)
        }
    }

    static func refresh(_ l: Ledger) async -> (claude: UsageSummary, grok: UsageSummary) {
        await withCheckedContinuation { c in
            l.refresh(windowStart: nil, progress: { _ in }, completion: { a, b, _ in c.resume(returning: (a, b)) })
        }
    }

    static func stop(_ l: Ledger) async -> LedgerStopResult {
        await withCheckedContinuation { c in l.requestStop { c.resume(returning: $0) } }
    }

    static func hours(_ l: Ledger) async -> [Int: [String: Agg]] {
        await withCheckedContinuation { c in l.claudeHourlyUsage { c.resume(returning: $0) } }
    }

    static func bytesRead(_ l: Ledger) async -> Int {
        await withCheckedContinuation { c in l.claudeReadStats { c.resume(returning: $0.bytes) } }
    }

    /// The saved cache as a dictionary, or nil if none was saved.
    static func cache(_ support: URL) -> NSDictionary? {
        guard let d = try? Data(contentsOf: support.appendingPathComponent(Ledger.cacheName)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? NSDictionary
    }

    /// A one-shot value set on any thread and awaited without blocking a thread of the shared pool (blocking it
    /// starves other tests' async work, #46).
    final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        private var waiters: [CheckedContinuation<T, Never>] = []
        func set(_ v: T) {
            let w: [CheckedContinuation<T, Never>] = lock.withLock {
                guard value == nil else { return [] }
                value = v
                defer { waiters = [] }
                return waiters
            }
            w.forEach { $0.resume(returning: v) }
        }
        var peek: T? { lock.withLock { value } }
        func get() async -> T {
            await withCheckedContinuation { c in
                let v: T? = lock.withLock {
                    if let value { return value }
                    waiters.append(c)
                    return nil
                }
                if let v { c.resume(returning: v) }
            }
        }
    }

    /// The result of a stop requested from inside a scan, once it arrives.
    final class StopBox: @unchecked Sendable {
        private let once = Once<LedgerStopResult>()
        func set(_ r: LedgerStopResult) { once.set(r) }
        var peek: LedgerStopResult? { once.peek }
        func result() async -> LedgerStopResult { await once.get() }
    }

    /// Stops the ledger at the `n`-th checkpoint (counting from 1) that `matches`, from inside the scan, as a quit
    /// arriving then would. The returned box gets that stop's result.
    @discardableResult
    static func stopAt(_ l: Ledger, _ n: Int, where matches: @escaping (Ledger.Checkpoint) -> Bool = { _ in true }) -> StopBox {
        let box = StopBox()
        var seen = 0
        l.checkpointHook = { [weak l] c in
            guard matches(c) else { return }
            seen += 1
            if seen == n { l?.requestStop(completion: { box.set($0) }) }
        }
        return box
    }

    /// How many checkpoints an uninterrupted refresh passes, per kind.
    static func checkpoints(_ rig: Rig, lines: Int) async throws -> [Ledger.Checkpoint] {
        let l = rig.ledger(try rig.support())
        l.stopCheckLines = lines
        var all: [Ledger.Checkpoint] = []
        let lock = NSLock()
        l.checkpointHook = { c in lock.withLock { all.append(c) } }
        _ = await refresh(l)
        return lock.withLock { all }
    }

    /// What one support folder holds after a relaunch and one more refresh: a new ledger, as after quitting.
    static func relaunched(_ rig: Rig, _ support: URL) async -> Ledger {
        let l = rig.ledger(support)
        _ = await refresh(l)
        l.flush()
        return l
    }

    /// An uninterrupted scan into a new support folder.
    static func baseline(_ rig: Rig) async throws -> (Ledger, URL) {
        let s = try rig.support()
        let l = rig.ledger(s)
        _ = await refresh(l)
        l.flush()
        return (l, s)
    }

    /// The resumed ledger counted exactly what the uninterrupted one did.
    static func expectSame(_ resumed: (Ledger, URL), _ base: (Ledger, URL), _ label: String,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        let a = resumed.0, b = base.0
        // Both nil is fine: some fixtures (F39) never leave anything to save.
        #expect(cache(resumed.1) == cache(base.1), "\(label): saved caches differ", sourceLocation: sourceLocation)
        #expect(await hours(a) == hours(b), "\(label): hourly usage differs", sourceLocation: sourceLocation)
        let (ca, ga) = await refresh(a), (cb, gb) = await refresh(b)
        for (x, y, name) in [(ca.today, cb.today, "today"), (ca.week, cb.week, "week"), (ca.month, cb.month, "month")] {
            // Costs are sums of doubles over dictionaries, so only their order of addition may differ.
            let sameCost = abs(x.cost.known - y.cost.known) <= 1e-9 * max(1, abs(y.cost.known))
                && x.cost.knownTokens == y.cost.knownTokens && x.cost.unknownTokens == y.cost.unknownTokens
                && abs(x.cost.minimum - y.cost.minimum) <= 1e-9 * max(1, abs(y.cost.minimum))
                && x.cost.disputedTokens == y.cost.disputedTokens
            #expect(x.tokens == y.tokens && x.identity == y.identity && x.completeness == y.completeness
                    && x.quantity == y.quantity && sameCost, "\(label): \(name) differs", sourceLocation: sourceLocation)
        }
        // Rows with equal tokens have no fixed order, so compare them by model.
        #expect(ca.models.map { "\($0.model)=\($0.tokens)" }.sorted() == cb.models.map { "\($0.model)=\($0.tokens)" }.sorted(),
                "\(label): per-model rows differ", sourceLocation: sourceLocation)
        #expect(ga.month.tokens == gb.month.tokens && ga.month.completeness == gb.month.completeness
                && ga.month.identity == gb.month.identity, "\(label): Grok totals differ", sourceLocation: sourceLocation)
    }

    // MARK: 1. Before scanning begins

    /// A stop before any refresh saves nothing, scans nothing afterwards, and every later refresh still completes.
    @Test func stopBeforeAnyRefresh() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        #expect(await Self.stop(l) == .nothingToSave)
        let after = await Self.refresh(l) // sticky: completes without scanning
        let read = await Self.bytesRead(l)
        #expect(after.claude.month.tokens == 0 && read == 0)
        #expect(Self.cache(s) == nil)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "before any refresh")
    }

    /// A stop at the first checkpoint (cache loaded, nothing scanned yet).
    @Test func stopBeforeTheScan() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 1, where: { $0 == .beforeScan })
        _ = await Self.refresh(l)
        let result = await box.result(), read = await Self.bytesRead(l)
        #expect(result == .nothingToSave && read == 0)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "before the scan")
    }

    // MARK: 2. Between files

    @Test(arguments: [1, 2, 3, 5])
    func stopBetweenFiles(_ n: Int) async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        l.stopCheckLines = .max
        let box = Self.stopAt(l, n, where: { $0 == .betweenFiles })
        _ = await Self.refresh(l)
        #expect(await box.result() == (n == 1 ? .nothingToSave : .saved)) // the first is before any file
        #expect(await Self.stop(l) == .nothingToSave) // already saved
        // Stopped: later refreshes don't scan.
        let read = await Self.bytesRead(l)
        _ = await Self.refresh(l)
        #expect(await Self.bytesRead(l) == read)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "between files #\(n)")
    }

    // MARK: 3. Inside a large file

    /// Stopping inside the big file saves its mark at the end of a fully counted line, short of the file's size, and
    /// the relaunch resumes there: nothing skipped, nothing counted twice.
    @Test(arguments: [1, 2, 7])
    func stopInsideALargeFile(_ n: Int) async throws {
        let rig = try Rig()
        try rig.writeDataset(files: 2, messages: 20, bigFile: 400)
        let s = try rig.support()
        let l = rig.ledger(s)
        l.stopCheckLines = 100
        let box = Self.stopAt(l, n, where: { $0 == .inFile })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved)

        // Every mark but one is at its file's end; that one is inside the big file, just past a newline.
        let dir = rig.box.home.appendingPathComponent(BenchDataset.projectDir)
        let sizes = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path).map {
            try Data(contentsOf: dir.appendingPathComponent($0)).count
        })
        let bytes = try Data(contentsOf: dir.appendingPathComponent("big.jsonl"))
        let marks = try #require(Self.cache(s)?["files"] as? [String: [String: Any]])
        let partial = marks.values.compactMap { $0["offset"] as? Int }.filter { !sizes.contains($0) }
        #expect(partial.count == 1, "one mark inside a file: \(partial)")
        if let o = partial.first {
            #expect(o > 0 && o < bytes.count && bytes[bytes.startIndex + o - 1] == 0x0A, "the mark is just past a newline")
            #expect(o >= n * 100 * 100, "at least the lines before the stop are counted") // 100 lines of ≥100 bytes each
        }

        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "inside the big file #\(n)")
    }

    // MARK: 4. During Grok

    @Test func stopDuringGrok() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 2, where: { $0 == .grok })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved) // every Claude file was counted before Grok
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "during Grok")
    }

    // MARK: 5. While a save is under way

    /// A stop requested while a cache write is in progress waits for it on the ledger queue (never on the caller). That
    /// write already holds everything counted, so the stop has nothing left to save; nothing is written twice.
    @Test func stopWhileSaving() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        // The save is held on the ledger's own dispatch queue (not the shared pool) until the test lets it go.
        let gate = DispatchSemaphore(value: 0), entered = Once<Bool>()
        var storage = PrivateDirectory(url: s)
        storage.markExcluded = { file in
            if file.lastPathComponent.contains(Ledger.cacheName) { entered.set(true); gate.wait() }
            try PrivateDirectory.setExcludedFromBackup(file)
        }
        let l = rig.ledger(s, storage: storage)
        let refreshed = Task { await Self.refresh(l) } // the first refresh with data saves at its end
        _ = await entered.get()
        let stopped = StopBox()
        let t0 = DispatchTime.now().uptimeNanoseconds
        l.requestStop(completion: { stopped.set($0) })
        let requestNs = DispatchTime.now().uptimeNanoseconds - t0
        #expect(requestNs < 16_000_000, "the request returns at once, without waiting for the save")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(stopped.peek == nil, "it completes only after the save")
        gate.signal()
        _ = await refreshed.value
        #expect(await stopped.result() == .nothingToSave)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "while saving")
    }

    // MARK: 6. Save failure

    /// A save that fails is reported as failed, never as saved; the previous valid cache stays byte for byte, and the
    /// relaunch rebuilds what wasn't saved from the transcripts.
    @Test func failedSaveKeepsThePreviousCache() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        _ = await Self.relaunched(rig, s) // a valid saved cache
        let before = try Data(contentsOf: s.appendingPathComponent(Ledger.cacheName))

        // More data, then a stop whose save can't complete.
        var seq = 0
        try BenchDataset.append(home: rig.box.home, count: 20, now: rig.clock.now, seq: &seq)
        var storage = PrivateDirectory(url: s)
        storage.markExcluded = { file in
            // Only the new cache's temporary file: the existing cache is marked at load as usual.
            if file.lastPathComponent.hasPrefix("." + Ledger.cacheName + ".tmp-") { throw CocoaError(.fileWriteUnknown) }
            try PrivateDirectory.setExcludedFromBackup(file)
        }
        let l = rig.ledger(s, storage: storage)
        let box = Self.stopAt(l, 2, where: { $0 == .inFile })
        l.stopCheckLines = 10
        _ = await Self.refresh(l)
        #expect(l.cacheIssue == nil, "nothing failed before the stop")
        #expect(await box.result() == .failed)
        #expect(l.cacheIssue != nil)
        #expect(await Self.stop(l) == .failed, "still not saved: asking again tries again and fails again")
        #expect(try Data(contentsOf: s.appendingPathComponent(Ledger.cacheName)) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.path).filter { $0.contains(".tmp-") }.isEmpty)

        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "after a failed save")
    }

    // MARK: 8. Repeated requests

    /// Asking again is harmless: every request completes, the first that saves does, and the cache isn't rewritten.
    @Test func repeatedStopRequests() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 3, where: { $0 == .betweenFiles })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved)
        let results = await withTaskGroup(of: LedgerStopResult.self) { g in
            for _ in 0..<5 { g.addTask { await Self.stop(l) } }
            return await g.reduce(into: [LedgerStopResult]()) { $0.append($1) }
        }
        #expect(results == Array(repeating: .nothingToSave, count: 5))
        let saved = try Data(contentsOf: s.appendingPathComponent(Ledger.cacheName))
        #expect(await Self.stop(l) == .nothingToSave)
        #expect(try Data(contentsOf: s.appendingPathComponent(Ledger.cacheName)) == saved)
    }

    /// The saved files keep their protections: owner-only, excluded from backup.
    @Test func stopSaveKeepsFileProtections() async throws {
        let rig = try Rig()
        try rig.writeDataset()
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 2, where: { $0 == .betweenFiles })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved)
        let cache = s.appendingPathComponent(Ledger.cacheName)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(getxattr(cache.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, XATTR_NOFOLLOW) >= 0)
    }

    // MARK: Review of #90

    /// Listing many transcripts has its own checkpoints, so a stop doesn't wait for the whole listing.
    @Test func stopWhileListingFiles() async throws {
        let rig = try Rig()
        try rig.writeDataset(files: 600, messages: 600, bigFile: 0, grokSessions: 0)
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 1, where: { $0 == .listing })
        _ = await Self.refresh(l)
        let result = await box.result(), read = await Self.bytesRead(l)
        #expect(result == .nothingToSave && read == 0)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "while listing")
    }

    /// Long lines reach the in-file checkpoint by size, not only by count (the line count alone is never reached).
    @Test func longLinesReachTheCheckpointBySize() async throws {
        let rig = try Rig()
        try rig.writeDataset(files: 1, messages: 10, bigFile: 300)
        let s = try rig.support()
        let l = rig.ledger(s)
        l.stopCheckLines = .max
        l.stopCheckBytes = 100_000
        let box = Self.stopAt(l, 3, where: { $0 == .inFile })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved)
        await Self.expectSame((await Self.relaunched(rig, s), s), try await Self.baseline(rig), "by size")
    }

    /// A first index stopped part-way still shows its progress when it resumes: many files are left to read.
    @Test func resumedFirstIndexShowsProgress() async throws {
        let rig = try Rig()
        try rig.writeDataset(files: 60, messages: 600, bigFile: 0, grokSessions: 0)
        let s = try rig.support()
        let l = rig.ledger(s)
        let box = Self.stopAt(l, 4, where: { $0 == .betweenFiles })
        _ = await Self.refresh(l)
        #expect(await box.result() == .saved)
        let resumed = rig.ledger(s)
        let messages = Once<[String]>()
        var seen: [String] = []
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            resumed.refresh(windowStart: nil, progress: { if let m = $0 { seen.append(m) } },
                            completion: { _, _, _ in messages.set(seen); c.resume() })
        }
        #expect(!(await messages.get()).isEmpty, "the resumed index reports progress")
    }

    // MARK: 9. Every interruption point, on the accounting fixtures

    /// For every F-fixture, the files after its first step and after all its steps: stopping at **every** checkpoint
    /// (one per line) and relaunching gives exactly the uninterrupted result.
    @Test(arguments: LedgerFixtureTests.names)
    func everyCheckpointResumesExactly(_ name: String) async throws {
        let fixture = try LedgerFixtureTests.load(name)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: fixture.timeZone))
        let rig = try Rig(now: try #require(ISO.parse(fixture.now)), calendar: cal)
        for (label, steps) in [("first step", Array(fixture.steps.prefix(1))), ("all steps", fixture.steps)] {
            try? FileManager.default.removeItem(at: rig.box.home.appendingPathComponent(".claude"))
            for step in steps { try Self.apply(step.ops, fixture: name, rig: rig) }
            let base = try await Self.baseline(rig)
            let total = try await Self.checkpoints(rig, lines: 1).count
            for k in 1...max(1, total) {
                let s = try rig.support()
                let l = rig.ledger(s)
                l.stopCheckLines = 1
                let box = Self.stopAt(l, k)
                _ = await Self.refresh(l)
                let result = await box.result()
                #expect(result == .saved || result == .nothingToSave, "\(name) \(label) checkpoint \(k): \(String(describing: result))")
                await Self.expectSame((await Self.relaunched(rig, s), s), base, "\(name) \(label) checkpoint \(k)/\(total)")
            }
        }
    }

    /// The fixture ops (`LedgerFixtureTests`), with modification times pinned just before the fixture's now.
    static func apply(_ ops: [LedgerFixtureTests.Op], fixture name: String, rig: Rig) throws {
        let fm = FileManager.default
        let projects = rig.box.home.appendingPathComponent(".claude/projects")
        for op in ops {
            let dest = projects.appendingPathComponent(op.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = { try Data(contentsOf: LedgerFixtureTests.root.appendingPathComponent("\(name)/\(op.from!)")) }
            switch op.op {
            case "write": try source().write(to: dest)
            case "append":
                let h = try FileHandle(forWritingTo: dest)
                try h.seekToEnd()
                try h.write(contentsOf: source())
                try h.close()
            case "delete": try fm.removeItem(at: dest)
            case "rename":
                let to = projects.appendingPathComponent(op.to!)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: dest, to: to)
            default: Issue.record("unknown op \(op.op)")
            }
        }
        let stamp = rig.clock.now.addingTimeInterval(-60)
        guard let en = fm.enumerator(at: projects, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in en { try fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path) }
    }
}

/// #86: the app's side of quitting. `applicationShouldTerminate` answers `.terminateLater` and the coordinator replies
/// once: when the ledger has stopped and saved, or after the timeout, whichever comes first. The main thread is never
/// held while the ledger works.
@MainActor @Suite(.serialized, .timeLimit(.minutes(5)))
struct ShutdownCoordinatorTests {
    /// A ledger stand-in whose completion the test controls.
    final class FakeStop: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [@Sendable (LedgerStopResult) -> Void] = []
        var calls: Int { lock.withLock { pending.count } }
        func stop(_ done: @escaping @Sendable (LedgerStopResult) -> Void) { lock.withLock { pending.append(done) } }
        func complete(_ r: LedgerStopResult) { for d in lock.withLock({ pending }) { d(r) } }
    }

    /// Timers the test fires by hand.
    final class ManualTimers {
        var scheduled: [(TimeInterval, @MainActor () -> Void)] = []
        func after(_ d: TimeInterval, _ f: @escaping @MainActor () -> Void) { scheduled.append((d, f)) }
    }

    /// Lets the main actor run the hops the coordinator makes.
    static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    @Test func defaultTimeoutIsFiveSeconds() {
        #expect(ShutdownCoordinator.defaultTimeout == 5)
    }

    @Test(arguments: [LedgerStopResult.saved, .nothingToSave, .failed])
    func repliesOnceWithTheLedgersResult(_ r: LedgerStopResult) async {
        let fake = FakeStop(), timers = ManualTimers()
        let c = ShutdownCoordinator(stop: fake.stop, after: timers.after)
        var replies: [ShutdownCoordinator.Outcome] = []
        #expect(c.begin { replies.append($0) })
        #expect(fake.calls == 1 && timers.scheduled.map(\.0) == [5])
        fake.complete(r)
        await Self.settle()
        let expected: ShutdownCoordinator.Outcome = r == .saved ? .saved : r == .nothingToSave ? .nothingToSave : .failed
        #expect(replies == [expected])
        // The timeout firing afterwards changes nothing.
        timers.scheduled.forEach { $0.1() }
        fake.complete(.saved)
        await Self.settle()
        #expect(replies == [expected] && c.outcome == expected)
    }

    /// 7. With no answer, the timeout replies; a late completion afterwards can't change the outcome or reply again.
    @Test func timeoutRepliesOnceAndIgnoresALateCompletion() async {
        let fake = FakeStop(), timers = ManualTimers()
        let c = ShutdownCoordinator(stop: fake.stop, after: timers.after)
        var replies: [ShutdownCoordinator.Outcome] = []
        c.begin { replies.append($0) }
        timers.scheduled.forEach { $0.1() }
        #expect(replies == [.timedOut])
        fake.complete(.saved)
        await Self.settle()
        #expect(replies == [.timedOut] && c.outcome == .timedOut)
    }

    /// 7. The real timer: a stop that never answers is replied to after the timeout, not before.
    @Test func realTimerFires() async {
        let fake = FakeStop()
        let c = ShutdownCoordinator(timeout: 0.2, stop: fake.stop)
        var replies: [ShutdownCoordinator.Outcome] = []
        let t0 = Date()
        c.begin { replies.append($0) }
        while replies.isEmpty && Date().timeIntervalSince(t0) < 5 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(replies == [.timedOut] && Date().timeIntervalSince(t0) >= 0.2)
    }

    /// 8. Asking again while a quit is under way starts nothing new, and every request gets the one outcome. After
    /// the outcome, a new request is answered at once (review of #90: a dropped reply would hang the quit).
    @Test func repeatedBeginStartsOnce() async {
        let fake = FakeStop(), timers = ManualTimers()
        let c = ShutdownCoordinator(stop: fake.stop, after: timers.after)
        var first: [ShutdownCoordinator.Outcome] = [], second: [ShutdownCoordinator.Outcome] = []
        #expect(c.begin { first.append($0) })
        #expect(!c.begin { second.append($0) })
        #expect(fake.calls == 1 && timers.scheduled.count == 1)
        fake.complete(.saved)
        fake.complete(.failed) // a racing second completion
        await Self.settle()
        #expect(first == [.saved] && second == [.saved])
        var late: [ShutdownCoordinator.Outcome] = []
        #expect(!c.begin { late.append($0) })
        #expect(late == [.saved], "a request after the outcome is answered at once")
        #expect(fake.calls == 1 && timers.scheduled.count == 1)
    }

    /// With the real ledger: the main actor stays responsive while the ledger stops a scan and saves, and the
    /// relaunch resumes exactly.
    @Test func realLedgerKeepsTheMainActorResponsive() async throws {
        let rig = try ShutdownTests.Rig()
        try rig.writeDataset(files: 4, messages: 400, bigFile: 800)
        let s = try rig.support()
        let l = rig.ledger(s)
        let scanning = ShutdownTests.Once<Bool>()
        l.checkpointHook = { c in if c == .inFile { scanning.set(true) } }
        l.stopCheckLines = 200
        let refreshed = Task.detached { await ShutdownTests.refresh(l) }
        _ = await scanning.get()

        var lateness: [Double] = []
        let beat = Task { @MainActor in
            while !Task.isCancelled {
                let t0 = DispatchTime.now().uptimeNanoseconds
                try? await Task.sleep(nanoseconds: 5_000_000)
                lateness.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 - 5)
            }
        }
        let c = ShutdownCoordinator(stop: { l.requestStop(completion: $0) })
        var replies: [ShutdownCoordinator.Outcome] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        c.begin { replies.append($0) }
        let beginMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        while replies.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        beat.cancel()
        _ = await refreshed.value
        #expect(replies == [.saved])
        #expect(beginMs < 16, "begin returned in \(beginMs) ms")
        // A guard against real blocking (a save or scan on the main thread would be seconds here). This test runs in
        // parallel with other scanning tests, so scheduling jitter is in it; the #8 benchmark measures it alone (B2, B3).
        #expect((lateness.max() ?? 0) < 200, "main actor late by up to \(lateness.max() ?? 0) ms")
        await ShutdownTests.expectSame((await ShutdownTests.relaunched(rig, s), s), try await ShutdownTests.baseline(rig),
                                       "coordinator stop")
    }
}

/// Review of #90: a refresh that ends because the ledger is stopping publishes nothing. An empty summary would show
/// zero tokens as if measured (missing is not zero).
@MainActor @Suite(.serialized)
struct ShutdownPublishTests {
    @Test func stoppedRefreshPublishesNothing() async throws {
        let box = try Sandbox()
        try BenchDataset(name: "t", files: 2, messages: 40, bigFile: 0, grokSessions: 1, grokTurns: 5)
            .write(home: box.home, now: Date())
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        _ = await services.refreshUsage(windowStart: nil)
        let before = try #require(services.store.claudeUsage).month.tokens
        #expect(before > 0)
        let updated = services.store.usageUpdated
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in services.ledger.requestStop { _ in c.resume() } }
        #expect(await services.refreshUsage(windowStart: nil) == nil)
        #expect(services.store.claudeUsage?.month.tokens == before && services.store.usageUpdated == updated)
    }
}
