import SwiftUI
import Charts

extension Color {
    static let cpu = Color(nsColor: Palette.cpu)
    static let gpu = Color(nsColor: Palette.gpu)
    static let mem = Color(nsColor: Palette.mem)
    static let battery = Color(nsColor: Palette.battery)
    static let claude = Color(nsColor: Palette.claude)
    static let grok = Color(nsColor: Palette.grok)

    static func severity(_ pct: Double, base: Color) -> Color {
        pct >= 90 ? .red : pct >= 75 ? .orange : base
    }
}

struct PopoverActions {
    var refresh: () -> Void
    var quit: () -> Void
    var keepAwake: (AwakeSession) -> Void
    var loginItem: LoginItemService
    /// Turns Claude plan limits on (from the consent card) or off (from Settings).
    var setClaudeLimits: (Bool) -> Void
    /// Turns Grok credits on (from the consent card) or off (from Settings).
    var setGrokCredits: (Bool) -> Void
    /// Called with each new value of a Claude/Grok menu-bar switch, which pauses or resumes that provider's quota
    /// polling (#19). Called on the main thread right after the preference is written.
    var quotaSwitchChanged: (ProviderServices.QuotaSwitch, Bool) -> Void
    /// The user's explicit request to download the pinned price file (R6); offered only when no verified prices exist.
    var updatePricing: () -> Void
    /// Deletes SpanDeck's usage cache after the user confirmed it (R8).
    var clearUsageCache: () -> Void
}

/// One-line keep-awake state, shared by the footer and the menu bar hover.
func awakeStatus(_ store: Store) -> String {
    if let until = store.awakeUntil {
        if until == .distantFuture { return "Awake indefinitely" }
        return "Awake for \(Fmt.until(until)), until \(until.formatted(date: .omitted, time: .shortened))"
    }
    return store.awakeForAgents ? "Awake while Claude Code or Grok works" : "Sleep allowed"
}

struct PopoverView: View {
    @ObservedObject var store: Store
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    SystemGrid(store: store)
                    LimitsCard(store: store, enableClaudeLimits: { actions.setClaudeLimits(true) },
                               enableGrokCredits: { actions.setGrokCredits(true) })
                }
                .frame(width: 330)
                UsageCard(store: store, updatePricing: actions.updatePricing)
                    .frame(width: 330)
            }
            if store.usageCacheClearRequested || store.usageCacheClearing || store.usageCacheResult != nil {
                UsageCacheCard(store: store, clear: actions.clearUsageCache)
            }
            Footer(store: store, actions: actions)
        }
        .padding(14)
        .fixedSize()
    }
}

// MARK: - Building blocks

struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CardHeader: View {
    let title: String
    let icon: String
    let tint: Color
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 11, weight: .semibold))
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.15)))
            }
        }
    }
}

struct BigNumber: View {
    let text: String
    var color: Color = .primary
    var body: some View {
        Text(text).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(color).contentTransition(.numericText())
    }
}

/// Live area chart with a fixed time window so it scrolls smoothly as samples arrive.
struct LiveChart: View {
    let points: [Point]
    let tint: Color
    var span: TimeInterval = 120

    var body: some View {
        let end = points.last?.t ?? Date()
        let start = end.addingTimeInterval(-span)
        Chart(points.filter { $0.t >= start }) { p in
            AreaMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("t", p.t), y: .value("v", p.v))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
            }
        }
        .animation(nil, value: points.count)
        .clipped()
    }
}

/// Capsule progress bar with an optional pace marker showing where usage would be if spread evenly.
struct UsageBar: View {
    let percent: Double
    let tint: Color
    var pace: Double?

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, g.size.width * min(percent, 100) / 100))
                if let pace {
                    Rectangle().fill(Color.primary.opacity(0.65))
                        .frame(width: 1.5, height: g.size.height + 4)
                        .offset(x: g.size.width * min(max(pace, 0), 100) / 100 - 0.75)
                }
            }
        }
        .frame(height: 6)
    }
}

struct LimitRow: View {
    let entry: LimitEntry
    let tint: Color

