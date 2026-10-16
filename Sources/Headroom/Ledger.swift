import CryptoKit
import Foundation

// MARK: - Aggregates

struct Agg: Codable {
    var input = 0
    var output = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    var cacheRead = 0
    var calls = 0
    /// Exact provider cost in 1e-10 USD ticks (Grok reports this; Claude cost comes from pricing).
    var costTicks: Int?
    /// Grok only: tokens of merged turns that reported no cost (R7). Optional so ledger caches written before it still
    /// decode; never set for Claude, whose missing costs come from the price table at summary time.
    var uncostedTokens: Int?

    var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }

    /// Field-wise growth from `old` to self (never negative); used when a streamed message is logged again.
    func growth(from old: Agg) -> Agg {
        Agg(input: max(input - old.input, 0), output: max(output - old.output, 0),
            cacheWrite5m: max(cacheWrite5m - old.cacheWrite5m, 0), cacheWrite1h: max(cacheWrite1h - old.cacheWrite1h, 0),
            cacheRead: max(cacheRead - old.cacheRead, 0), calls: 0)
    }

    func maxed(with o: Agg) -> Agg {
        Agg(input: max(input, o.input), output: max(output, o.output), cacheWrite5m: max(cacheWrite5m, o.cacheWrite5m),
            cacheWrite1h: max(cacheWrite1h, o.cacheWrite1h), cacheRead: max(cacheRead, o.cacheRead), calls: max(calls, o.calls))
    }

    mutating func add(_ o: Agg) {
        input += o.input; output += o.output
        cacheWrite5m += o.cacheWrite5m; cacheWrite1h += o.cacheWrite1h
        cacheRead += o.cacheRead; calls += o.calls
        if let t = o.costTicks { costTicks = (costTicks ?? 0) + t }
    }
}

/// A cost with its coverage (R7): the sum of the costs that are known, and how many tokens had a known or an unknown
/// cost. A missing price is never counted as $0. Claude costs are estimates at LiteLLM list prices; Grok costs are what
/// the Grok CLI reported. Neither is a bill.
struct CostEstimate: Equatable, Sendable {
    enum Coverage: Equatable, Sendable {
        /// Every token's cost is known (including no usage at all, and costs that are really zero).
        case complete
        /// Some tokens have a known cost and some don't; `known` is a lower bound.
        case partial
        /// There is usage but none of its cost is known.
        case unavailable
    }

    var known = 0.0
    var knownTokens = 0
    var unknownTokens = 0

    static let zero = CostEstimate()

    var coverage: Coverage {
        if unknownTokens == 0 { return .complete }
        return knownTokens == 0 && known == 0 ? .unavailable : .partial
    }

    /// The amount when complete; nil when any of it is unknown.
    var value: Double? { coverage == .complete ? known : nil }

    static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate {
        CostEstimate(known: a.known + b.known, knownTokens: a.knownTokens + b.knownTokens,
                     unknownTokens: a.unknownTokens + b.unknownTokens)
    }

    static func += (a: inout CostEstimate, b: CostEstimate) { a = a + b }
}

struct Totals {
    var tokens = 0
    var cost = CostEstimate.zero
}

struct DayBar: Identifiable {
    var id: String { "\(day.timeIntervalSince1970)-\(family)" }
    var day: Date
    var family: String
    var tokens: Int
    var cost: CostEstimate
}

struct ModelRow: Identifiable {
    var id: String { model }
    var model: String
    var tokens: Int
    var cost: CostEstimate
}

struct UsageSummary {
    var today = Totals()
    var week = Totals()
    var month = Totals()
    var window: Totals?
    var bars: [DayBar] = []
    var models: [ModelRow] = []
    var monthStart = Date()
}

extension UsageSummary {
    /// Adds two providers' summaries; the 5h window is Claude-only and comes from `a`.
    static func combine(_ a: UsageSummary?, _ b: UsageSummary?) -> UsageSummary? {
        guard var r = a ?? b else { return nil }
        guard let a, let b else { return r }
        // Estimates add field by field, so one provider's incomplete cost keeps the combined total incomplete (R7).
        func add(_ x: Totals, _ y: Totals) -> Totals { Totals(tokens: x.tokens + y.tokens, cost: x.cost + y.cost) }
        r.today = add(a.today, b.today)
        r.week = add(a.week, b.week)
        r.month = add(a.month, b.month)
        r.bars = (a.bars + b.bars).sorted { ($0.day, $0.family) < ($1.day, $1.family) }
        r.models = (a.models + b.models).sorted { $0.tokens > $1.tokens }
        return r
    }
}

