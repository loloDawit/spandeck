import AppKit
import Foundation

// Opt-in, local-only performance diagnostics (#94). Off by default and nothing is measured or written until the user
// starts a session from Settings. A session records numbers and fixed labels only: no file name, path, transcript
// content, prompt, model name, account detail or credential can be recorded, because an event has no free-text field.
// It lives in one owner-only file in SpanDeck's Application Support folder, is never uploaded, and is copied elsewhere
// only by the user's explicit Export. See `docs/DIAGNOSTICS.md`.

/// What an event measures. A closed set: adding a kind is a code change, reviewed like any other.
enum DiagnosticKind: String, Codable, CaseIterable, Sendable {
    /// A session was started (or resumed at launch).
    case sessionStart, sessionResume
    /// Process start to the end of `applicationDidFinishLaunching`, and to the first usage totals published.
    case launch, firstUsage
    /// Popover: from the click to the main thread next going idle (built, laid out, committed); and closing it.
    case popoverOpen, popoverClose
    /// A main-thread busy span of at least `Diagnostics.stallThresholdMs`.
    case stall
    /// One ledger refresh on its own queue (`detail`: full or tail scan; cold for the first scan without a cache).
    case refresh
    /// Reading the usage cache at the first refresh (`detail`: kept, discarded, absent) and saving it.
    case cacheLoad, cacheSave
    /// The process's CPU use (% of one core since the last sample) and memory footprint (MB), every 30 s.
    case process
    /// Quitting: from the quit request to the reply, with the ledger's outcome.
    case shutdown
    /// An operation that failed, by category only.
    case error
}

/// A fixed label qualifying an event. Never derived from data.
enum DiagnosticDetail: String, Codable, CaseIterable, Sendable {
    case full, tail, cold
    case kept, discarded, absent
    case saved, failed, nothingToSave, timedOut
    case claudeQuota, grokQuota, usageCache, pricing
}

/// One measurement. Every field but `kind` is optional; only numbers and the two closed enums exist.
struct DiagnosticEvent: Codable, Equatable, Sendable {
    /// Seconds since the session started.
    var t: Double
    var kind: DiagnosticKind
    var detail: DiagnosticDetail?
    var ms: Double?
    var bytes: Int?
    var cpuPercent: Double?
    var footprintMB: Double?
}

/// The session file and the export share this shape (the export adds `environment`).
struct DiagnosticSession: Codable, Equatable, Sendable {
    static let schema = 1
    var schema = DiagnosticSession.schema
    var startedAt: Date
    var updatedAt: Date
    /// Events dropped because the session reached `Diagnostics.maxEvents` (oldest first).
    var dropped = 0
    var events: [DiagnosticEvent] = []
}

/// The session recorder. Thread-safe: the ledger records from its own queue, the app from the main thread. While no
/// session is active, `record` returns at once and nothing is kept.
final class Diagnostics: @unchecked Sendable {
    static let fileName = "diagnostics.json"
    static let activeKey = "diagnostics.active"
    /// Bounded storage: at most this many events (about 100 bytes each in the file), oldest dropped first.
    static let maxEvents = 5_000
    /// A session stops by itself after this long, so it can't be forgotten on.
    static let maxSessionAge: TimeInterval = 24 * 3600
    /// The session file is deleted at launch once it hasn't been written for this long.
    static let retention: TimeInterval = 7 * 24 * 3600
    static let stallThresholdMs = 100.0
    static let sampleInterval: TimeInterval = 30
    /// The file is written at most this often while a session runs, and always when it stops or the app quits.
    static let persistInterval: TimeInterval = 300

    private let directory: PrivateDirectory
    private let preferences: PreferenceStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var session: DiagnosticSession?
    private var lastPersist = Date.distantPast
    private var failure: StorageFailure?
    /// Encoding and writing happen here, off the main thread, in order: a delete queued after a write runs after it.
    private let writeQueue = DispatchQueue(label: "spandeck.diagnostics.write", qos: .utility)
    /// Called (on any thread) when a session stops by itself at `maxSessionAge`, so the UI can show it as off.
    var onExpire: (@Sendable () -> Void)?

    /// Why the last write failed, if it did.
    var writeFailure: StorageFailure? { lock.withLock { failure } }

    init(directory: PrivateDirectory, preferences: PreferenceStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.preferences = preferences
        self.now = now
    }