    private var pace: Double? {
        guard let w = entry.window, let r = entry.resetsAt else { return nil }
        return (1 - r.timeIntervalSinceNow / w) * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(Fmt.pct(entry.percent)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.severity(entry.percent, base: .primary))
            }
            UsageBar(percent: entry.percent, tint: Color.severity(entry.percent, base: tint), pace: pace)
            HStack {
                if let note = entry.note { Text(note) }
                Spacer()
                if let r = entry.resetsAt { Text("resets in \(Fmt.until(r))") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct StatTile: View {
    let title: String
    let totals: Totals?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(totals.map { Fmt.tokens($0.tokens) } ?? "--")
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(totals.map { Fmt.cost($0.cost) } ?? " ")
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .help(totals.map { Fmt.costDetail($0.cost) } ?? "")
                .accessibilityLabel(totals.map { Fmt.spokenCost($0.cost) } ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

enum DailyMetric: String, CaseIterable, Identifiable {
    case cost = "Cost", tokens = "Tokens"
    var id: String { rawValue }
}

struct DailyChart: View {
    let summary: UsageSummary
    let metric: DailyMetric
    var height: CGFloat = 110

    private var families: [String] { Array(Set(summary.bars.map(\.family))).sorted() }

    var body: some View {
        let today = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        Chart {
            ForEach(summary.bars) { b in
                BarMark(x: .value("Day", b.day, unit: .day), y: .value(metric.rawValue, value(b)))
                    .foregroundStyle(by: .value("Model", b.family))
                    .cornerRadius(1.5)
                    .accessibilityLabel("\(b.family), \(b.day.formatted(date: .abbreviated, time: .omitted))")
                    .accessibilityValue(metric == .cost ? Fmt.spokenCost(b.cost) : "\(Fmt.tokens(b.tokens)) tokens")
            }
            // R7: a day whose cost isn't fully known shows only its priced part (with P9 minimums), marked "?" so it
            // doesn't read as a complete (or zero) cost, or "~" when it's provisional (P9, #58: cache-write quantities
            // disagree, so it isn't a lower bound either). Token bars are unaffected.
            if metric == .cost {
                ForEach(summary.incompleteCostDays, id: \.day) { d in
                    PointMark(x: .value("Day", d.day, unit: .day), y: .value(metric.rawValue, d.cost.amount))
                        .symbolSize(0)
                        .annotation(position: .top, spacing: 1) {
                            Text(d.cost.isProvisional ? "~" : "?").font(.system(size: 9, weight: .bold))
                        }
                        .accessibilityLabel(d.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue(Fmt.spokenCost(d.cost))
                }
            }
        }
        .chartForegroundStyleScale(domain: families, range: families.enumerated().map { Palette.familyColor($1, index: $0) })
        .chartXScale(domain: summary.monthStart...end)
        .chartXAxis {
            AxisMarks(values: (0..<4).compactMap { Calendar.current.date(byAdding: .day, value: $0 * 7, to: summary.monthStart) }) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(Color.primary.opacity(0.12))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(metric == .cost ? Fmt.usd(d) : "\(Fmt.tokens(Int(d * 1e6)))").font(.system(size: 9))
                    }
                }
            }
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
        .frame(height: height)
    }

    private func value(_ b: DayBar) -> Double { metric == .cost ? b.cost.amount : Double(b.tokens) / 1e6 }
}

// MARK: - System

struct SystemGrid: View {
    @ObservedObject var store: Store

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                MetricCard(title: "CPU", icon: "cpu", tint: .cpu, value: store.cpu?.total, history: store.cpuHistory,
                           subtitle: store.cpu.map { "usr \(Fmt.pct($0.user))  sys \(Fmt.pct($0.system))" } ?? " ") {
                    CoreBars(cores: store.cpu?.cores ?? [])
                }
                .topConsumersOnHover(.cpu, title: "TOP CPU")
                MetricCard(title: "GPU", icon: "cube.transparent", tint: .gpu, value: store.gpu, history: store.gpuHistory,
                           subtitle: "Device utilization") { EmptyView() }
                    .topConsumersOnHover(.gpu, title: "TOP GPU")
            }
            GridRow {
                MetricCard(title: "Memory", icon: "memorychip", tint: memTint, value: store.memory?.percent,
                           history: store.memHistory,
                           subtitle: store.memory.map { "\(Fmt.gb($0.used)) of \(Fmt.gb($0.total))" } ?? " ") {
                    if let m = store.memory {
                        HStack(spacing: 4) {
                            Text("Pressure \(m.pressureName)")
                            Spacer()
                            if m.swapUsed > 0 { Text("swap \(Fmt.gb(m.swapUsed))") }
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .topConsumersOnHover(.memory, title: "TOP MEMORY")
                BatteryCard(battery: store.battery)
                    .topConsumersOnHover(.battery, title: "ENERGY SHARE")
            }
        }
    }

    private var memTint: Color {
        let p = store.memory?.pressure ?? 1
        return p >= 4 ? .red : p >= 2 ? .orange : .mem
    }
}

struct MetricCard<Extra: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let value: Double?
    let history: [Point]
    let subtitle: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                CardHeader(title: title, icon: icon, tint: tint)
                BigNumber(text: Fmt.pct(value))
            }
            LiveChart(points: history, tint: tint).frame(height: 42)
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            extra
        }
        .padding(10)
        .frame(width: 160, height: 150, alignment: .topLeading)
        .background(CardBackground())
    }
}

