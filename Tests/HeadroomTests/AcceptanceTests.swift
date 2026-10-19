import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Headroom

/// Private-use acceptance journeys (#94; matrix in `docs/VALIDATION.md`). Each test drives the app's own services,
/// store and popover view over a synthetic home and a recording transport, the way the app delegate does, and checks
/// what the user would see and which side effects happened. Nothing here touches the real home, Keychain, network
/// or login items; the offscreen render only reads the test process's standard defaults (`@AppStorage`). Drawing, the real `NSPopover`, clicks and the app process are the owner's checks.
@MainActor
struct AcceptanceTests {
    /// A synthetic Claude Code line for a model, with a fixed id pair: 100 input + 50 output tokens.
    private static func line(_ id: String, model: String = "claude-haiku-4-5", date: Date = Date()) -> String {
        Sandbox.transcriptLine(model: model, id: id, canary: "ACCEPTANCE-CANARY", date: date)
    }

    private func launch(_ box: Sandbox, transport: FakeTransport = FakeTransport(),
                        credentials: FakeCredentialStore = FakeCredentialStore(nil),
                        login: FakeLoginItem = FakeLoginItem()) -> ProviderServices {
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: credentials,
                                                                              loginItem: login))
        services.start()
        return services
    }

    /// Renders the popover offscreen, as the hosting controller would, and returns its size. A never-shown window:
    /// this proves the view tree builds and lays out for the state, not how it looks on screen.
    private func renderPopover(_ store: Store) -> NSSize {
        _ = NSApplication.shared
        let view = PopoverView(store: store, actions: PopoverActions(
            refresh: {}, quit: {}, keepAwake: { _ in }, loginItem: FakeLoginItem(), setClaudeLimits: { _ in },
            setGrokCredits: { _ in }, quotaSwitchChanged: { _, _ in }, updatePricing: {}, clearUsageCache: {}))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.contentView = nil
        return size
    }

    private func sane(_ size: NSSize) -> Bool { size.width > 600 && size.width < 900 && size.height > 200 && size.height < 1400 }

    // MARK: Journeys

    /// Fresh install, no Claude Code yet, nothing configured, offline: no zero totals, guidance instead, no side effects.
    @Test func freshInstallWithNothingConfigured() async throws {
        let box = try Sandbox()
        let transport = FakeTransport()
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let login = FakeLoginItem()
        let services = launch(box, transport: transport, credentials: creds, login: login)
        await services.refreshClaude()
        await services.refreshGrok()
        await services.refreshUsage(windowStart: nil)

        let store = services.store
        #expect(store.claudeSource == .notFound && store.displayedClaudeUsage == nil)
        #expect(SourceText.note(store.claudeSource, hasData: false) == SourceText.notFound)
        #expect(!store.claudeLimitsEnabled && !store.grokEnabled && store.claudeLimits == nil)
        #expect(store.pricing.source == .bundled)
        #expect(transport.requests.isEmpty && creds.reads == 0 && login.registers == 0)
        #expect(sane(renderPopover(store)))
    }

    /// Existing history: first index, an incremental update, a relaunch with the same totals, then a corrupt cache
    /// that is rebuilt to the same totals. Each message is counted exactly once throughout.
    @Test func historyIsCountedOnceAcrossUpdatesRelaunchAndCorruptCache() async throws {
        let box = try Sandbox()
        let file = try box.write(".claude/projects/p/s.jsonl", Self.line("a") + "\n" + Self.line("b") + "\n")
        let first = launch(box)
        await first.refreshUsage(windowStart: nil)
        #expect(first.store.displayedClaudeUsage?.today.tokens == 300)
        #expect(first.store.claudeUsage?.today.cost.coverage == .complete)

        // Incremental: one new message, and a streamed repeat of an old one that must not count again.
        let h = try FileHandle(forWritingTo: file)
        try h.seekToEnd()
        try h.write(contentsOf: Data((Self.line("c") + "\n" + Self.line("a") + "\n").utf8))
        try h.close()
        await first.refreshUsage(windowStart: nil)
        #expect(first.store.displayedClaudeUsage?.today.tokens == 450)

        // Quit (the #86 path: stop and save), then relaunch.
        let saved = await withCheckedContinuation { c in first.ledger.requestStop { c.resume(returning: $0) } }
        #expect(saved == .saved || saved == .nothingToSave)
        let relaunch = launch(box)
        await relaunch.refreshUsage(windowStart: nil)
        #expect(relaunch.store.displayedClaudeUsage?.today.tokens == 450)

        // A corrupt cache is discarded and rebuilt from the transcripts: same totals, never misread.
        try Data("{corrupt".utf8).write(to: box.appSupport.appendingPathComponent(Ledger.cacheName))
        let recovered = launch(box)
        await recovered.refreshUsage(windowStart: nil)
        #expect(recovered.store.displayedClaudeUsage?.today.tokens == 450)
        #expect(sane(renderPopover(recovered.store)))
    }

    /// Unsupported data: an unpriced model is counted with an unknown cost (never $0), and a usage record cut off
    /// mid-line is reported as unread, not silently dropped.
    @Test func unsupportedDataIsExplainedNotZeroed() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/p/s.jsonl", Self.line("a") + "\n" + Self.line("b", model: "claude-opus-9-1")
                        + "\n" + #"{"type":"assistant","message":{"id":"msg_x","usage":{"input_tokens":"#  + "\n")
        let services = launch(box)
        await services.refreshUsage(windowStart: nil)
        let usage = try #require(services.store.displayedClaudeUsage)
        #expect(usage.today.tokens == 300)
        #expect(usage.today.cost.coverage == .partial && Fmt.cost(usage.today.cost).hasPrefix("≥"))
        #expect(PricingText.coverageNote(claude: usage, grok: nil)?.contains("claude-opus-9-1") == true)
        #expect(UsageCard.notes(services.store).contains { $0.text == CompletenessText.incomplete })
        #expect(sane(renderPopover(services.store)))
    }

    /// Claude plan limits: consent reads the credential and polls; offline shows the error without inventing data;
    /// turning it off clears everything shown and stops all reads and requests (rollback).
    @Test func quotaIntegrationEnableOfflineAndRollBack() async throws {
        let box = try Sandbox()
        let transport = FakeTransport([Hosts.anthropic: [.claudeUsage, .timeout]])
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = launch(box, transport: transport, credentials: creds)

        await services.applyClaudeLimitsChoice(true)
        #expect(creds.reads == 1 && transport.requests.count == 1)
        #expect(StatusRenderer.claudeGauge(services.store) == [42, nil, nil])
        #expect(sane(renderPopover(services.store)))

        // Offline: the error is shown, the gauge blanks, the kept value is labelled stale with its age.
        await services.refreshClaude(force: true)
        #expect(services.store.claudeError != nil && StatusRenderer.claudeGauge(services.store) == [nil, nil, nil])
        #expect(LimitText.staleNote("Offline", limits: services.store.currentClaudeLimits(),
                                    fetchedAt: Date()).contains("showing data"))

        // Roll back: consent off clears what was shown and nothing is read or sent afterwards.
        await services.applyClaudeLimitsChoice(false)
        await services.refreshClaude(force: true)
        #expect(!services.store.claudeLimitsEnabled && services.store.claudeLimits == nil)
        #expect(box.preferences.bool(forKey: Prefs.claudeLimits) == false)
        #expect(creds.reads == 2 && transport.requests.count == 2)
        #expect(transport.unexpected.isEmpty)
    }

    /// A denied Keychain read (no credential returned) with consent: shown as not set up, no request sent.
    @Test func deniedCredentialSendsNothing() async throws {
        let box = try Sandbox()
        let transport = FakeTransport()
        let services = launch(box, transport: transport, credentials: FakeCredentialStore(nil))
        await services.applyClaudeLimitsChoice(true)
        #expect(transport.requests.isEmpty && services.store.claudeLimits == nil && !services.store.claudeAvailable)
    }

    /// Grok local usage is shown without consent; its credits integration stays off and nothing is run or sent.
    @Test func grokUsageWithoutCreditsConsent() async throws {
        let box = try Sandbox()
        try box.installGrok()
        let transport = FakeTransport()
        let runner = FakeProcessRunner()
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, runner: runner))
        services.start()
        await services.refreshGrok()
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.localGrokUsage?.today.tokens == 150)
        #expect(services.store.displayedClaudeUsage == nil) // no Claude folder: not shown as 0
        #expect(transport.requests.isEmpty && runner.calls.isEmpty)
        #expect(sane(renderPopover(services.store)))
    }

    /// Stopping mid-index (quit during a first scan) and relaunching gives exact totals: what was read is saved, the
    /// rest is read on the next launch, nothing twice (#86).
    @Test func quitDuringIndexingThenRelaunch() async throws {
        let box = try Sandbox()
        for i in 0..<60 { try box.write(".claude/projects/p/s\(i).jsonl", Self.line("m\(i)") + "\n") }
        let first = launch(box)
        let stopped = Flag()
        first.ledger.checkpointHook = { c in
            if c == .betweenFiles, !stopped.isSet { stopped.set(); first.ledger.requestStop { _ in } }
        }
        let published = await first.refreshUsage(windowStart: nil)
        #expect(published == nil) // a stopped refresh publishes nothing
        let relaunch = launch(box)
        await relaunch.refreshUsage(windowStart: nil)
        #expect(relaunch.store.displayedClaudeUsage?.today.tokens == 60 * 150)
    }
}