    var isActive: Bool { lock.withLock { session != nil } }
    var startedAt: Date? { lock.withLock { session?.startedAt } }
    var eventCount: Int { lock.withLock { session?.events.count ?? 0 } }

    /// At launch: resume a session that was on when the app last quit (so start-up and quit are measured), unless it
    /// is older than `maxSessionAge`; delete a session file not written for `retention`. Reads only SpanDeck's own file.
    func restore() {
        let data = (try? directory.read(Self.fileName)) ?? nil
        let stored = data.flatMap { try? Self.decoder.decode(DiagnosticSession.self, from: $0) }
        // SpanDeck's own file, but unusable (damaged, or another schema): nothing can be exported from it, so it goes.
        if data != nil, stored == nil { try? directory.remove(Self.fileName) }
        let current = now()
        if preferences.bool(forKey: Self.activeKey) {
            // A start time in the future (the clock moved back) doesn't extend the session.
            if var s = stored, s.startedAt <= current, current.timeIntervalSince(s.startedAt) < Self.maxSessionAge {
                s.updatedAt = current
                lock.withLock { session = s }
                record(.sessionResume)
                return
            }
            preferences.set(false, forKey: Self.activeKey)
        }
        if let s = stored, current.timeIntervalSince(s.updatedAt) >= Self.retention { try? directory.remove(Self.fileName) }
    }

    /// Starts a new session, replacing any earlier one's data.
    func start() {
        let t = now()
        lock.withLock { session = DiagnosticSession(startedAt: t, updatedAt: t) }
        preferences.set(true, forKey: Self.activeKey)
        record(.sessionStart)
        persist(force: true)
    }

    /// Stops the session and writes it. Nothing is recorded afterwards.
    func stop() {
        guard isActive else { return }
        persist(force: true, wait: true)
        lock.withLock { session = nil }
        preferences.set(false, forKey: Self.activeKey)
    }

    /// Stops any session and deletes its file, after any write already queued.
    func delete() throws {
        lock.withLock { session = nil }
        preferences.set(false, forKey: Self.activeKey)
        try writeQueue.sync { try directory.remove(Self.fileName) }
    }

    /// Adds one event if a session is active; stops a session that reached `maxSessionAge`.
    func record(_ kind: DiagnosticKind, _ detail: DiagnosticDetail? = nil, ms: Double? = nil, bytes: Int? = nil,
                cpuPercent: Double? = nil, footprintMB: Double? = nil) {
        let t = now()
        let expired: Bool = lock.withLock {
            guard let started = session?.startedAt else { return false }
            if t.timeIntervalSince(started) >= Self.maxSessionAge { return true }
            // In place: no copy of the event array per record.
            session!.events.append(DiagnosticEvent(t: Self.round(t.timeIntervalSince(started), 3), kind: kind,
                                                   detail: detail, ms: ms.map { Self.round($0, 2) }, bytes: bytes,
                                                   cpuPercent: cpuPercent.map { Self.round($0, 2) },
                                                   footprintMB: footprintMB.map { Self.round($0, 1) }))
            if session!.events.count > Self.maxEvents {
                session!.events.removeFirst()
                session!.dropped += 1
            }
            session!.updatedAt = t
            return false
        }
        if expired {
            stop()
            onExpire?()
        }
    }

    /// Writes the session file: at most every `persistInterval`, unless `force`. The snapshot is taken now; encoding
    /// and writing run on `writeQueue`, so a periodic write doesn't hold the main thread. `wait` (stop, quit) returns
    /// once the file is written.
    func persist(force: Bool = false, wait: Bool = false) {
        let t = now()
        guard let s: DiagnosticSession = lock.withLock({
            guard let s = session, force || t.timeIntervalSince(lastPersist) >= Self.persistInterval else { return nil }
            lastPersist = t
            return s
        }) else { return }
        let write = { [self] in
            var result: StorageFailure?
            do { try directory.write(try Self.encoder.encode(s), to: Self.fileName, excludedFromBackup: true) } catch {
                result = error as? StorageFailure ?? .io(EIO)
            }
            lock.withLock { failure = result }
        }
        if wait { writeQueue.sync(execute: write) } else { writeQueue.async(execute: write) }
    }