struct CoreBars: View {
    let cores: [Double]
    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, c in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 1).fill(Color.severity(c, base: .cpu))
                        .frame(height: max(1, 14 * c / 100))
                }
                .frame(height: 14)
            }
        }
    }
}

struct BatteryCard: View {
    let battery: BatterySample?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                CardHeader(title: "Battery", icon: icon, tint: .battery)
                BigNumber(text: Fmt.pct(battery?.percent), color: low ? .red : .primary)
            }
            if let b = battery {
                UsageBar(percent: b.percent, tint: low ? .red : b.charging ? .mem : .battery).padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status(b)).font(.system(size: 11, weight: .medium))
                    Text(power(b)).foregroundStyle(.secondary)
                    Text(health(b)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10)).lineLimit(1)
            } else {
                Spacer()
                Text("No battery").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 160, height: 150, alignment: .topLeading)
        .background(CardBackground())
    }

    private var low: Bool { (battery.map { !$0.pluggedIn && $0.percent <= 15 }) ?? false }
    private var icon: String {
        guard let b = battery else { return "battery.0" }
        if b.charging { return "battery.100.bolt" }
        return b.percent > 60 ? "battery.75" : b.percent > 30 ? "battery.50" : "battery.25"
    }

    private func status(_ b: BatterySample) -> String {
        if b.charging { return b.minutesToFull.map { "Charging, full in \(Fmt.duration(minutes: $0))" } ?? "Charging" }
        if b.pluggedIn { return b.charged ? "Charged" : "On power adapter" }
        return b.minutesToEmpty.map { "\(Fmt.duration(minutes: $0)) remaining" } ?? "On battery"
    }

    private func power(_ b: BatterySample) -> String {
        var parts: [String] = []
        if let w = b.watts, abs(w) >= 0.1 { parts.append(String(format: "%@%.1f W", w > 0 ? "+" : "", w)) }
        if let a = b.adapterWatts, b.pluggedIn { parts.append("\(a) W adapter") }
        if let t = b.temperature { parts.append(String(format: "%.0f\u{00B0}C", t)) }
        return parts.isEmpty ? " " : parts.joined(separator: "  ")
    }

    private func health(_ b: BatterySample) -> String {
        var parts: [String] = []
        if let h = b.health { parts.append("Health \(Fmt.pct(h))") }
        if let c = b.cycles { parts.append("\(c) cycles") }
        return parts.isEmpty ? " " : parts.joined(separator: "  ")
    }
}

// MARK: - Limits

/// What the popover's Grok section shows (#21). Pure, so tests can check that a failure is never hidden.
enum GrokSection: Equatable {
    case consent
    /// Consent given, quota switch off (R3, #19).
    case paused
    case loading
    case plan(GrokPlanView)
    case failure(GrokError)

    /// A plan, possibly kept through a temporary failure; `failure` is then shown next to it as stale.
    struct GrokPlanView: Equatable {
        var staleBecause: GrokError?
    }

    /// nil: no Grok section (consent not given and not requested).
    static func select(_ store: Store) -> GrokSection? {
        guard store.grokEnabled else { return store.grokConsentRequested ? .consent : nil }
        guard store.grokQuotaShown else { return .paused }
        if store.grokPlan != nil { return .plan(GrokPlanView(staleBecause: store.grokFailure)) }
        if let failure = store.grokFailure { return .failure(failure) }
        return .loading
    }
}

struct LimitsCard: View {
    @ObservedObject var store: Store
    var enableClaudeLimits: () -> Void
    var enableGrokCredits: () -> Void

