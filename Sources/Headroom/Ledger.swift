import CryptoKit
import Foundation

// MARK: - Aggregates

struct Agg: Codable, Equatable {
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
    /// P9 (#58), Claude only: cache-write tokens whose 5-minute/1-hour tier is unknown, because the breakdown doesn't
    /// match the flat total or can't be read. The flat total is the quantity; the cost is a minimum at the cheaper
    /// tier's rate. Optional (and saved only when set) so ordinary buckets stay small.
    var cacheWriteUnresolved: Int?
    /// P9 (#58), Claude only: cache-write tokens the breakdown reports beyond the flat total. Counted provisionally
    /// (the larger source wins) with an unknown cost; neither a verified count nor a lower bound.
    var cacheWriteDisputed: Int?

    var unresolved: Int { cacheWriteUnresolved ?? 0 }
    var disputed: Int { cacheWriteDisputed ?? 0 }
    /// Tokens whose tier is known: what the price table prices exactly.
    var resolved: Int { [output, cacheWrite5m, cacheWrite1h, cacheRead].reduce(input) { $0.saturatingAdd($1) } }
    /// Saturating, like `add`: counters are validated below 2^53 (#58), but enough of them must still not trap.
    var total: Int { resolved.saturatingAdd(unresolved).saturatingAdd(disputed) }
    /// A counter or the total was held at `Int.max`, so the true value is unknown (#58).
    var isSaturated: Bool { [input, output, cacheWrite5m, cacheWrite1h, cacheRead, unresolved, disputed, total].contains(.max) }

    private static func optional(_ n: Int) -> Int? { n == 0 ? nil : n }

    /// The cache writes' quantity, however they are classified: tiered, tier-unresolved and disputed together.
    var cacheWrites: Int {
        cacheWrite5m.saturatingAdd(cacheWrite1h).saturatingAdd(unresolved).saturatingAdd(disputed)
    }

    /// What one operation reported, from two of its records (#58): streaming logs a message several times with growing
    /// counts. Other counters keep their largest value. Cache writes are one quantity whose classification can change
    /// between records, so their fields are never maxed one by one (a reclassification would count twice): the larger
    /// quantity wins with its classification. At equal quantity the less certain wins (disputed, then tier-unresolved,
    /// then tiered), and two tier splits that disagree make the tier unknown rather than picking one. The result
    /// doesn't depend on which record came first, nor on how records are grouped (it's commutative and associative),
    /// so arrival order, rescans and #55 merges all reach the same operation.
    func reconciled(with o: Agg) -> Agg {
        var r = Agg(input: max(input, o.input), output: max(output, o.output), cacheRead: max(cacheRead, o.cacheRead),
                    calls: max(calls, o.calls))
        let q = cacheWrites, oq = o.cacheWrites
        if q != oq {
            let w = q > oq ? self : o
            r.cacheWrite5m = w.cacheWrite5m; r.cacheWrite1h = w.cacheWrite1h
            r.cacheWriteUnresolved = w.cacheWriteUnresolved; r.cacheWriteDisputed = w.cacheWriteDisputed
            return r
        }
        let d = max(disputed, o.disputed)
        if cacheWrite5m == o.cacheWrite5m && cacheWrite1h == o.cacheWrite1h {
            r.cacheWrite5m = cacheWrite5m; r.cacheWrite1h = cacheWrite1h
        }
        r.cacheWriteDisputed = Self.optional(d)
        // Never negative: when the splits agree, the record with the larger disputed part leaves exactly its own rest.
        r.cacheWriteUnresolved = Self.optional(max(q - d - r.cacheWrite5m - r.cacheWrite1h, 0))
        return r
    }

    /// `self - o` field by field, and possibly negative: what to add to a bucket that holds `o` so it holds `self`
    /// instead. Adds no calls.
    func difference(from o: Agg) -> Agg {
        Agg(input: input - o.input, output: output - o.output, cacheWrite5m: cacheWrite5m - o.cacheWrite5m,
            cacheWrite1h: cacheWrite1h - o.cacheWrite1h, cacheRead: cacheRead - o.cacheRead, calls: 0,
            cacheWriteUnresolved: Self.optional(unresolved - o.unresolved),
            cacheWriteDisputed: Self.optional(disputed - o.disputed))
    }

    /// Some counter goes down, as in a reclassification's difference.
    var hasDecrease: Bool { [input, output, cacheWrite5m, cacheWrite1h, cacheRead, unresolved, disputed].contains { $0 < 0 } }

    mutating func add(_ o: Agg) {
        input = input.saturatingAdd(o.input); output = output.saturatingAdd(o.output)
        cacheWrite5m = cacheWrite5m.saturatingAdd(o.cacheWrite5m); cacheWrite1h = cacheWrite1h.saturatingAdd(o.cacheWrite1h)
        cacheRead = cacheRead.saturatingAdd(o.cacheRead); calls += o.calls
        if let t = o.costTicks { costTicks = (costTicks ?? 0) + t }
        if o.unresolved != 0 { cacheWriteUnresolved = Self.optional(unresolved.saturatingAdd(o.unresolved)) }
        if o.disputed != 0 { cacheWriteDisputed = Self.optional(disputed.saturatingAdd(o.disputed)) }
    }

    /// Takes back `o`, which was added before. Only for sums that aren't held (`isSaturated`).
    mutating func subtract(_ o: Agg) {
        input -= o.input; output -= o.output
        cacheWrite5m -= o.cacheWrite5m; cacheWrite1h -= o.cacheWrite1h
        cacheRead -= o.cacheRead; calls -= o.calls
        cacheWriteUnresolved = Self.optional(unresolved - o.unresolved)
        cacheWriteDisputed = Self.optional(disputed - o.disputed)
    }
}