    /// The export: the current session, or the last stopped one from its file, with a sanitized environment (app
    /// version, macOS version, architecture and core count; no host, user or path). nil when there is nothing.
    func exportData(environment: [String: String] = Diagnostics.environment()) -> Data? {
        writeQueue.sync {} // a stopped session's last write has landed
        let s = lock.withLock { session } ?? (try? directory.read(Self.fileName))
            .flatMap { $0 }.flatMap { try? Self.decoder.decode(DiagnosticSession.self, from: $0) }
        guard let s else { return nil }
        struct Export: Encodable { var environment: [String: String]; var session: DiagnosticSession }
        return try? Self.encoder.encode(Export(environment: environment, session: s))
    }

    /// Whether a session file exists (for Settings: Export and Delete are offered then).
    var hasData: Bool {
        isActive || writeQueue.sync { FileManager.default.fileExists(atPath: directory.url.appendingPathComponent(Self.fileName).path) }
    }

    static func environment() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return ["app": AppIdentity.name,
                "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": info["CFBundleVersion"] as? String ?? "unknown",
                "macOS": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                "arch": arch,
                "cores": String(ProcessInfo.processInfo.activeProcessorCount)]
    }

    private static func round(_ x: Double, _ digits: Int) -> Double {
        let p = pow(10, Double(digits))
        return (x * p).rounded() / p
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Process-level measurements, read only while a session runs.
enum ProcessMetrics {
    /// User + system CPU time of this process, in seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
            + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// The physical footprint, in bytes (what Activity Monitor calls Memory).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// When this process started, from the kernel; nil if it can't be read.
    static func startDate() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }
}

/// Main-thread instruments, installed only while a session is active and removed when it stops: a run-loop observer
/// for stalls and the popover's time to idle, and a 30 s timer for CPU and memory. Each observer callback is two
/// `mach_absolute_time` reads and a comparison. Main thread only, like the app delegate that owns it.
final class DiagnosticsMonitor {
    private let diagnostics: Diagnostics
    private var busy: CFRunLoopObserver?
    private var idle: CFRunLoopObserver?
    private var timer: Timer?
    private var busySince: UInt64 = 0
    private var popoverSince: UInt64?
    private var lastCPU: (wall: UInt64, cpu: Double)?
    private var samples = 0

    init(diagnostics: Diagnostics) { self.diagnostics = diagnostics }

    /// Whether any instrument is installed (tests check that stopping removes them).
    var isInstalled: Bool { busy != nil || idle != nil || timer != nil }

    /// Installs the instruments if a session is active, removes them if not.
    func sync() {
        if diagnostics.isActive { install() } else { remove() }
    }

    /// Marks the popover click; the next time the main thread goes idle records `popoverOpen`.
    func popoverRequested() {
        guard diagnostics.isActive else { return }
        popoverSince = mach_absolute_time()
    }

    private func install() {
        guard !isInstalled else { return }
        busySince = mach_absolute_time()
        let start = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) {
            [weak self] _, _ in self?.busySince = mach_absolute_time()
        }
        let end = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) {
            [weak self] _, _ in self?.wentIdle()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), start, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), end, .commonModes)
        busy = start
        idle = end
        let t = Timer(timeInterval: Diagnostics.sampleInterval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        lastCPU = nil
        sample()
    }

    private func remove() {
        if let busy { CFRunLoopRemoveObserver(CFRunLoopGetMain(), busy, .commonModes) }
        if let idle { CFRunLoopRemoveObserver(CFRunLoopGetMain(), idle, .commonModes) }
        busy = nil
        idle = nil
        timer?.invalidate()
        timer = nil
        popoverSince = nil
    }

    private func wentIdle() {
        let t = mach_absolute_time()
        let busyMs = Self.ms(from: busySince, to: t)
        if busyMs >= Diagnostics.stallThresholdMs { diagnostics.record(.stall, ms: busyMs) }
        if let since = popoverSince {
            popoverSince = nil
            diagnostics.record(.popoverOpen, ms: Self.ms(from: since, to: t))
        }
    }

    private func sample() {
        let wall = mach_absolute_time(), cpu = ProcessMetrics.cpuSeconds()
        let percent = lastCPU.map { (cpu - $0.cpu) / max(Self.ms(from: $0.wall, to: wall) / 1000, 0.001) * 100 }
        lastCPU = (wall, cpu)
        diagnostics.record(.process, cpuPercent: percent, footprintMB: Double(ProcessMetrics.footprint()) / 1_048_576)
        samples += 1
        diagnostics.persist()
        if !diagnostics.isActive { remove() } // reached its maximum age
    }

    static func ms(from a: UInt64, to b: UInt64) -> Double {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(b &- a) * Double(tb.numer) / Double(tb.denom) / 1e6
    }
}