    /// The Claude section shows the consent prompt, a paused note when its gauge is hidden, or the account's limits.
    private var showsClaude: Bool { !store.claudeLimitsEnabled || !store.claudeQuotaShown || store.claudeAvailable }
    /// Grok consent is only shown when asked for from Settings, so the app never probes for Grok files to decide.
    private var grok: GrokSection? { GrokSection.select(store) }
    private var showsGrok: Bool { grok != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.claudeLimitsEnabled {
                ClaudeLimitsConsent(enable: enableClaudeLimits)
            } else if !store.claudeQuotaShown {
                QuotaPaused(title: "Claude Code", icon: "sparkle", tint: .claude, what: "Claude plan limits", toggle: "Claude limits")
            } else if store.claudeAvailable {
                CardHeader(title: "Claude Code", icon: "sparkle", tint: .claude, trailing: store.claudeLimits?.plan)
                if let l = store.claudeLimits {
                    ForEach(l.all) { LimitRow(entry: $0, tint: .claude) }
                } else {
                    Text(store.claudeError ?? "Loading limits...").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let err = store.claudeError, store.claudeLimits != nil {
                    Text("\(err), showing data from \(Fmt.ago(store.claudeLimits?.fetchedAt))").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            if showsClaude && showsGrok {
                Divider().opacity(0.5)
            }
            switch grok {
            case .consent?:
                GrokCreditsConsent(enable: enableGrokCredits, cancel: { store.grokConsentRequested = false })
            case .paused?:
                QuotaPaused(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok, what: "Grok credits", toggle: "Grok credits")
            case .loading?:
                CardHeader(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok)
                Text("Loading plan...").font(.system(size: 11)).foregroundStyle(.secondary)
            case .plan(let view)?:
                if let p = store.grokPlan {
                    CardHeader(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok,
                               trailing: view.staleBecause == nil ? p.periodName.capitalized + " credits" : "Stale")
                    LimitRow(entry: LimitEntry(id: "grok", name: "Credits used", percent: p.percent, resetsAt: p.periodEnd,
                                               window: window(p),
                                               note: p.products.count > 1 ? p.products.map { "\($0.name) \(Fmt.pct($0.percent))" }.joined(separator: "  ") : nil),
                             tint: .grok)
                    if let failure = view.staleBecause {
                        Text("\(failure.title). Not current: last updated \(Fmt.ago(p.fetchedAt)). \(failure.guidance)")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .failure(let failure)?:
                CardHeader(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok,
                           trailing: failure == .notConfigured ? "Not set up" : failure.isTemporary ? "Retrying" : "Error")
                Text(failure.title).font(.system(size: 11, weight: .medium))
                Text(failure.guidance).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
            if !showsClaude && !showsGrok {
                Text("No Claude Code or Grok account found").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(CardBackground())
    }

    private func window(_ p: GrokPlan) -> TimeInterval? {
        guard let s = p.periodStart, let e = p.periodEnd else { return nil }
        return e.timeIntervalSince(s)
    }
}

/// Shown instead of a provider's plan data while its menu-bar switch is off: nothing is fetched, consent is unchanged (#19).
struct QuotaPaused: View {
    let title: String
    let icon: String
    let tint: Color
    let what: String
    let toggle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: title, icon: icon, tint: tint, trailing: "Paused")
            Text("\(what) are hidden from the menu bar, so they aren't refreshed. "
                 + "Turn on Settings ▸ \(toggle) to resume. Token usage is still counted.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Explains exactly what enabling Claude plan limits does before anything is read (#15).
struct ClaudeLimitsConsent: View {
    var enable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Claude Code", icon: "sparkle", tint: .claude, trailing: "Off")
            Text("Plan limits are off. To show them, this app reads the Claude Code credentials stored in your macOS Keychain "
                 + "and sends their OAuth access token to api.anthropic.com/api/oauth/usage: at launch, once a minute, "
                 + "after wake and when you refresh. That endpoint is unofficial and may stop working. "
                 + "Token usage works without this. You can turn it off in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Enable Claude plan limits", action: enable)
                .controlSize(.small)
        }
    }
}

/// Explains exactly what enabling Grok credits does before anything is read (#17).
struct GrokCreditsConsent: View {
    var enable: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Grok", icon: "bolt.horizontal.circle", tint: .grok, trailing: "Off")
            Text("Grok credits are off. To show them, this app reads the API key the Grok CLI stores in ~/.grok/auth.json "
                 + "and sends it to cli-chat-proxy.grok.com/v1/billing: at launch, once a minute, after wake and when you refresh. "
                 + "If the key has expired or is rejected, it runs ~/.grok/bin/grok models (at most once every 10 minutes, "
                 + "even if you turn this off and on) so the CLI can refresh it; the CLI may update its own files, including auth.json. "
                 + "This app never writes your Grok files itself. That endpoint is the Grok CLI's and may change. "
                 + "Grok token usage works without this. You can turn it off in Settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Enable Grok credits", action: enable)
                Button("Not now", action: cancel)
            }
            .controlSize(.small)
        }
    }
}

/// Confirms Settings ▸ Clear cached usage data before anything is deleted, then shows the outcome (R8).
struct UsageCacheCard: View {
    @ObservedObject var store: Store
    var clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Cached usage data", icon: "externaldrive", tint: .secondary)
            if store.usageCacheClearing {
                Text("Clearing…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let result = store.usageCacheResult {
                Text(result).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Done") { store.usageCacheResult = nil }.controlSize(.small)
            } else {
                Text(UsageCacheText.confirmation).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Clear cached usage data") {
                        store.usageCacheClearRequested = false
                        clear()
                    }
                    Button("Cancel") { store.usageCacheClearRequested = false }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }
}

/// Copy for the usage cache (R8), kept apart from the views so tests can check it.
enum UsageCacheText {
    static let confirmation = "This deletes SpanDeck's locally stored usage index (claude-ledger.json and its key file). "
        + "It doesn't delete Claude Code or Grok transcripts, provider credentials or price files, and doesn't change "
        + "plan-limit consent. Totals are rebuilt by reading the transcripts again, which can take a moment. Deleted "
        + "files may remain in backups or snapshots; this isn't secure erasure."
    static let cleared = "Cached usage data cleared. Totals are being rebuilt from your Claude Code and Grok files."
}

// MARK: - Combined token usage

struct UsageCard: View {
    @ObservedObject var store: Store
    var updatePricing: () -> Void
    @AppStorage("usage.metric") private var metric: DailyMetric = .cost

    var body: some View {
        let grok = store.localGrokUsage
        let combined = UsageSummary.combine(store.claudeUsage, grok)
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(title: "Token usage", icon: "chart.bar.xaxis", tint: .claude, trailing: grok == nil ? "Claude Code" : "Claude + Grok")
            HStack(spacing: 6) {
                StatTile(title: "Today", totals: combined?.today)
                StatTile(title: "7 days", totals: combined?.week)
                StatTile(title: "30 days", totals: combined?.month)
            }
            let notes = UsageNotes.notes(store.claudeUsage)
            if !notes.isEmpty { UsageNotes(notes: notes) }
            VStack(spacing: 4) {
                ProviderRow(name: "Claude", color: .claude, summary: store.claudeUsage)
                if grok != nil { ProviderRow(name: "Grok", color: .grok, summary: grok) }
            }
            if let w = store.claudeUsage?.window {
                HStack {
                    Text("Claude 5h window").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Fmt.tokens(w.tokens)) tokens  \(Fmt.cost(w.cost))").monospacedDigit()
                        .help(Fmt.costDetail(w.cost))
                        .accessibilityLabel("\(Fmt.tokens(w.tokens)) tokens, \(Fmt.spokenCost(w.cost))")
                }
                .font(.system(size: 11))
            }

            if let u = combined {
                HStack {
                    Text("LAST 30 DAYS").font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $metric) {
                        ForEach(DailyMetric.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 110)
                }
                DailyChart(summary: u, metric: metric, height: 190)
                ModelList(models: Array(u.models.prefix(8)), families: Array(Set(u.bars.map(\.family))).sorted())
                if let note = PricingText.coverageNote(claude: store.claudeUsage, grok: grok) {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(store.indexing ?? "Reading usage...").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            PricingNote(store: store, update: updatePricing)
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(CardBackground())
    }
}

/// One provider's cost across the three windows, aligned under the tiles.
struct ProviderRow: View {
    let name: String
    let color: Color
    let summary: UsageSummary?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).frame(width: 46, alignment: .leading)
            ForEach(0..<3, id: \.self) { i in
                let t: Totals? = [summary?.today, summary?.week, summary?.month][i]
                Text(t.map { "\(Fmt.tokens($0.tokens)) \(Fmt.cost($0.cost))" } ?? "--")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(t.map { Fmt.costDetail($0.cost) } ?? "")
                    .accessibilityLabel(t.map { "\(Fmt.tokens($0.tokens)) tokens, \(Fmt.spokenCost($0.cost))" } ?? "--")
            }
        }
        .font(.system(size: 10))
    }
}

struct ModelList: View {
    let models: [ModelRow]
    let families: [String]
    var body: some View {
        VStack(spacing: 3) {
            ForEach(models) { m in
                HStack(spacing: 6) {
                    Circle().fill(Palette.familyColor(modelFamily(m.model), index: families.firstIndex(of: modelFamily(m.model)) ?? 0))
                        .frame(width: 6, height: 6)
                    Text(m.model).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(Fmt.tokens(m.tokens)).monospacedDigit().foregroundStyle(.secondary)
                    Text(Fmt.cost(m.cost)).monospacedDigit().frame(width: 52, alignment: .trailing)
                        .help(Fmt.costDetail(m.cost))
                        .accessibilityLabel(Fmt.spokenCost(m.cost))
                }
                .font(.system(size: 10))
            }
        }
    }
}

/// Where cost estimates come from (R6). The one explicit price download is offered only when no verified prices are
/// in use; otherwise downloading the same pinned file again would change nothing.
struct PricingNote: View {
    @ObservedObject var store: Store
    var update: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PricingText.summary(store.pricing)).foregroundStyle(.secondary)
            if store.pricing.source == .unavailable {
                Text(PricingText.downloadDisclosure).foregroundStyle(.secondary)
                Button(store.pricingUpdating ? "Downloading…" : "Download reviewed prices", action: update)
                    .disabled(store.pricingUpdating).controlSize(.small)
            }
            if let error = store.pricingError {
                Text(PricingText.failure(error)).foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Copy for pricing provenance (R6), kept apart from the views so tests can check it.
enum PricingText {
    static func short(_ revision: String?) -> String { String((revision ?? "").prefix(7)) }

    static func summary(_ info: PricingInfo) -> String {
        let date = String((info.retrieved ?? "").prefix(10))
        switch info.source {
        case .bundled:
            return "Costs are estimates at list prices from LiteLLM \(short(info.revision)) (reviewed \(date), built in), "
                + "not your Anthropic bill. " + unpricedRule
        case .downloaded:
            return "Costs are estimates at list prices from LiteLLM \(short(info.revision)) (downloaded \(date)), "
                + "not your Anthropic bill. " + unpricedRule
        case .unavailable:
            return "Claude costs can't be estimated: no verified price list, so Claude costs show n/a. "
                + "Grok amounts are as reported by the Grok CLI."
        }
    }

    /// R7: what happens to usage without a known cost, and where Grok amounts come from.
    static let unpricedRule = "Models missing from that list (often newer ones) aren't priced, and some Grok turns have "
        + "no reported cost: totals that include either show ≥ (known part only) or n/a, never $0. Where Claude Code's "
        + "logs disagree on a cache-write amount, costs show ~ (provisional, not a lower bound). Grok amounts are as "
        + "reported by the Grok CLI."

    /// Why the 30-day estimate is incomplete, naming the models; nil when every cost is known. An unpriced Claude model
    /// and a Grok model whose turns reported no cost are different causes, so they're named separately. The cause comes
    /// from which summary a model is in, never from its name (a Grok model ID can be any string).
    static func coverageNote(claude: UsageSummary?, grok: UsageSummary?) -> String? {
        func list(_ m: [String]) -> String {
            m.prefix(3).joined(separator: ", ") + (m.count > 3 ? " and \(m.count - 3) more" : "")
        }
        let priced = claude?.uncostedModels ?? [], reported = grok?.uncostedModels ?? []
        let tiers = claude?.uncertainCacheModels ?? []
        guard !priced.isEmpty || !reported.isEmpty || !tiers.isEmpty, let total = UsageSummary.combine(claude, grok)
        else { return nil }
        var causes: [String] = []
        if !priced.isEmpty { causes.append("no price for \(list(priced))") }
        // P9 (#58): the logs' cache-write totals and their 5-minute/1-hour breakdown disagree or can't be read.
        if !tiers.isEmpty { causes.append("cache writes of uncertain tier or amount for \(list(tiers))") }
        if !reported.isEmpty { causes.append("the Grok CLI reported no cost for some \(list(reported)) turns") }
        let provisional = total.month.cost.isProvisional
        return (provisional ? "≥ partial estimate, ~ provisional estimate, n/a no estimate: " : "≥ partial estimate, n/a no estimate: ")
            + causes.joined(separator: "; ") + ". \(Fmt.costDetail(total.month.cost)) over 30 days. On the chart, \"?\" "
            + (provisional ? "marks days whose cost isn't fully known and \"~\" days whose cost is provisional."
                           : "marks days whose cost isn't fully known.")
    }

    static var downloadDisclosure: String {
        "The built-in price list didn't verify. You can download the same reviewed list (LiteLLM "
            + "\(short(PricingSnapshot.pin.revision))) from GitHub (raw.githubusercontent.com). Only that price file is "
            + "fetched; nothing about your usage or transcripts is sent. Its SHA-256 is checked before it is used. Newer "
            + "upstream prices are not trusted automatically; reviewed updates arrive with SpanDeck updates."
    }

    static func failure(_ error: PricingUpdateError) -> String {
        switch error {
        case .alreadyCurrent: return "These are already the reviewed prices; newer ones arrive with SpanDeck updates."
        case .inProgress: return "A price download is already running."
        case .network: return "Couldn't reach GitHub. Prices unchanged."
        case .http(let code): return "GitHub answered HTTP \(code). Prices unchanged."
        case .checksumMismatch: return "The download didn't match the reviewed file (SHA-256). Prices unchanged."
        case .invalidData: return "The downloaded file had no valid Claude prices. Prices unchanged."
        case .writeFailed: return "Couldn't save the downloaded prices. Prices unchanged."
        }
    }
}

/// Copy for identity coverage (#55), kept apart from the views so tests can check it. Independent of cost coverage:
/// a total can be exactly identified with an unknown cost, or approximate with a fully known one. Provisional wording
/// until #7 settles the metric terms.
enum IdentityText {
    static let approximate = "Usage may be approximate: some records lack identifiers."

    /// The note and its detail when any Claude message in the 30 days wasn't identified by both a message id and a
    /// request id; nil when all were. Counts identity groups (logged messages with their streamed copies), not model
    /// calls. Counts only, never an id.
    static func note(_ claude: UsageSummary?) -> (text: String, detail: String)? {
        guard let c = claude?.month.identity, !c.isExact else { return nil }
        var kinds: [String] = []
        if c.incomplete > 0 { kinds.append("\(c.incomplete) by one id") }
        if c.fingerprinted > 0 {
            kinds.append("\(c.fingerprinted) with no id, by a fingerprint of timestamp, model and token counts")
        }
        if c.ambiguous > 0 { kinds.append("\(c.ambiguous) by an id that more than one message shares") }
        let noun = c.groups == 1 ? "logged message" : "logged messages", were = c.uncertain == 1 ? "was" : "were"
        return (approximate, "Of \(c.groups) \(noun) from Claude in the last 30 days, \(c.uncertain) \(were) told apart "
                    + "without both a message id and a request id: " + kinds.joined(separator: ", ") + ". These may be "
                    + "counted twice or merged, so token totals and cost estimates may be off. Costs are still estimates, "
                    + "not your bill.")
    }
}

/// Copy for data completeness (#58), kept apart from the views so tests can check it. Independent of identity (#55)
/// and cost coverage (R7): it says what the ledger couldn't read, not how records were told apart or priced.
/// Provisional wording until #7 settles the metric terms.
enum CompletenessText {
    static let incomplete = "Some usage records couldn't be read. Totals may be incomplete."

    /// The note and its detail when any Claude usage record in the 30 days couldn't be read, or was counted with an
    /// invalid counter left out; nil otherwise. A line still being written isn't a gap. Counts only, never content.
    static func note(_ claude: UsageSummary?) -> (text: String, detail: String)? {
        guard let c = claude?.month.completeness, !c.isComplete else { return nil }
        func n(_ k: Int, _ one: String, _ many: String) -> String { "\(k) " + (k == 1 ? one : many) }
        var parts: [String] = []
        if c.unread > 0 {
            var kinds: [String] = []
            if c.malformed > 0 { kinds.append(n(c.malformed, "isn't valid JSON", "aren't valid JSON")) }
            if c.undated > 0 { kinds.append(n(c.undated, "has no usable timestamp", "have no usable timestamp")) }
            if c.invalidUsage > 0 {
                kinds.append(n(c.invalidUsage, "has usage in a form SpanDeck doesn't recognize",
                               "have usage in a form SpanDeck doesn't recognize"))
            }
            // Counted per distinct line: identical copies of a broken line are one (#58).
            parts.append(n(c.unread, "record", "records") + " couldn't be read, counting identical lines once: "
                         + kinds.joined(separator: ", ") + ".")
        }
        if c.flawed > 0 {
            parts.append(n(c.flawed, "message", "messages") + " had a token count that isn't a valid number; it was "
                         + "left out and the rest counted.")
        }
        let undated = c.undated + c.malformed
        if undated > 0 {
            parts.append(undated == c.unread
                ? (undated == 1 ? "It has no date, so it may belong to any period."
                                : "None of them has a date, so they may belong to any period.")
                : n(undated, "of the unread records has no date, so it", "of the unread records have no date, so they")
                    + " may belong to any period.")
        }
        return (incomplete, "In Claude Code's logs for the last 30 days, " + parts.joined(separator: " ") + " What "
                    + "couldn't be read isn't in the token totals or cost estimates, so both may be low. Costs are "
                    + "still estimates, not your bill.")
    }
}

/// Copy for token-quantity uncertainty (#58), kept apart from the views so tests can check it. Independent of
/// identity, completeness and cost coverage: it says the counts themselves aren't exact.
enum QuantityText {
    static let provisional = "Some token counts are provisional. Totals may be over- or understated."

    /// The note and its detail when any Claude token quantity in the 30 days isn't exact; nil otherwise.
    static func note(_ claude: UsageSummary?) -> (text: String, detail: String)? {
        guard let q = claude?.month.quantity, !q.isExact else { return nil }
        var causes: [String] = []
        if q.saturated {
            causes.append("some totals are larger than SpanDeck can count, so they are shown at the largest value it "
                          + "can hold, below the true amount.")
        }
        if q.disputedTokens > 0 {
            causes.append("\(Fmt.tokens(q.disputedTokens)) cache-write tokens are counted provisionally, because a "
                          + "cache-write total and its 5-minute/1-hour breakdown disagree and the larger was used. The "
                          + "true amount may be lower or higher, and their cost isn't estimated.")
        }
        return (provisional, "In Claude Code's logs for the last 30 days, " + causes.joined(separator: " Also, ")
                    + " Costs are still estimates, not your bill.")
    }
}

/// The notes under the usage tiles (#55, #58): one short line each, with the detail as a tooltip and for VoiceOver.
/// What couldn't be read comes first, then uncertain quantities, then how records were told apart. Cost coverage
/// stays with the costs.
struct UsageNotes: View {
    let notes: [(text: String, detail: String)]

    nonisolated static func notes(_ claude: UsageSummary?) -> [(text: String, detail: String)] {
        [CompletenessText.note(claude), QuantityText.note(claude), IdentityText.note(claude)].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(notes, id: \.text) { note in
                Text(note.text).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note.detail)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(note.text + " " + note.detail)
            }
        }
    }
}