extension Int {
    /// `self + o`, held at `Int.max` or `Int.min` instead of trapping (#58: a crafted transcript mustn't crash the app).
    func saturatingAdd(_ o: Int) -> Int {
        let (r, overflow) = addingReportingOverflow(o)
        return overflow ? (o > 0 ? .max : .min) : r
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
    /// Tokens without a price (Claude) or a reported cost (Grok).
    var unknownTokens = 0
    /// P9 (#58): the least the tier-unresolved cache writes can cost, at the cheaper tier's list price. A lower bound,
    /// kept apart from `known`, which is exact at list prices.
    var minimum = 0.0
    var minimumTokens = 0
    /// P9 (#58): provisional cache-write tokens beyond the flat total. Their cost is unknown, and no bound is claimed.
    var disputedTokens = 0
    /// The part of `disputedTokens` whose model has no price (#58): already counted there, never again in
    /// `unknownTokens`, and kept so the model is still named as unpriced when all its tokens are disputed.
    var unpricedDisputedTokens = 0

    static let zero = CostEstimate()

    var coverage: Coverage {
        if unknownTokens == 0 && minimumTokens == 0 && disputedTokens == 0 { return .complete }
        return knownTokens == 0 && known == 0 && minimumTokens == 0 ? .unavailable : .partial
    }

    /// The amount when complete; nil when any of it is unknown.
    var value: Double? { coverage == .complete ? known : nil }
    /// P9 (#58): some cache-write quantities disagree between the logs' sources, so even the flat totals behind
    /// `minimum` aren't verified, and no lower bound is claimed: the cost is a provisional estimate.
    var isProvisional: Bool { disputedTokens > 0 }
    /// The amount shown for a partial cost: the exact part plus the minimum for tier-unresolved writes. A lower bound
    /// unless `isProvisional`; with unpriced tokens the true cost may be higher, never lower.
    var amount: Double { known + minimum }

    static func + (a: CostEstimate, b: CostEstimate) -> CostEstimate {
        CostEstimate(known: a.known + b.known, knownTokens: a.knownTokens.saturatingAdd(b.knownTokens),
                     unknownTokens: a.unknownTokens.saturatingAdd(b.unknownTokens), minimum: a.minimum + b.minimum,
                     minimumTokens: a.minimumTokens.saturatingAdd(b.minimumTokens),
                     disputedTokens: a.disputedTokens.saturatingAdd(b.disputedTokens),
                     unpricedDisputedTokens: a.unpricedDisputedTokens.saturatingAdd(b.unpricedDisputedTokens))
    }

    static func += (a: inout CostEstimate, b: CostEstimate) { a = a + b }
}

/// How the records behind a total were told apart (#55, P4), independent of cost coverage (R7). The unit is an
/// identity group: everything counted under one identity (a pair, one id, or a fingerprint), i.e. one logged message
/// with its streamed copies. It is not a count of model calls: a message's `iterations` can add calls of other models
/// under the same group (F13: 2 calls, 1 group). Only groups with both a message id and a request id are certain;
/// every other kind means the token count may be approximate.
struct IdentityCoverage: Codable, Equatable, Sendable {
    /// Message id + request id.
    var identified = 0
    /// One id only: counted alone, or joined to the one pair that carries the same id.
    var incomplete = 0
    /// Neither id: a keyed fingerprint of timestamp, model and counters. Changed counters count again, and distinct
    /// messages with identical fingerprints count once.
    var fingerprinted = 0
    /// One id only, but more than one pair carries it: counted on its own, joined to neither.
    var ambiguous = 0

    enum Kind: String, Codable { case identified, incomplete, fingerprinted, ambiguous }

    /// No group in the total was identified by anything less than both ids.
    var isExact: Bool { incomplete == 0 && fingerprinted == 0 && ambiguous == 0 }
    var groups: Int { identified + incomplete + fingerprinted + ambiguous }
    var uncertain: Int { groups - identified }

    mutating func add(_ kind: Kind, _ n: Int = 1) {
        switch kind {
        case .identified: identified += n
        case .incomplete: incomplete += n
        case .fingerprinted: fingerprinted += n
        case .ambiguous: ambiguous += n
        }
    }

    static func + (a: IdentityCoverage, b: IdentityCoverage) -> IdentityCoverage {
        IdentityCoverage(identified: a.identified + b.identified, incomplete: a.incomplete + b.incomplete,
                         fingerprinted: a.fingerprinted + b.fingerprinted, ambiguous: a.ambiguous + b.ambiguous)
    }

    static func += (a: inout IdentityCoverage, b: IdentityCoverage) { a = a + b }
}

/// What the ledger couldn't read (#58, P7/P8), independent of identity (#55), cost coverage (R7) and cache issues (R8).
/// Claude only. Records that can't be read aren't in any total, so a total with any of them may be low; a message
/// counted with an invalid counter left out is a lower bound too. Records that aren't usage (user records,
/// `<synthetic>`, other types, an assistant record without usage) are ignored and never counted here.
struct DataCompleteness: Decodable, Equatable, Sendable {
    /// Logged messages (identity groups) counted with at least one invalid counter left out: negative, fractional,
    /// not a number, or too large. Their valid counters count. In the 15-minute slot of the message, like its tokens.
    var flawed = 0
    /// Records with a timestamp whose usage isn't an object. Not counted; in their own slot.
    var invalidUsage = 0
    /// Usage records whose timestamp is missing or can't be parsed. Not counted, and with no period: reported with
    /// every period, since they could belong to any.
    var undated = 0
    /// Lines with a `"usage"` key that aren't a JSON object: malformed JSON or invalid UTF-8. Not counted; no period.
    var malformed = 0
    /// Transcripts whose last line has no newline yet (P6). Read once it is finished, so not a gap in itself; it is
    /// normal while Claude Code is writing. Reported with every period.
    var pending = 0

    var unread: Int { invalidUsage + undated + malformed }
    /// Every record that looked like usage was read with valid counters. Pending lines don't count against it.
    var isComplete: Bool { flawed == 0 && unread == 0 }