extension UsageSummary {
    /// Models whose cost isn't fully known in the 30 days (R7), for the explanation under the totals.
    var uncostedModels: [String] { models.filter { $0.cost.coverage != .complete }.map(\.model).sorted() }

    /// Days whose cost isn't fully known, with the known part, so the chart can mark them instead of drawing what
    /// looks like a complete (or zero) cost.
    var incompleteCostDays: [(day: Date, known: Double)] {
        var days: [Date: CostEstimate] = [:]
        for b in bars { days[b.day, default: .zero] += b.cost }
        return days.filter { $0.value.coverage != .complete }.map { ($0.key, $0.value.known) }.sorted { $0.day < $1.day }
    }
}

func modelFamily(_ model: String) -> String {
    let m = model.lowercased()
    for f in ["opus", "fable", "sonnet", "haiku", "mythos"] where m.contains(f) { return f.prefix(1).uppercased() + f.dropFirst() }
    if m.hasPrefix("grok") { return "Grok" }
    return model
}

// MARK: - Pricing (reviewed LiteLLM snapshot, R6)

struct Price: Codable, Equatable {
    var input: Double
    var output: Double
    var cacheWrite: Double
    var cacheWrite1h: Double
    var cacheRead: Double
}

/// One exact LiteLLM revision of the price file and the SHA-256 it must have. Never a branch.
struct PricingPin: Equatable, Sendable {
    var revision: String
    var sourceSHA256: String
    var url: URL { URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/\(revision)/model_prices_and_context_window.json")! }
}

/// A price table built into the app, with the checksum of its exact text so a damaged build is noticed.
struct PricingBundle: Sendable {
    var revision: String
    var sourceSHA256: String
    var retrieved: String
    var tableSHA256: String
    var tableJSON: String
}

/// Which prices are in use. Costs are always estimates at list prices, never a provider bill.
struct PricingInfo: Equatable {
    enum Source: Equatable { case bundled, downloaded, unavailable }
    var source: Source
    /// LiteLLM commit the prices came from; nil when unavailable.
    var revision: String?
    /// When that revision was retrieved: for review (bundled) or by the user's download.
    var retrieved: String?

    static let unavailable = PricingInfo(source: .unavailable)
}

enum PricingUpdateError: Error, Equatable {
    /// The prices in use already come from the pinned revision; downloading it again would change nothing.
    case alreadyCurrent
    case inProgress
    case network
    case http(Int)
    /// The download isn't the pinned file.
    case checksumMismatch
    /// The pinned file doesn't yield a valid Claude price table.
    case invalidData
    case writeFailed
}

/// Claude prices for cost estimates. Loading is local only: the built-in snapshot, or a snapshot of the same pinned
/// revision the user downloaded explicitly. Nothing is downloaded at launch or because data is old (R6). The legacy
/// `pricing.json` from the old unpinned download is ignored and left in place.
final class Pricing: @unchecked Sendable {
    /// USD per token above which a price is treated as malformed ($1,000 per million tokens).
    static let maxPrice = 1e-3

    private let lock = NSLock()
    private var table: [String: Price] = [:]
    private var _info = PricingInfo.unavailable
    private var _generation = 0
    private var updating = false
    /// The explicitly downloaded upstream file, kept byte for byte so its SHA-256 can be checked against the compiled
    /// pin on every load (#28 review). Distinct from the legacy `pricing.json`.
    private let file: URL
    private let transport: HTTPTransport
    private let pin: PricingPin
    private let bundle: PricingBundle
    private let now: @Sendable () -> Date
    /// Sets the saved file's date (display only). Injectable so tests can make it fail.
    private let setDate: @Sendable (Date, URL) throws -> Void

    init(directory: URL, transport: HTTPTransport, pin: PricingPin = PricingSnapshot.pin,
         bundle: PricingBundle = PricingSnapshot.bundled, now: @escaping @Sendable () -> Date = { Date() },
         setDate: @escaping @Sendable (Date, URL) throws -> Void = { date, url in
             try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
         }) {
        self.file = directory.appendingPathComponent("pricing-source.json")
        self.transport = transport
        self.pin = pin
        self.bundle = bundle
        self.now = now
        self.setDate = setDate
    }

    var info: PricingInfo { lock.withLock { _info } }
    /// Changes whenever the table in use changes, so cached cost summaries are recomputed.
    var generation: Int { lock.withLock { _generation } }