// MARK: - Footer

struct Footer: View {
    @ObservedObject var store: Store
    let actions: PopoverActions
    @AppStorage(Prefs.showCPU) private var showCPU = true
    @AppStorage(Prefs.showGPU) private var showGPU = false
    @AppStorage(Prefs.showMem) private var showMem = true
    @AppStorage(Prefs.showBattery) private var showBattery = false
    @AppStorage(Prefs.showClaude) private var showClaude = true
    @AppStorage(Prefs.showGrok) private var showGrok = true
    @AppStorage(Prefs.interval) private var interval = 1.0
    @AppStorage(Prefs.awakeForAgents) private var awakeForAgents = false
    @AppStorage(Prefs.awakeDisplay) private var awakeDisplay = false
    @State private var launchAtLogin = false

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Section("Show in menu bar") {
                    Toggle("CPU", isOn: $showCPU)
                    Toggle("GPU", isOn: $showGPU)
                    Toggle("Memory", isOn: $showMem)
                    Toggle("Battery", isOn: $showBattery)
                }
                // These switches also pause or resume quota polling; they never grant or revoke consent (#19).
                if store.claudeLimitsEnabled || store.grokEnabled {
                    Section("Plan limits · hidden ones aren't refreshed") {
                        if store.claudeLimitsEnabled { Toggle("Claude limits", isOn: quotaSwitch($showClaude, .claude)) }
                        if store.grokEnabled { Toggle("Grok credits", isOn: quotaSwitch($showGrok, .grok)) }
                    }
                }
                Picker("Update every", selection: $interval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                Section("Cost estimates") {
                    Text(store.pricing.source == .unavailable ? "No verified prices"
                         : "LiteLLM \(PricingText.short(store.pricing.revision)) · \(store.pricing.source == .bundled ? "built in" : "downloaded")")
                    Text("Newer reviewed prices arrive with SpanDeck updates")
                }
                Section("Cached usage data") {
                    if let issue = store.usageCacheIssue { Text(issue) }
                    Button("Clear cached usage data…") { store.usageCacheClearRequested = true }
                        .disabled(store.usageCacheClearing)
                }
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if store.claudeLimitsEnabled {
                    Button("Turn off Claude plan limits") { actions.setClaudeLimits(false) }
                }
                if store.grokEnabled {
                    Button("Turn off Grok credits") { actions.setGrokCredits(false) }
                } else {
                    Button("Set up Grok credits…") { store.grokConsentRequested = true }
                }
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton).fixedSize()