    init(flawed: Int = 0, invalidUsage: Int = 0, undated: Int = 0, malformed: Int = 0, pending: Int = 0) {
        self.flawed = flawed; self.invalidUsage = invalidUsage; self.undated = undated
        self.malformed = malformed; self.pending = pending
    }

    /// Fields left out are 0, so a fixture names only what it expects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ k: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: k) ?? 0 }
        self.init(flawed: try n(.flawed), invalidUsage: try n(.invalidUsage), undated: try n(.undated),
                  malformed: try n(.malformed), pending: try n(.pending))
    }

    private enum CodingKeys: String, CodingKey { case flawed, invalidUsage, undated, malformed, pending }

    static func + (a: DataCompleteness, b: DataCompleteness) -> DataCompleteness {
        DataCompleteness(flawed: a.flawed + b.flawed, invalidUsage: a.invalidUsage + b.invalidUsage,
                         undated: a.undated + b.undated, malformed: a.malformed + b.malformed, pending: a.pending + b.pending)
    }

    static func += (a: inout DataCompleteness, b: DataCompleteness) { a = a + b }
}

/// Whether token quantities are exact (#58), independent of identity, completeness and cost coverage. Claude only.
struct QuantityUncertainty: Decodable, Equatable, Sendable {
    /// P9: cache-write tokens counted provisionally because a breakdown exceeds its flat total. The true amount may be
    /// lower or higher.
    var disputedTokens = 0
    /// A sum exceeded `Int.max` and was held there: the total shown is less than the true one.
    var saturated = false

    var isExact: Bool { disputedTokens == 0 && !saturated }

    init(disputedTokens: Int = 0, saturated: Bool = false) {
        self.disputedTokens = disputedTokens; self.saturated = saturated
    }

    /// Fields left out are 0 or false, so a fixture names only what it expects.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(disputedTokens: try c.decodeIfPresent(Int.self, forKey: .disputedTokens) ?? 0,
                  saturated: try c.decodeIfPresent(Bool.self, forKey: .saturated) ?? false)
    }

    private enum CodingKeys: String, CodingKey { case disputedTokens, saturated }

    static func + (a: QuantityUncertainty, b: QuantityUncertainty) -> QuantityUncertainty {
        QuantityUncertainty(disputedTokens: a.disputedTokens.saturatingAdd(b.disputedTokens),
                            saturated: a.saturated || b.saturated)
    }

    static func += (a: inout QuantityUncertainty, b: QuantityUncertainty) { a = a + b }
}

struct Totals {
    var tokens = 0
    var cost = CostEstimate.zero
    /// Claude only; Grok turns are deduplicated by their own rule and aren't counted here.
    var identity = IdentityCoverage()
    /// Claude only (#58): an unread Claude record says nothing about Grok.
    var completeness = DataCompleteness()
    /// Claude only (#58).
    var quantity = QuantityUncertainty()

    /// Adds `t` tokens, holding the sum at `Int.max` and saying so instead of trapping (#58). A sum that lands on
    /// `Int.max` can't be told from a held one, so it counts as held too.
    mutating func addTokens(_ t: Int, saturated: Bool = false) {
        let (r, overflow) = tokens.addingReportingOverflow(t)
        tokens = overflow ? .max : r
        if saturated || tokens == .max { quantity.saturated = true }
    }
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
        func add(_ x: Totals, _ y: Totals) -> Totals {
            var t = Totals(cost: x.cost + y.cost, identity: x.identity + y.identity,
                           completeness: x.completeness + y.completeness, quantity: x.quantity + y.quantity)
            t.addTokens(x.tokens)
            t.addTokens(y.tokens)
            return t
        }
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
    var uncostedModels: [String] {
        models.filter { $0.cost.unknownTokens > 0 || $0.cost.unpricedDisputedTokens > 0 }.map(\.model).sorted()
    }

    /// Priced models whose cache writes have an unknown tier or a disputed amount (P9, #58).
    var uncertainCacheModels: [String] {
        models.filter { $0.cost.minimumTokens > 0 || $0.cost.disputedTokens > 0 }.map(\.model).sorted()
    }

    /// Days whose cost isn't fully known, with the known part, so the chart can mark them instead of drawing what
    /// looks like a complete (or zero) cost.
    var incompleteCostDays: [(day: Date, cost: CostEstimate)] {
        var days: [Date: CostEstimate] = [:]
        for b in bars { days[b.day, default: .zero] += b.cost }
        return days.filter { $0.value.coverage != .complete }.map { ($0.key, $0.value) }.sorted { $0.day < $1.day }
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
        guard let (c, p) = listCost(model: model, a) else {
            // No price: everything is unknown, but disputed tokens stay disputed (counted once), so a total that holds
            // them is still provisional (P9, #58).
            return CostEstimate(unknownTokens: a.total - a.disputed, disputedTokens: a.disputed,
                                unpricedDisputedTokens: a.disputed)
        }
        // P9: unresolved writes cost at least the cheaper tier's rate; disputed ones aren't priced at all.
        return CostEstimate(known: c, knownTokens: a.resolved, minimum: Double(a.unresolved) * min(p.cacheWrite, p.cacheWrite1h),
                            minimumTokens: a.unresolved, disputedTokens: a.disputed)
    }

    /// The cost if fully known, else nil.
    func cost(model: String, _ a: Agg) -> Double? { estimate(model: model, a).value }