    /// Installs local prices: the downloaded pinned file if its bytes still have the pinned SHA-256 and yield a valid
    /// table, else the built-in snapshot if it verifies, else none (costs unavailable). Nothing stored next to the
    /// download is trusted; only the compiled pin. Never touches the network.
    @discardableResult
    func load() -> PricingInfo {
        if let data = try? Data(contentsOf: file), Self.sha256(data) == pin.sourceSHA256, let t = Self.table(fromSource: data) {
            let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
            return install(t, PricingInfo(source: .downloaded, revision: pin.revision,
                                          retrieved: ISO8601DateFormatter().string(from: saved)))
        }
        let text = Data(bundle.tableJSON.utf8)
        if Self.sha256(text) == bundle.tableSHA256, let t = try? JSONDecoder().decode([String: Price].self, from: text),
           Self.valid(t) {
            return install(t, PricingInfo(source: .bundled, revision: bundle.revision, retrieved: bundle.retrieved))
        }
        return install([:], .unavailable)
    }

    /// The one explicit download: the pinned revision only, verified before it is parsed, validated, and written
    /// atomically before it replaces anything. On any failure the prices in use stay as they are.
    func update() async -> Result<PricingInfo, PricingUpdateError> {
        let start: PricingUpdateError? = lock.withLock {
            if _info.source != .unavailable && _info.revision == pin.revision { return .alreadyCurrent }
            if updating { return .inProgress }
            updating = true
            return nil
        }
        if let start { return .failure(start) }
        defer { lock.withLock { updating = false } }

        var request = URLRequest(url: pin.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let data: Data, response: URLResponse
        do { (data, response) = try await transport.data(for: request) } catch { return .failure(.network) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failure(.http(status)) }
        guard Self.sha256(data) == pin.sourceSHA256 else { return .failure(.checksumMismatch) }
        guard let t = Self.table(fromSource: data) else { return .failure(.invalidData) }
        let time = now()
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            return .failure(.writeFailed)
        }
        // Best effort: the date is only shown, never part of the integrity check. Once the verified file is saved the
        // update has succeeded, so a failure here must not report one (it would load on the next launch anyway).
        try? setDate(time, file)
        let retrieved = ISO8601DateFormatter().string(from: time)
        return .success(install(t, PricingInfo(source: .downloaded, revision: pin.revision, retrieved: retrieved)))
    }

    private func install(_ t: [String: Price], _ info: PricingInfo) -> PricingInfo {
        lock.withLock {
            table = t
            resolved = [:]
            _info = info
            _generation += 1
        }
        return info
    }

    /// The validated Claude table in an upstream LiteLLM file, or nil.
    static func table(fromSource data: Data) -> [String: Price]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = extract(json), valid(t)
        else { return nil }
        return t
    }

    /// Claude entries with input and output prices; missing cache prices use Anthropic's usual multiples. The same
    /// rules as `scripts/update-pricing-snapshot.py`. nil if nothing usable is found.
    static func extract(_ json: [String: Any]) -> [String: Price]? {
        func number(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.doubleValue
        }
        var t: [String: Price] = [:]
        for (k, v) in json where k.hasPrefix("claude") {
            guard let v = v as? [String: Any], let input = number(v["input_cost_per_token"]),
                  let output = number(v["output_cost_per_token"]) else { continue }
            t[k] = Price(input: input, output: output,
                         cacheWrite: number(v["cache_creation_input_token_cost"]) ?? input * 1.25,
                         cacheWrite1h: number(v["cache_creation_input_token_cost_above_1hr"]) ?? input * 2,
                         cacheRead: number(v["cache_read_input_token_cost"]) ?? input * 0.1)
        }
        return t.isEmpty ? nil : t
    }

