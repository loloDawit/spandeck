import Foundation
import Testing
@testable import Headroom

/// Private-use trust states (#94): a missing or unreadable transcript folder is never shown as zero usage, and a quota
/// whose window has reset since it was fetched is never shown as current (F-3, #4, #7; `METRIC_CONTRACT.md` §3).
/// Synthetic sandbox only.
@MainActor
struct TrustStateTests {
    // MARK: Transcript source availability

    @Test func noTranscriptFolderIsNotFound() async throws {
        let box = try Sandbox()
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        #expect(services.ledger.claudeSource == .notFound)
        #expect(services.store.claudeSource == .notFound)
        // No data and no folder: no zero tiles, a reason instead.
        #expect(services.store.displayedClaudeUsage == nil)
        #expect(SourceText.note(.notFound, hasData: false) == SourceText.notFound)
        // The usage card's notes don't describe a Claude total that isn't shown.
        #expect(UsageCard.notes(services.store).isEmpty)
    }

    @Test func emptyTranscriptFolderIsFoundAndZeroIsObserved() async throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.home.appendingPathComponent(".claude/projects"),
                                                withIntermediateDirectories: true)
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.claudeSource == .found)
        // An existing, readable folder with nothing in it is an observed zero.
        #expect(services.store.displayedClaudeUsage?.month.tokens == 0)
        #expect(SourceText.note(.found, hasData: false) == nil)
    }

    @Test func unreadableTranscriptFolderIsReported() async throws {
        let box = try Sandbox()
        let projects = box.home.appendingPathComponent(".claude/projects")
        try box.write(".claude/projects/p/s.jsonl", Sandbox.transcriptLine(model: "claude-test-1", id: "a", canary: "x") + "\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: projects.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projects.path) }
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.claudeSource == .unreadable)
        #expect(services.store.displayedClaudeUsage == nil)
        #expect(SourceText.note(.unreadable, hasData: false) == SourceText.unreadable)
    }

    @Test func folderRemovedAfterReadingKeepsEarlierTotalsWithANote() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/p/s.jsonl", Sandbox.transcriptLine(model: "claude-test-1", id: "a", canary: "x") + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.claudeSource == .found)
        #expect(services.store.displayedClaudeUsage?.month.tokens == 150)

        try FileManager.default.removeItem(at: box.home.appendingPathComponent(".claude"))
        // Checked on every refresh, not only on the 5-minute full scan.
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.claudeSource == .notFound)
        // Previously counted usage isn't silently dropped, but it's labelled as no longer updating.
        #expect(services.store.displayedClaudeUsage?.month.tokens == 150)
        #expect(SourceText.note(.notFound, hasData: true) == SourceText.gone)
    }

    // MARK: Quota windows that have reset (F-3)

    private func entry(_ id: String, _ percent: Double?, resets: Date?) -> LimitEntry {
        LimitEntry(id: id, name: id, percent: percent, resetsAt: resets, window: 5 * 3600)
    }

    @Test func limitPastItsResetIsUnavailable() {
        let now = Date()
        let past = entry("session", 80, resets: now.addingTimeInterval(-1))
        let future = entry("weekly", 40, resets: now.addingTimeInterval(3600))
        #expect(past.current(at: now, stale: false).percent == nil)
        #expect(past.current(at: now, stale: false).note == LimitText.windowReset)
        #expect(LimitText.note(past.current(at: now, stale: false)) == LimitText.windowReset)
        #expect(future.current(at: now, stale: false).percent == 40)
        #expect(past.current(at: now, stale: false).resetsAt == nil) // never "resets in now"
        #expect(future.current(at: now, stale: true).percent == 40) // stale, but still within its window
        // Without a reset time a fresh value stands; a stale one has no proven window, so it's unavailable.
        let noReset = entry("model", 10, resets: nil)
        #expect(noReset.current(at: now, stale: false).percent == 10)
        #expect(noReset.current(at: now, stale: true).percent == nil)
    }

    @Test func storeAndGaugeUseOnlyCurrentLimits() {
        let now = Date()
        let store = Store()
        let session = entry("session", 80, resets: now.addingTimeInterval(-60))
        let weekly = entry("weekly", 40, resets: now.addingTimeInterval(86400))
        store.claudeLimits = ClaudeLimits(session: session, weekly: weekly, model: nil, all: [session, weekly], plan: "Max",
                                          fetchedAt: now.addingTimeInterval(-600))
        let current = store.currentClaudeLimits(at: now)
        #expect(current?.session?.percent == nil && current?.all.first?.percent == nil)
        #expect(current?.weekly?.percent == 40 && current?.all.last?.percent == 40)
        #expect(StatusRenderer.claudeGauge(store, now: now) == [nil, 40, nil])
        // After a failed refresh the orange line claims shown data only while some value is still shown.
        #expect(LimitText.staleNote("Offline", limits: current, fetchedAt: now).contains("showing data"))
        let allPast = ClaudeLimits(session: session, weekly: nil, model: nil, all: [session], plan: nil, fetchedAt: now)
        #expect(!LimitText.staleNote("Offline", limits: allPast.current(at: now, stale: true), fetchedAt: now)
            .contains("showing data"))
        // A 5-hour window that has already reset gives no window start.
        #expect(ProviderServices.windowStart(store.claudeLimits, now: now) == nil)
        let later = entry("session", 10, resets: now.addingTimeInterval(3600))
        store.claudeLimits?.session = later
        #expect(ProviderServices.windowStart(store.claudeLimits, now: now) == later.resetsAt!.addingTimeInterval(-5 * 3600))
    }

    @Test func grokPlanPastItsPeriodIsNotCurrent() {
        let now = Date()
        let store = Store()
        store.grokEnabled = true
        store.grokPlan = GrokPlan(percent: 70, periodStart: now.addingTimeInterval(-30 * 86400),
                                  periodEnd: now.addingTimeInterval(-1), periodName: "monthly", products: [],
                                  fetchedAt: now.addingTimeInterval(-3600))
        // Fresh plan, period over: waiting for the new period's answer, never shown or drawn as current.
        #expect(GrokSection.select(store, now: now) == .loading)
        #expect(StatusRenderer.grokGauge(store, now: now) == [nil])
        // Kept through a temporary failure past its period: the failure, not a stale plan.
        store.grokFailure = .network
        #expect(GrokSection.select(store, now: now) == .failure(.network))
        // Within its period, a stale plan is still shown as stale.
        store.grokPlan?.periodEnd = now.addingTimeInterval(86400)
        #expect(GrokSection.select(store, now: now) == .plan(.init(staleBecause: .network)))
        // With no period end, a fresh plan is shown, and a stale one has no proven period, so its failure shows.
        store.grokPlan?.periodEnd = nil
        #expect(GrokSection.select(store, now: now) == .failure(.network))
        store.grokFailure = nil
        #expect(GrokSection.select(store, now: now) == .plan(.init(staleBecause: nil)))
    }
}