    /// The exact list cost of `a`'s resolved tokens, and the price used; nil without a price.
    private func listCost(model: String, _ a: Agg) -> (Double, Price)? {
        let p: Price? = lock.withLock {
            if let hit = resolved[model] { return hit }
            var p = table[model]
            // claude-haiku-4-5-20251001 -> claude-haiku-4-5
            if p == nil, let r = model.range(of: #"-\d{8}$"#, options: .regularExpression) { p = table[String(model[..<r.lowerBound])] }
            if !table.isEmpty { resolved[model] = p }
            return p
        }
        guard let p else { return nil }
        return (Double(a.input) * p.input + Double(a.output) * p.output + Double(a.cacheWrite5m) * p.cacheWrite
            + Double(a.cacheWrite1h) * p.cacheWrite1h + Double(a.cacheRead) * p.cacheRead, p)
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
/// (same rule as ccusage), and buckets per 15-minute UTC slot and model (#57). State is cached on disk so relaunches
/// are instant.
///
/// The cache (R8) holds no transcript paths, message ids or request ids: files and messages are keyed by opaque ids,
/// a keyed hash (HMAC-SHA256, truncated to 128 bits) under a random per-install key kept in its own owner-only file.
/// Paths are only held in memory to read the files.
final class Ledger {
    /// Buckets are 15-minute UTC slots (#57): every UTC offset in use is a multiple of 15 minutes, so every local
    /// midnight is a slot boundary and a slot belongs to exactly one local day in any zone. Whole hours put part of
    /// every day on the day before in zones such as +05:30, +05:45 and -03:30.
    static let slotSeconds = 900
    static func slot(of d: Date) -> Int { Int((d.timeIntervalSince1970 / Double(slotSeconds)).rounded(.down)) }
    static func start(of slot: Int) -> Date { Date(timeIntervalSince1970: Double(slot) * Double(slotSeconds)) }

    private struct FileMark: Codable { var offset: UInt64 }
    /// What has been counted for one operation, per model, and how the operation was identified (#55). `flawed` is
    /// set (never cleared) once any of its records had an invalid counter (#58); left out of the cache when not.
    private struct Seen: Codable {
        var slot: Int; var parts: [String: Agg]; var identity: IdentityCoverage.Kind; var flawed: Bool?
    }
    /// A record that couldn't be read (#58), keyed by an opaque id of its line so that reading the same bytes again
    /// (a rescan, a rewrite, a rename or a copy) reports it once. `slot` is the record's own for `invalidUsage`; the
    /// other kinds have no period, and theirs is the slot they were found in, used only to prune them.
    private struct Unread: Codable {
        enum Kind: String, Codable { case invalidUsage, undated, malformed }
        var kind: Kind; var slot: Int
    }
    /// Which operation carries a single message id or request id (#55): the one pair with it, or `ambiguous` once a
    /// second pair has it too. `slot` is the newest of their slots, for pruning.
    private struct Link: Codable { var target: String; var slot: Int }
    /// Version 7 (#57): `slots`, and every `slot`, are 15-minute UTC slots instead of whole UTC hours (`hours`,
    /// `hour`). An hour that holds a local midnight can't be split without the timestamps, so a version 6 cache is
    /// re-indexed rather than reinterpreted. Version 6 (#58): `unread` holds records that couldn't be read, and
    /// `flawed` counts operations per hour that were counted with an invalid counter. Version 5 subtracted negative
    /// counters, dropped cache-write breakdowns without a flat total and skipped `"usage": {`, and its offsets are past
    /// those lines, so its totals can't be carried over. Version 5 (#55): `seen` also holds operations known by one id or by a fingerprint, `links` maps
    /// single ids to pairs, and `identity` counts operations per hour by how they were identified. Version 4 counted
    /// records without ids on every read and treated empty ids as an id. Version 4 (R8) keyed `files` and `seen` by
    /// opaque ids; version 3 by raw paths and ids.
    private struct State: Codable {
        var version = 7
        /// An opaque id of a fixed input under the key the ids were made with, so a cache is only loaded with that key
        /// (a restored old cache next to a newer key would otherwise re-read and double count everything).
        var keyCheck = ""
        var files: [String: FileMark] = [:]
        var seen: [String: Seen] = [:]
        var links: [String: Link] = [:]
        var slots: [Int: [String: Agg]] = [:]
        var identity: [Int: IdentityCoverage] = [:]
        var flawed: [Int: Int] = [:]
        var unread: [String: Unread] = [:]
    }
    private static let ambiguous = "ambiguous"
    static let cacheName = "claude-ledger.json"
    static let keyName = "claude-ledger.key"
    struct GrokTurn { var key: String; var slot: Int; var model: String; var agg: Agg }
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
    /// Files (opaque ids) whose last line has no newline yet (#58). Not saved: every file with one is read again on the
    /// first full scan after a launch, since its saved offset is short of its size.
    private var pendingFiles: Set<String> = []
    private var lastFullScan = Date.distantPast
    /// Newest transcript write seen (Claude or Grok), used to tell when an agent is working.
    private var lastActivity = Date.distantPast
    private var changeCounter = 0
    /// Bytes scanned for lines, and files read again from the start, since this ledger started (#56). For tests and
    /// audits: they show unchanged transcripts aren't re-read.
    private var readStats = (bytes: 0, restarts: 0)
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
    private static let usageNeedle = Array(#""usage""#.utf8)

    /// The current time and the calendar for day boundaries. Injectable so accounting fixtures (#6) can pin "now" and
    /// the time zone, and tests can change the zone while the ledger runs (#57); by default the real clock and
    /// `Calendar.current`, read on every use as before.
    private let now: @Sendable () -> Date
    private let currentCalendar: @Sendable () -> Calendar
    private var calendar: Calendar { currentCalendar() }

    init(home: URL, appSupport: URL, pricing: Pricing, storage: PrivateDirectory? = nil,
         now: @escaping @Sendable () -> Date = { Date() }, calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.home = home
        self.storage = storage ?? PrivateDirectory(url: appSupport)
        self.pricing = pricing
        self.now = now
        self.currentCalendar = calendar
    }

    /// Why the cache isn't being saved, if it isn't; nil when it is (or nothing was tried yet).
    var cacheIssue: LedgerCacheIssue? { issueLock.withLock { issue } }
    private func setIssue(_ i: LedgerCacheIssue?) { issueLock.withLock { issue = i } }

    // MARK: Opaque ids (R8)

    /// HMAC-SHA256 over a domain and length-prefixed parts, so different kinds and splits of input can't collide.
    private func opaqueID(_ domain: String, _ parts: String...) -> String { opaqueID(domain, parts) }

    private func opaqueID(_ domain: String, _ parts: [String]) -> String { opaqueID(domain, data: parts.map { Data($0.utf8) }) }

    private func opaqueID(_ domain: String, data parts: [Data]) -> String {
        var mac = HMAC<SHA256>(key: key)
        for bytes in [Data(domain.utf8)] + parts {
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
    private func messageOnlyID(_ id: String) -> String { opaqueID("message-only", id) }
    private func requestOnlyID(_ request: String) -> String { opaqueID("request-only", request) }

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
            // Summaries only change with new data, a new window, a new day, a new time zone or new prices. Days are
            // worked out from the UTC slots here, so a new zone needs nothing else (#57); two zones can share today's
            // midnight and still differ on earlier days.
            let cal = calendar
            let key = "\(changeCounter)|\(windowStart?.timeIntervalSince1970 ?? 0)|\(cal.timeZone.identifier)|\(cal.startOfDay(for: now()).timeIntervalSince1970)|\(pricing.generation)"
            if key != lastSummaryKey || cachedSummaries == nil {
                cachedSummaries = (summarize(claudeSlots(), identity: state.identity, completeness: claudeCompleteness(),
                                             windowStart: windowStart),
                                   summarize(grokSlots(), identity: [:], completeness: ([:], DataCompleteness()),
                                             windowStart: nil))
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
        pendingFiles = []
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
            if size < offset { offset = 0; readStats.restarts += 1 } // rewritten file; dedupe keys prevent double counting
            offset = ingestClaudeFile(path, from: offset)
            state.files[id] = FileMark(offset: offset)
            setPending(id, offset < size)
            dirty = true
        }

        // Forget files that aged out or were removed, and prune old buckets and dedupe keys.
        let stale = state.files.keys.filter { !present.contains($0) }
        if !stale.isEmpty { stale.forEach { state.files.removeValue(forKey: $0) }; dirty = true }
        // Every other file was read to its end before (offset == size), or is gone: neither is pending.
        let read = Set(candidates.map(\.id))
        for id in pendingFiles where !read.contains(id) { setPending(id, false) }
        let minSlot = Self.slot(of: cutoff)
        if state.slots.keys.contains(where: { $0 < minSlot }) || state.flawed.keys.contains(where: { $0 < minSlot })
            || state.unread.values.contains(where: { $0.slot < minSlot }) {
            state.slots = state.slots.filter { $0.key >= minSlot }
            state.seen = state.seen.filter { $0.value.slot >= minSlot }
            state.links = state.links.filter { $0.value.slot >= minSlot }
            state.identity = state.identity.filter { $0.key >= minSlot }
            state.flawed = state.flawed.filter { $0.key >= minSlot }
            state.unread = state.unread.filter { $0.value.slot >= minSlot }
            changeCounter += 1
            dirty = true
        }
    }

    private func setPending(_ id: String, _ pending: Bool) {
        guard pending != pendingFiles.contains(id) else { return }
        if pending { pendingFiles.insert(id) } else { pendingFiles.remove(id) }
        changeCounter += 1
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
            let id = fileID(path)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { setPending(id, false); continue }
            if let m = attrs[.modificationDate] as? Date { lastActivity = max(lastActivity, m) }
            var offset = state.files[id]?.offset ?? 0
            if size == offset { continue }
            if size < offset { offset = 0; readStats.restarts += 1 }
            offset = ingestClaudeFile(path, from: offset)
            state.files[id] = FileMark(offset: offset)
            setPending(id, offset < size)
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
                if end > start, Self.hasUsageKey(UnsafeRawBufferPointer(start: base + start, count: end - start)) {
                    autoreleasepool {
                        ingestClaudeLine(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start),
                                              count: end - start, deallocator: .none))
                    }
                }
                start = end + 1
            }
            return start
        }
        readStats.bytes += consumed - Int(offset)
        return UInt64(consumed)
    }

    /// Whether a line has a `"usage"` key: the quoted name, then optional JSON whitespace and a colon, anywhere in the
    /// line (#58). Lines without one carry no usage and aren't parsed. The quotes keep it from matching `\"usage\"`
    /// inside text (there the byte after `e` is a backslash), and the colon from matching `"usage"` as a value.
    static func hasUsageKey(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        let n = line.count, k = usageNeedle.count
        var from = 0
        while from < n, let hit = memmem(base + from, n - from, usageNeedle, k) {
            var i = base.distance(to: UnsafeRawPointer(hit)) + k
            while i < n, line[i] == 0x20 || line[i] == 0x09 || line[i] == 0x0D { i += 1 } // space, tab, CR; no LF in a line
            if i < n, line[i] == 0x3A { return true }
            from = base.distance(to: UnsafeRawPointer(hit)) + 1
        }
        return false
    }

    /// Reads one line that has a usage key. What isn't usage is ignored; usage that can't be read is reported (#58)
    /// instead of dropped, and counters that aren't valid are left out and flag the message.
    private func ingestClaudeLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return unread(line, .malformed, slot: nil)
        }
        // Not usage: another record type, no message, no usage (or null), or a <synthetic> record. Checked before the
        // timestamp, so these are never reported as unread.
        guard obj.string("type") == "assistant", let msg = obj.dict("message"), let raw = msg["usage"], !(raw is NSNull)
        else { return }
        let model = msg.string("model") ?? "unknown"
        if model == "<synthetic>" { return }
        guard let date = ISO.parse(obj.string("timestamp")) else { return unread(line, .undated, slot: nil) }
        let slot = Self.slot(of: date)
        guard let usage = raw as? [String: Any] else { return unread(line, .invalidUsage, slot: slot) }