    /// Non-empty, and every price finite, not negative and at most `maxPrice`.
    static func valid(_ t: [String: Price]) -> Bool {
        !t.isEmpty && t.values.allSatisfy { p in
            [p.input, p.output, p.cacheWrite, p.cacheWrite1h, p.cacheRead].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= maxPrice }
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var resolved: [String: Price?] = [:]

    /// The cost of `a` and its coverage (R7). Reported Grok ticks are used as they are; turns that reported none are
    /// unknown. Otherwise the price table decides; a model without a price is unknown, never $0. Tokens-free usage
    /// has nothing unknown.
    func estimate(model: String, _ a: Agg) -> CostEstimate {
        if let ticks = a.costTicks {
            let unknown = min(a.uncostedTokens ?? 0, a.total)
            return CostEstimate(known: Double(ticks) / 1e10, knownTokens: a.total - unknown, unknownTokens: unknown)
        }
        if a.uncostedTokens != nil { return CostEstimate(unknownTokens: a.total) } // Grok, no turn reported a cost
        guard let c = listCost(model: model, a) else { return CostEstimate(unknownTokens: a.total) }
        return CostEstimate(known: c, knownTokens: a.total)
    }

    /// The cost if fully known, else nil.
    func cost(model: String, _ a: Agg) -> Double? { estimate(model: model, a).value }

    private func listCost(model: String, _ a: Agg) -> Double? {
        let p: Price? = lock.withLock {
            if let hit = resolved[model] { return hit }
            var p = table[model]
            // claude-haiku-4-5-20251001 -> claude-haiku-4-5
            if p == nil, let r = model.range(of: #"-\d{8}$"#, options: .regularExpression) { p = table[String(model[..<r.lowerBound])] }
            if !table.isEmpty { resolved[model] = p }
            return p
        }
        guard let p else { return nil }
        return Double(a.input) * p.input + Double(a.output) * p.output + Double(a.cacheWrite5m) * p.cacheWrite
            + Double(a.cacheWrite1h) * p.cacheWrite1h + Double(a.cacheRead) * p.cacheRead
    }
}

// MARK: - Ledger

/// Why the usage cache isn't being saved, or an old one couldn't be removed (R8). Usage is still counted in memory.
enum LedgerCacheIssue: Equatable {
    case notSaved(StorageFailure)
    case legacyNotRemoved(StorageFailure)

    var text: String {
        switch self {
        case .notSaved(let f): return "Usage cache not saved: \(f.text). Totals are kept in memory only."
        case .legacyNotRemoved(let f): return "An old usage cache couldn't be removed: \(f.text)."
        }
    }
}

/// Why clearing the usage cache failed (R8).
enum LedgerClearFailure: Error, Equatable {
    /// Nothing was cleared.
    case cache(StorageFailure)
    /// The cache was deleted, but its key file or a leftover temporary file wasn't.
    case incomplete(StorageFailure)

    var text: String {
        switch self {
        case .cache(let f): return "Couldn't clear cached usage data: \(f.text). Nothing was cleared."
        case .incomplete(let f):
            return "Cached usage data was deleted, but its key file or a temporary file couldn't be removed: \(f.text)."
        }
    }
}

/// Incremental token ledger over Claude Code transcripts and Grok session usage files.
/// Claude: tail-reads ~/.claude/projects/**/*.jsonl by byte offset, dedupes on message id + request id
/// (same rule as ccusage), and buckets per hour and model. State is cached on disk so relaunches are instant.
///
/// The cache (R8) holds no transcript paths, message ids or request ids: files and messages are keyed by opaque ids,
/// a keyed hash (HMAC-SHA256, truncated to 128 bits) under a random per-install key kept in its own owner-only file.
/// Paths are only held in memory to read the files.
final class Ledger {
    private struct FileMark: Codable { var offset: UInt64 }
    /// What has been counted for one message id + request id, per model.
    private struct Seen: Codable { var hour: Int; var parts: [String: Agg] }
    /// Version 4 (R8): `files` and `seen` are keyed by opaque ids. Version 3 keyed them by raw paths and ids.
    private struct State: Codable {
        var version = 4
        /// An opaque id of a fixed input under the key the ids were made with, so a cache is only loaded with that key
        /// (a restored old cache next to a newer key would otherwise re-read and double count everything).
        var keyCheck = ""
        var files: [String: FileMark] = [:]
        var seen: [String: Seen] = [:]
        var hours: [Int: [String: Agg]] = [:]
    }
    static let cacheName = "claude-ledger.json"
    static let keyName = "claude-ledger.key"
    struct GrokTurn { var key: String; var hour: Int; var model: String; var agg: Agg }
    private struct GrokFile { var mtime: Date; var turns: [GrokTurn] }

    static let retentionDays = 32

    private let queue = DispatchQueue(label: "headroom.ledger", qos: .utility)
    private var state = State()
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private var grokFiles: [String: GrokFile] = [:]
    /// Transcripts modified in the last two hours; tailed on every refresh between full scans.
    private var hotFiles: Set<String> = []
    private var lastFullScan = Date.distantPast
    /// Newest transcript write seen (Claude or Grok), used to tell when an agent is working.
    private var lastActivity = Date.distantPast
    private var changeCounter = 0
    private var lastSummaryKey = ""
    private var cachedSummaries: (UsageSummary, UsageSummary)?
    private let storage: PrivateDirectory
    /// Key for the opaque ids. Loaded (or made) before anything is scanned, since ids are computed while indexing.
    private var key = SymmetricKey(size: .bits256)
    private var keyPersisted = false
    private let issueLock = NSLock()
    private var issue: LedgerCacheIssue?
    private let home: URL
    private let pricing: Pricing
    private let usageNeedle = Array(#""usage":{"#.utf8)

    /// The current time and the calendar for day boundaries. Injectable so accounting fixtures (#6) can pin "now" and
    /// the time zone; by default the real clock and `Calendar.current`, read on every use as before.
    private let now: @Sendable () -> Date
    private let fixedCalendar: Calendar?
    private var calendar: Calendar { fixedCalendar ?? .current }

    init(home: URL, appSupport: URL, pricing: Pricing, storage: PrivateDirectory? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar? = nil) {
        self.home = home
        self.storage = storage ?? PrivateDirectory(url: appSupport)
        self.pricing = pricing
        self.now = now
        self.fixedCalendar = calendar
    }

    /// Why the cache isn't being saved, if it isn't; nil when it is (or nothing was tried yet).
    var cacheIssue: LedgerCacheIssue? { issueLock.withLock { issue } }
    private func setIssue(_ i: LedgerCacheIssue?) { issueLock.withLock { issue = i } }

    // MARK: Opaque ids (R8)

    /// HMAC-SHA256 over a domain and length-prefixed parts, so different kinds and splits of input can't collide.
    private func opaqueID(_ domain: String, _ parts: String...) -> String {
        var mac = HMAC<SHA256>(key: key)
        for part in [domain] + parts {
            let bytes = Data(part.utf8)
            mac.update(data: withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { Data($0) })
            mac.update(data: bytes)
        }
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(32)
        for b in Data(mac.finalize()).prefix(16) {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func fileID(_ path: String) -> String { opaqueID("file", path) }
    private var keyCheck: String { opaqueID("key-check") }
    private func messageID(_ id: String, _ request: String) -> String { opaqueID("message", id, request) }

    private var claudeRoots: [URL] {
        [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
    }

    /// Scans for new data and returns summaries. `progress` reports indexing on first run.
    func refresh(windowStart: Date?, progress: @escaping (String?) -> Void,
                 completion: @escaping (_ claude: UsageSummary, _ grok: UsageSummary, _ lastActivity: Date) -> Void) {
        queue.async { [self] in
            if !loaded { loadCache(); loaded = true }
            let full = now().timeIntervalSince(lastFullScan) >= 300
            if full {
                scanClaude(progress: progress)
                scanGrok()
                lastFullScan = now()
            } else {
                discoverNewFiles()
                tailHotFiles()
                scanGrok()
            }
            // Encoding the cache is the most expensive step, so only persist occasionally (and on quit).
            if dirty, lastSave == .distantPast || now().timeIntervalSince(lastSave) > 600 {
                saveCache()
            }
            progress(nil)
            // Summaries only change with new data, a new window, a new day or new prices.
            let key = "\(changeCounter)|\(windowStart?.timeIntervalSince1970 ?? 0)|\(calendar.startOfDay(for: now()).timeIntervalSince1970)|\(pricing.generation)"
            if key != lastSummaryKey || cachedSummaries == nil {
                cachedSummaries = (summarize(claudeHours(), windowStart: windowStart), summarize(grokHours(), windowStart: nil))
                lastSummaryKey = key
            }
            completion(cachedSummaries!.0, cachedSummaries!.1, lastActivity)
        }
    }

    func flush() {
        queue.sync { if dirty { saveCache() } }
    }

    /// Deletes the usage cache and its key (R8), on the ledger queue so it can't interleave with a refresh or a save.
    /// Resets everything in memory, so the next refresh re-reads the transcripts from scratch and nothing from before
    /// the clear is saved again. Transcripts, pricing files and settings are not touched. If the cache can't be
    /// deleted, nothing is reset.
    func clearCache(completion: @escaping (LedgerClearFailure?) -> Void) {
        queue.async { [self] in completion(clear()) }
    }

    private func clear() -> LedgerClearFailure? {
        // Leftover temp files are listed first: if the folder can't be listed, nothing is deleted at all.
        let leftovers: [String]
        do {
            leftovers = try storage.temporaryFiles(of: Self.cacheName) + storage.temporaryFiles(of: Self.keyName)
            try storage.remove(Self.cacheName)
        } catch {
            return .cache(error as? StorageFailure ?? .io(EIO))
        }
        state = State()
        loaded = true
        dirty = false
        lastSave = .distantPast
        key = SymmetricKey(size: .bits256)
        keyPersisted = false
        hotFiles = []
        grokFiles = [:]
        lastFullScan = .distantPast
        changeCounter += 1
        cachedSummaries = nil
        lastSummaryKey = ""
        setIssue(nil)
        do {
            for item in leftovers { try storage.remove(item) }
            try storage.remove(Self.keyName)
        } catch {
            return .incomplete(error as? StorageFailure ?? .io(EIO))
        }
        return nil
    }

    // MARK: Claude

    private func scanClaude(progress: (String?) -> Void) {
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var candidates: [(path: String, id: String, size: UInt64)] = []
        var present = Set<String>()
        var hot = Set<String>()
        let hotCutoff = now().addingTimeInterval(-2 * 3600)

        for root in claudeRoots {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let mtime = v.contentModificationDate, mtime >= cutoff else { continue }
                let path = url.path
                let id = fileID(path)
                present.insert(id)
                if mtime >= hotCutoff { hot.insert(path); lastActivity = max(lastActivity, mtime) }
                let size = UInt64(v.fileSize ?? 0)
                if state.files[id]?.offset != size { candidates.append((path, id, size)) }
            }
        }

        hotFiles = hot
        let initial = state.files.isEmpty
        for (i, (path, id, size)) in candidates.enumerated() {
            if initial, i % 25 == 0 { progress("Indexing Claude logs \(i)/\(candidates.count)") }
            var offset = state.files[id]?.offset ?? 0
            if size < offset { offset = 0 } // rewritten file; dedupe keys prevent double counting
            offset = ingestClaudeFile(path, from: offset)
            state.files[id] = FileMark(offset: offset)
            dirty = true
        }

        // Forget files that aged out or were removed, and prune old buckets and dedupe keys.
        let stale = state.files.keys.filter { !present.contains($0) }
        if !stale.isEmpty { stale.forEach { state.files.removeValue(forKey: $0) }; dirty = true }
        let minHour = Int(cutoff.timeIntervalSince1970 / 3600)
        if state.hours.keys.contains(where: { $0 < minHour }) {
            state.hours = state.hours.filter { $0.key >= minHour }
            state.seen = state.seen.filter { $0.value.hour >= minHour }
            dirty = true
        }
    }

    /// Cheap new-file check between full scans: only lists project folders touched in the last two hours.
    private func discoverNewFiles() {
        let hotCutoff = now().addingTimeInterval(-2 * 3600)
        let fm = FileManager.default
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) >= hotCutoff
        }
        for root in claudeRoots {
            guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for dir in projects where recent(dir) {
                guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in items where f.pathExtension == "jsonl" && !hotFiles.contains(f.path) && recent(f) {
                    hotFiles.insert(f.path)
                }
            }
        }
        // Subagent transcripts live next to their parent session.
        for path in hotFiles where path.hasSuffix(".jsonl") && !path.contains("/subagents/") {
            let sub = URL(fileURLWithPath: String(path.dropLast(6))).appendingPathComponent("subagents")
            guard recent(sub), let items = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) else { continue }
            for f in items where f.pathExtension == "jsonl" { hotFiles.insert(f.path) }
        }
    }

    private func tailHotFiles() {
        for path in hotFiles {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            if let m = attrs[.modificationDate] as? Date { lastActivity = max(lastActivity, m) }
            let id = fileID(path)
            var offset = state.files[id]?.offset ?? 0
            if size == offset { continue }
            if size < offset { offset = 0 }
            state.files[id] = FileMark(offset: ingestClaudeFile(path, from: offset))
            dirty = true
        }
    }

    /// Reads complete lines from `offset` and returns the new offset (just past the last newline).
    /// The file is memory-mapped, so even multi-hundred-megabyte transcripts are not copied into memory.
    private func ingestClaudeFile(_ path: String, from offset: UInt64) -> UInt64 {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
              UInt64(data.count) > offset else { return offset }
        let consumed = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return Int(offset) }
            let n = raw.count
            var start = Int(offset)
            while start < n, let nl = memchr(base + start, 0x0A, n - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start, memmem(base + start, end - start, usageNeedle, usageNeedle.count) != nil {
                    autoreleasepool {
                        ingestClaudeLine(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                              count: end - start, deallocator: .none))
                    }
                }
                start = end + 1
            }
            return start
        }
        return UInt64(consumed)
    }

    private func ingestClaudeLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj.string("type") == "assistant",
              let msg = obj.dict("message"), let usage = msg.dict("usage"),
              let date = ISO.parse(obj.string("timestamp")) else { return }
        let model = msg.string("model") ?? "unknown"
        if model == "<synthetic>" { return }
        let hour = Int(date.timeIntervalSince1970 / 3600)

        var parts: [String: Agg] = [model: Self.agg(usage)]
        // Sub-calls made inside a turn (e.g. the advisor) are listed as extra iterations with their own
        // model; the top-level usage only covers the main model's iterations.
        for it in usage["iterations"] as? [[String: Any]] ?? [] {
            guard let sub = it.string("model"), sub != model, it.string("type") != "message" else { continue }
            parts[sub, default: Agg(calls: 0)].add(Self.agg(it))
        }

        guard let id = msg.string("id"), let req = obj.string("requestId") else {
            for (m, a) in parts { state.hours[hour, default: [:]][m, default: Agg()].add(a) }
            changeCounter += 1
            return
        }
        let key = messageID(id, req)
        if var old = state.seen[key] {
            // Streaming logs the same message several times with growing counts; count only the growth.
            for (m, a) in parts {
                let prev = old.parts[m] ?? Agg(calls: 0)
                let delta = a.growth(from: prev)
                guard delta.total > 0 else { continue }
                state.hours[old.hour, default: [:]][m, default: Agg()].add(delta)
                old.parts[m] = a.maxed(with: prev)
                changeCounter += 1
            }
            state.seen[key] = old
        } else {
            for (m, a) in parts { state.hours[hour, default: [:]][m, default: Agg()].add(a) }
            state.seen[key] = Seen(hour: hour, parts: parts)
            changeCounter += 1
        }
    }

    private static func agg(_ usage: [String: Any]) -> Agg {
        var a = Agg(input: usage.int("input_tokens"), output: usage.int("output_tokens"),
                    cacheRead: usage.int("cache_read_input_tokens"), calls: 1)
        let created = usage.int("cache_creation_input_tokens")
        if let cc = usage.dict("cache_creation") {
            a.cacheWrite1h = cc.int("ephemeral_1h_input_tokens")
            a.cacheWrite5m = cc.int("ephemeral_5m_input_tokens")
            // Fall back to the flat total when the breakdown does not add up.
            if a.cacheWrite1h + a.cacheWrite5m != created { a.cacheWrite5m = created; a.cacheWrite1h = 0 }
        } else {
            a.cacheWrite5m = created
        }
        return a
    }

    private func claudeHours() -> [Int: [String: Agg]] { state.hours }

    /// Claude's hour buckets (hours since 1970 UTC, then model), read on the ledger queue. For accounting fixtures and
    /// audits (#6); the app doesn't use it.
    func claudeHourlyUsage(completion: @escaping ([Int: [String: Agg]]) -> Void) {
        queue.async { [self] in completion(state.hours) }
    }

    // MARK: Grok

    private func scanGrok() {
        let root = home.appendingPathComponent(".grok/sessions")
        guard let projects = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        var present = Set<String>()
        for p in projects {
            let dir = root.appendingPathComponent(p)
            guard let sessions = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for s in sessions {
                let url = dir.appendingPathComponent(s).appendingPathComponent("usage.json")
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
                present.insert(url.path)
                lastActivity = max(lastActivity, mtime)
                if grokFiles[url.path]?.mtime == mtime { continue }
                grokFiles[url.path] = GrokFile(mtime: mtime, turns: parseGrokUsage(url))
                changeCounter += 1
            }
        }
        grokFiles = grokFiles.filter { present.contains($0.key) }
    }

    private func parseGrokUsage(_ url: URL) -> [GrokTurn] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let turns = json["turns"] as? [[String: Any]] else { return [] }
        return turns.compactMap { t in
            guard let ended = t.string("endedAt"), let date = ISO.parse(ended) else { return nil }
            let cached = t.int("cachedReadTokens")
            let agg = Agg(input: max(t.int("inputTokens") - cached, 0), output: t.int("outputTokens"),
                          cacheWrite5m: t.int("cacheCreationTokens"), cacheRead: cached,
                          calls: t.int("modelCalls"), costTicks: t.optionalInt("costUsdTicks"))
            // Resumed and forked sessions repeat inherited turns, so dedupe on content. The key (unchanged by R7) reads
            // a missing cost as 0, so a turn without a cost and a copy reporting $0 are the same turn; `uniqueGrokTurns`
            // decides which copy counts.
            let key = "\(ended)|\(t.int("totalTokens"))|\(t.int("costUsdTicks"))"
            return GrokTurn(key: key, hour: Int(date.timeIntervalSince1970 / 3600),
                            model: t.string("primaryModelId") ?? "grok", agg: agg)
        }
    }

    /// One turn per dedupe key, chosen the same way whatever order the files and turns are read in (R7): a copy that
    /// reports a cost wins over one that doesn't, then the lowest model and token counts. Otherwise whether a turn's
    /// cost is known would depend on which file came first.
    static func uniqueGrokTurns(_ turns: [GrokTurn]) -> [GrokTurn] {
        func rank(_ t: GrokTurn) -> (Int, String, Int, Int, Int, Int) {
            (t.agg.costTicks == nil ? 1 : 0, t.model, t.agg.input, t.agg.output, t.agg.cacheWrite5m, t.agg.cacheRead)
        }
        var best: [String: GrokTurn] = [:]
        for t in turns {
            if let b = best[t.key], rank(b) < rank(t) || (rank(b) == rank(t) && b.agg.calls <= t.agg.calls) { continue }
            best[t.key] = t
        }
        return Array(best.values)
    }

    private func grokHours() -> [Int: [String: Agg]] {
        var hours: [Int: [String: Agg]] = [:]
        for t in Self.uniqueGrokTurns(grokFiles.values.flatMap(\.turns)) {
            var a = hours[t.hour, default: [:]][t.model, default: Agg()]
            a.add(t.agg)
            // A turn without a reported cost stays unknown after merging with turns that have one (R7).
            if t.agg.costTicks == nil { a.uncostedTokens = (a.uncostedTokens ?? 0) + t.agg.total }
            hours[t.hour, default: [:]][t.model] = a
        }
        return hours
    }

    // MARK: Summaries

    /// Calendar-day windows like ccusage: today, the last 7 days and the last 30 days, all including today.
    private func summarize(_ hours: [Int: [String: Agg]], windowStart: Date?) -> UsageSummary {
        let cal = calendar
        let today = cal.startOfDay(for: now())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let monthStart = cal.date(byAdding: .day, value: -29, to: today)!
        let windowHour = windowStart.map { Int($0.timeIntervalSince1970 / 3600) }

        var s = UsageSummary(monthStart: monthStart)
        if windowHour != nil { s.window = Totals() }
        var bars: [String: DayBar] = [:]
        var models: [String: (Int, CostEstimate)] = [:]

        for (hour, byModel) in hours {
            let date = Date(timeIntervalSince1970: Double(hour) * 3600)
            guard date >= monthStart else { continue }
            let day = cal.startOfDay(for: date)
            for (model, a) in byModel {
                let c = pricing.estimate(model: model, a)
                let t = a.total
                s.month.tokens += t; s.month.cost += c
                if date >= weekStart { s.week.tokens += t; s.week.cost += c }
                if date >= today { s.today.tokens += t; s.today.cost += c }
                if let wh = windowHour, hour >= wh { s.window!.tokens += t; s.window!.cost += c }

                let family = modelFamily(model)
                let key = "\(day.timeIntervalSince1970)-\(family)"
                var bar = bars[key] ?? DayBar(day: day, family: family, tokens: 0, cost: .zero)
                bar.tokens += t; bar.cost += c
                bars[key] = bar

                var m = models[model] ?? (0, .zero)
                m.0 += t
                m.1 += c
                models[model] = m
            }
        }
        s.bars = bars.values.sorted { ($0.day, $0.family) < ($1.day, $1.family) }
        s.models = models.map { ModelRow(model: $0.key, tokens: $0.value.0, cost: $0.value.1) }
            .sorted { $0.tokens > $1.tokens }
        return s
    }

    // MARK: Cache

    /// Loads the key, then the cache (R8). Anything else at the cache path is deleted at once and the transcripts are
    /// re-indexed: a version 3 cache (raw paths and ids), a corrupt file, a cache whose key is gone or different, or a
    /// symlink.
    /// If the folder can't be made owner-only nothing is read, and usage is kept in memory with a fresh key.
    private func loadCache() {
        key = SymmetricKey(size: .bits256)
        keyPersisted = false
        do {
            try storage.prepare()
            try storage.removeTemporaryFiles(of: Self.cacheName)
            try storage.removeTemporaryFiles(of: Self.keyName)
        } catch {
            setIssue(.notSaved(error as? StorageFailure ?? .io(EIO)))
            return
        }
        if let k = try? storage.read(Self.keyName), k.count == 32 {
            key = SymmetricKey(data: k)
            keyPersisted = true
        }
        let data: Data?
        do { data = try storage.read(Self.cacheName) } catch { data = Data() } // unreadable: discard
        guard let data else { return }
        if keyPersisted, let s = try? JSONDecoder().decode(State.self, from: data), s.version == State().version,
           s.keyCheck == keyCheck {
            state = s
            return
        }
        do { try storage.remove(Self.cacheName) } catch {
            setIssue(.legacyNotRemoved(error as? StorageFailure ?? .io(EIO)))
        }
    }

    /// Writes the key (once) and then the cache, both owner-only. On failure nothing is written elsewhere; the issue
    /// is reported and the save retried later.
    private func saveCache() {
        state.keyCheck = keyCheck
        guard let data = try? JSONEncoder().encode(state) else { return }
        lastSave = now()
        do {
            if !keyPersisted {
                try storage.write(key.withUnsafeBytes { Data($0) }, to: Self.keyName)
                keyPersisted = true
            }
            try storage.write(data, to: Self.cacheName)
            dirty = false
            setIssue(nil)
        } catch {
            setIssue(.notSaved(error as? StorageFailure ?? .io(EIO)))
        }
    }
}