            Menu {
                Section(awakeStatus(store)) {
                    Button("Off") { actions.keepAwake(.off) }.disabled(store.awakeUntil == nil)
                    Button("For 1 hour") { actions.keepAwake(.hours(1)) }
                    Button("For 2 hours") { actions.keepAwake(.hours(2)) }
                    Button("For 4 hours") { actions.keepAwake(.hours(4)) }
                    Button("For 8 hours") { actions.keepAwake(.hours(8)) }
                    Button("Indefinitely") { actions.keepAwake(.indefinitely) }
                }
                Toggle("While Claude Code or Grok works", isOn: $awakeForAgents)
                Toggle("Keep display on", isOn: $awakeDisplay)
            } label: {
                Label(awakeLabel, systemImage: store.awake ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Keep awake (Option-click the menu bar item to toggle)")

            Spacer()
            Text(store.indexing ?? "Usage updated \(Fmt.ago(store.usageUpdated))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Button(action: actions.refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh limits and usage")
            Button("Quit", action: actions.quit).buttonStyle(.borderless)
        }
        .font(.system(size: 11))
        .onAppear { launchAtLogin = actions.loginItem.isEnabled }
    }

    private var awakeLabel: String {
        if let until = store.awakeUntil { return until == .distantFuture ? "Awake" : "Awake \(Fmt.until(until))" }
        return store.awakeForAgents ? "Awake (agents)" : "Keep awake"
    }

    /// Writes the switch, then reports this exact change so the app records it before anything else runs.
    private func quotaSwitch(_ value: Binding<Bool>, _ provider: ProviderServices.QuotaSwitch) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; actions.quotaSwitchChanged(provider, $0) })
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try actions.loginItem.register() } else { try actions.loginItem.unregister() }
        } catch {
            NSLog("\(AppIdentity.name): login item change failed: \(error)")
        }
        launchAtLogin = actions.loginItem.isEnabled
    }
}