        var counters = CounterReader()
        var parts: [String: Agg] = [model: Self.agg(usage, &counters)]
        // Sub-calls made inside a turn (e.g. the advisor) are listed as extra iterations with their own
        // model; the top-level usage only covers the main model's iterations.
        switch usage["iterations"] {
        case nil, is NSNull: break
        case let list as [Any]:
            for item in list {
                guard let it = item as? [String: Any] else { counters.flawed = true; continue }
                guard let sub = it.string("model"), sub != model, it.string("type") != "message" else { continue }
                parts[sub, default: Agg(calls: 0)].add(Self.agg(it, &counters))
            }
        default: counters.flawed = true
        }
        let flawed = counters.flawed

        let id = Self.usableID(msg["id"]), req = Self.usableID(obj["requestId"])
        switch (id, req) {
        case let (id?, req?):
            let key = messageID(id, req)
            let single = [messageOnlyID(id), requestOnlyID(req)]
            // Operations first seen with one id that no other pair carries are this pair's operation: the first keeps
            // its slot and becomes the pair's, a second (the other id) is merged into it, and only growth is added.
            // Either way the operation stays incomplete.
            if state.seen[key] == nil {
                for s in single where state.links[s] == nil {
                    guard let partial = state.seen.removeValue(forKey: s) else { continue }
                    if state.seen[key] == nil {
                        state.seen[key] = partial
                    } else {
                        uncount(partial)
                        count(partial.parts, slot: partial.slot, key: key, kind: .incomplete, flawed: partial.flawed == true)
                    }
                }
            }
            count(parts, slot: slot, key: key, kind: .identified, flawed: flawed)
            let at = state.seen[key]!.slot
            for s in single {
                if let l = state.links[s], l.target != key {
                    state.links[s] = Link(target: Self.ambiguous, slot: max(l.slot, at))
                } else {
                    state.links[s] = Link(target: key, slot: max(state.links[s]?.slot ?? at, at))
                }
            }
        case (let id?, nil), (nil, let id?):
            let single = req == nil ? messageOnlyID(id) : requestOnlyID(id)
            switch state.links[single]?.target {
            case nil: count(parts, slot: slot, key: single, kind: .incomplete, flawed: flawed)
            case Self.ambiguous?:
                // More than one pair carries this id: joining either could merge two operations, so it stays apart.
                count(parts, slot: slot, key: single, kind: .ambiguous, flawed: flawed)
                reclassify(single, .ambiguous)
            case let pair?:
                count(parts, slot: slot, key: pair, kind: .identified, flawed: flawed)
                reclassify(pair, .incomplete)
            }
        case (nil, nil):
            count(parts, slot: slot, key: fingerprint(date, msg, usage), kind: .fingerprinted, flawed: flawed)
        }
    }

    /// Adds a record to the operation `key`: all of it if the operation is new, else only its growth, since streaming
    /// logs the same message several times with growing counts. A `flawed` record flags the operation for good.
    private func count(_ parts: [String: Agg], slot: Int, key: String, kind: IdentityCoverage.Kind, flawed: Bool) {
        guard var old = state.seen[key] else {
            for (m, a) in parts { state.slots[slot, default: [:]][m, default: Agg()].add(a) }
            state.seen[key] = Seen(slot: slot, parts: parts, identity: kind, flawed: flawed ? true : nil)
            state.identity[slot, default: IdentityCoverage()].add(kind)
            if flawed { state.flawed[slot, default: 0] += 1 }
            changeCounter += 1
            return
        }
        if flawed, old.flawed != true {
            old.flawed = true
            state.flawed[old.slot, default: 0] += 1
            changeCounter += 1
        }
        var held: [String] = []
        for (m, a) in parts {
            let prev = old.parts[m] ?? Agg(calls: 0)
            // A record adds no calls, so `parts` keeps the calls that were counted and stays exactly what this
            // operation added to `slots` (needed to take it back when two operations turn out to be one).
            var merged = a.reconciled(with: prev)
            merged.calls = prev.calls
            guard merged != prev else { continue }
            // The difference can be negative in some fields when cache writes are reclassified (#58); the bucket
            // can't go below 0, since it is the sum of `parts` and each part's counters are. A held bucket has lost
            // its true value, so it's rebuilt rather than reduced.
            let delta = merged.difference(from: prev)
            if delta.hasDecrease, state.slots[old.slot]?[m]?.isSaturated == true {
                held.append(m)
            } else {
                state.slots[old.slot, default: [:]][m, default: Agg()].add(delta)
            }
            old.parts[m] = merged
            changeCounter += 1
        }
        state.seen[key] = old
        for m in held { rebuild(slot: old.slot, model: m) }
    }

    /// Sets a bucket to the sum of the operations' `parts` counted in it, which `count` and `uncount` keep it equal
    /// to. For a held sum (#58): subtracting from one would show a wrong remainder as exact.
    private func rebuild(slot: Int, model m: String) {
        var b = Agg()
        for o in state.seen.values where o.slot == slot { if let p = o.parts[m] { b.add(p) } }
        state.slots[slot, default: [:]][m] = b.calls == 0 && b.total == 0 ? nil : b
    }

    /// Takes back everything an operation added to `slots` and `identity`.
    /// `s` must already be gone from `seen`.
    private func uncount(_ s: Seen) {
        for (m, a) in s.parts {
            guard var b = state.slots[s.slot]?[m] else { continue }
            if b.isSaturated || a.isSaturated {
                // A held sum has lost its true value (#58): rebuilt from the operations still counted there.
                rebuild(slot: s.slot, model: m)
                continue
            }
            b.subtract(a)
            state.slots[s.slot]![m] = b.total == 0 && b.calls == 0 ? nil : b
        }
        if state.slots[s.slot]?.isEmpty == true { state.slots[s.slot] = nil }
        state.identity[s.slot, default: IdentityCoverage()].add(s.identity, -1)
        if state.identity[s.slot]?.groups == 0 { state.identity[s.slot] = nil }
        if s.flawed == true {
            state.flawed[s.slot, default: 0] -= 1
            if state.flawed[s.slot] == 0 { state.flawed[s.slot] = nil }
        }
        changeCounter += 1
    }

    /// Reports a record that couldn't be read, once per distinct line (#58). Only an opaque id of the line is kept,
    /// never its text. Without `slot` (no timestamp) it has no period; the slot it was found in is kept only for pruning.
    private func unread(_ line: Data, _ kind: Unread.Kind, slot: Int?) {
        let key = opaqueID("unread", data: [line])
        guard state.unread[key] == nil else { return }
        state.unread[key] = Unread(kind: kind, slot: slot ?? Self.slot(of: now()))
        changeCounter += 1
    }

    /// Moves an operation to a less certain kind. Never back: a pair that was joined by one id stays incomplete.
    private func reclassify(_ key: String, _ kind: IdentityCoverage.Kind) {
        guard var s = state.seen[key], s.identity != kind, s.identity != .ambiguous,
              !(s.identity == .incomplete && kind == .identified) else { return }
        state.identity[s.slot, default: IdentityCoverage()].add(s.identity, -1)
        state.identity[s.slot, default: IdentityCoverage()].add(kind)
        s.identity = kind
        state.seen[key] = s
        changeCounter += 1
    }

    /// An id the ledger can use: a string with something other than whitespace in it. Missing, empty, blank and
    /// non-string ids are all absent (P4), never an identity shared by every record that has one.
    static func usableID(_ v: Any?) -> String? {
        guard let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    /// For a record with neither id: a keyed hash of its timestamp, model and every usage counter, in a fixed order,
    /// as written (absent, a number, or something else). Nothing about where the record was read is in it, so the
    /// same record in a rewritten, restored or copied file is the same operation. It is best effort (#9): a streamed
    /// record whose counters grew gets a new fingerprint, and two operations that really are identical get one.
    private func fingerprint(_ date: Date, _ msg: [String: Any], _ usage: [String: Any]) -> String {
        func text(_ v: Any?) -> String {
            switch v {
            case nil: return "-"
            case let s as String: return "s:" + s
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
                // The value, not its spelling: 50, 50.0 and 5e1 are one number.
                let d = n.doubleValue
                if d.rounded() == d, abs(d) < 9e15 { return "n:" + String(Int64(d)) }
                return "n:" + String(d)
            default: return "x"
            }
        }
        func counters(_ u: [String: Any]) -> [String] {
            let cc = u.dict("cache_creation")
            return Self.fingerprintCounters.map { text(u[$0]) }
                + ["cc:" + (cc == nil ? text(u["cache_creation"]) : "{}")]
                + Self.cacheTiers.map { text(cc?[$0]) }
        }
        // The instant as parsed (to the millisecond), not its spelling: "…:00Z", "…:00.000Z" and "…:00+00:00" are
        // one time.
        var parts = ["t:" + String(Int64((date.timeIntervalSince1970 * 1000).rounded())), text(msg["model"])] + counters(usage)
        let iterations = usage["iterations"] as? [[String: Any]] ?? []
        parts.append("iterations:\(usage["iterations"] == nil ? "-" : String(iterations.count))")
        for it in iterations { parts += [text(it["type"]), text(it["model"])] + counters(it) }
        return opaqueID("fingerprint", parts)
    }

    private static let fingerprintCounters = ["input_tokens", "output_tokens", "cache_creation_input_tokens",
                                              "cache_read_input_tokens"]
    private static let cacheTiers = ["ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"]

    /// A token counter as written (P8, #58).
    enum Counter: Equatable { case absent, value(Int), invalid }

    /// Absent and null report nothing. A valid counter is a non-negative integral number below 2^53, where every
    /// integer is exact (so `100.0`, `5e1` and `1e2` are valid). Anything else (negative, fractional, too large, not
    /// finite, a string, a boolean, an object or an array) is invalid: never read as 0 or as some other number.
    static func counter(_ v: Any?) -> Counter {
        switch v {
        case nil, is NSNull: return .absent
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
            let d = n.doubleValue
            guard d.isFinite, d >= 0, d.rounded() == d, d < 9_007_199_254_740_992 else { return .invalid }
            return .value(Int(d))
        default: return .invalid
        }
    }

    /// Reads counters and remembers whether any was invalid.
    private struct CounterReader {
        var flawed = false
        /// The value, or nil when absent or invalid (an invalid one sets `flawed`).
        mutating func read(_ d: [String: Any], _ k: String) -> Int? {
            switch Ledger.counter(d[k]) {
            case .absent: return nil
            case .invalid: flawed = true; return nil
            case .value(let n): return n
            }
        }
    }

    private static func agg(_ usage: [String: Any], _ r: inout CounterReader) -> Agg {
        var a = Agg(input: r.read(usage, "input_tokens") ?? 0, output: r.read(usage, "output_tokens") ?? 0,
                    cacheRead: r.read(usage, "cache_read_input_tokens") ?? 0, calls: 1)
        let flat = r.read(usage, "cache_creation_input_tokens")
        switch usage["cache_creation"] {
        case let cc as [String: Any] where Self.cacheTiers.contains(where: { Self.counter(cc[$0]) != .absent }):
            let tierInvalid = Self.cacheTiers.contains { Self.counter(cc[$0]) == .invalid }
            let t5 = r.read(cc, "ephemeral_5m_input_tokens") ?? 0, t1 = r.read(cc, "ephemeral_1h_input_tokens") ?? 0
            let sum = t5 + t1
            guard let flat else {
                // P8: without a valid flat total the breakdown is all there is. With an invalid tier its valid tiers
                // still count, but the split is unknown, so their tier is unresolved (P9).
                if tierInvalid { a.cacheWriteUnresolved = sum == 0 ? nil : sum } else { a.cacheWrite5m = t5; a.cacheWrite1h = t1 }
                break
            }
            // P9 (decided on #58): matching sources give the tiers. Otherwise the flat total is the quantity and its
            // tier is unknown (an invalid tier is never taken as matching), and what the breakdown reports beyond it
            // is counted provisionally, unpriced.
            if !tierInvalid && sum == flat {
                a.cacheWrite5m = t5; a.cacheWrite1h = t1
            } else {
                a.cacheWriteUnresolved = flat == 0 ? nil : flat
                if sum > flat { a.cacheWriteDisputed = sum - flat }
            }
        case nil, is NSNull, is [String: Any]:
            // No breakdown (or one without tiers): the flat total is 5-minute writes, as before.
            a.cacheWrite5m = flat ?? 0
        default:
            // A breakdown that can't be read: the flat total's tier is unknown.
            r.flawed = true
            if let flat, flat > 0 { a.cacheWriteUnresolved = flat }
        }
        return a
    }

    private func claudeSlots() -> [Int: [String: Agg]] { state.slots }

    /// What couldn't be read, per slot where its time is known, and what has no period (#58).
    private func claudeCompleteness() -> (bySlot: [Int: DataCompleteness], undated: DataCompleteness) {
        var bySlot = state.flawed.mapValues { DataCompleteness(flawed: $0) }
        var undated = DataCompleteness(pending: pendingFiles.count)
        for u in state.unread.values {
            switch u.kind {
            case .invalidUsage: bySlot[u.slot, default: DataCompleteness()].invalidUsage += 1
            case .undated: undated.undated += 1
            case .malformed: undated.malformed += 1
            }
        }
        return (bySlot, undated)
    }

    /// Bytes scanned for lines and files read again from the start since this ledger started, read on the ledger
    /// queue (#56). For tests and audits; the app doesn't use it.
    func claudeReadStats(completion: @escaping ((bytes: Int, restarts: Int)) -> Void) {
        queue.async { [self] in completion(readStats) }
    }

    /// Claude's usage per whole UTC hour (hours since 1970, then model): the 15-minute slots summed, read on the ledger
    /// queue. For accounting fixtures and audits (#6), whose expectations are in UTC hours; the app doesn't use it.
    func claudeHourlyUsage(completion: @escaping ([Int: [String: Agg]]) -> Void) {
        queue.async { [self] in
            var hours: [Int: [String: Agg]] = [:]
            let perHour = 3600 / Self.slotSeconds
            for (slot, models) in state.slots {
                let hour = Int((Double(slot) / Double(perHour)).rounded(.down))
                for (m, a) in models { hours[hour, default: [:]][m, default: Agg()].add(a) }
            }
            completion(hours)
        }
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
            return GrokTurn(key: key, slot: Self.slot(of: date),
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

    private func grokSlots() -> [Int: [String: Agg]] {
        var slots: [Int: [String: Agg]] = [:]
        for t in Self.uniqueGrokTurns(grokFiles.values.flatMap(\.turns)) {
            var a = slots[t.slot, default: [:]][t.model, default: Agg()]
            a.add(t.agg)
            // A turn without a reported cost stays unknown after merging with turns that have one (R7).
            if t.agg.costTicks == nil { a.uncostedTokens = (a.uncostedTokens ?? 0) + t.agg.total }
            slots[t.slot, default: [:]][t.model] = a
        }
        return slots
    }

    // MARK: Summaries

    /// Calendar-day windows like ccusage: today, the last 7 days and the last 30 days, all including today.
    private func summarize(_ slots: [Int: [String: Agg]], identity: [Int: IdentityCoverage],
                           completeness: (bySlot: [Int: DataCompleteness], undated: DataCompleteness),
                           windowStart: Date?) -> UsageSummary {
        let cal = calendar
        let today = cal.startOfDay(for: now())
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let monthStart = cal.date(byAdding: .day, value: -29, to: today)!
        let windowSlot = windowStart.map(Self.slot(of:))

        var s = UsageSummary(monthStart: monthStart)
        if windowSlot != nil { s.window = Totals() }
        var bars: [String: DayBar] = [:]
        var models: [String: (Int, CostEstimate)] = [:]

        for (slot, byModel) in slots {
            let date = Self.start(of: slot)
            guard date >= monthStart else { continue }
            let day = cal.startOfDay(for: date)
            for (model, a) in byModel {
                let c = pricing.estimate(model: model, a)
                let t = a.total
                let held = a.isSaturated
                let q = QuantityUncertainty(disputedTokens: a.disputed)
                s.month.addTokens(t, saturated: held); s.month.cost += c; s.month.quantity += q
                if date >= weekStart { s.week.addTokens(t, saturated: held); s.week.cost += c; s.week.quantity += q }
                if date >= today { s.today.addTokens(t, saturated: held); s.today.cost += c; s.today.quantity += q }
                if let wh = windowSlot, slot >= wh {
                    s.window!.addTokens(t, saturated: held); s.window!.cost += c; s.window!.quantity += q
                }

                let family = modelFamily(model)
                let key = "\(day.timeIntervalSince1970)-\(family)"
                var bar = bars[key] ?? DayBar(day: day, family: family, tokens: 0, cost: .zero)
                bar.tokens = bar.tokens.saturatingAdd(t); bar.cost += c
                bars[key] = bar

                var m = models[model] ?? (0, .zero)
                m.0 = m.0.saturatingAdd(t)
                m.1 += c
                models[model] = m
            }
        }
        // How the operations were identified (#55), by the slot each operation was first read in, like its tokens.
        for (slot, c) in identity {
            let date = Self.start(of: slot)
            guard date >= monthStart else { continue }
            s.month.identity += c
            if date >= weekStart { s.week.identity += c }
            if date >= today { s.today.identity += c }
            if let wh = windowSlot, slot >= wh { s.window!.identity += c }
        }
        // What couldn't be read (#58): in its own periods when its time is known, else in every period.
        for (slot, c) in completeness.bySlot {
            let date = Self.start(of: slot)
            guard date >= monthStart else { continue }
            s.month.completeness += c
            if date >= weekStart { s.week.completeness += c }
            if date >= today { s.today.completeness += c }
            if let wh = windowSlot, slot >= wh { s.window!.completeness += c }
        }
        s.month.completeness += completeness.undated
        s.week.completeness += completeness.undated
        s.today.completeness += completeness.undated
        s.window?.completeness += completeness.undated
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
