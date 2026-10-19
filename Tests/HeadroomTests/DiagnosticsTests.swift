import Foundation
import Testing
@testable import Headroom

/// Opt-in local diagnostics (#94): off by default, explicit start and stop, bounded, retained for a limited time, and
/// nothing but numbers and fixed labels in what is stored or exported. Synthetic sandbox only.
@MainActor
struct DiagnosticsTests {
    private func file(_ box: Sandbox) -> URL { box.appSupport.appendingPathComponent(Diagnostics.fileName) }

    private func session(_ box: Sandbox) throws -> DiagnosticSession {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(DiagnosticSession.self, from: Data(contentsOf: file(box)))
    }

    @Test func offByDefaultAndWritesNothing() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/p/s.jsonl", Sandbox.transcriptLine(model: "claude-test-1", id: "a", canary: "x") + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        services.start()
        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()
        #expect(!services.diagnostics.isActive && !services.store.diagnosticsActive && !services.store.diagnosticsHasData)
        #expect(!FileManager.default.fileExists(atPath: file(box).path))
        #expect(box.preferences.object(forKey: Diagnostics.activeKey) == nil)
        // Recording without a session keeps nothing.
        services.diagnostics.record(.stall, ms: 500)
        #expect(services.diagnostics.eventCount == 0)
        let monitor = DiagnosticsMonitor(diagnostics: services.diagnostics)
        monitor.sync()
        #expect(!monitor.isInstalled)
    }

    @Test func startRecordsAndStopEndsEverything() async throws {
        let box = try Sandbox()
        try box.write(".claude/projects/p/s.jsonl", Sandbox.transcriptLine(model: "claude-test-1", id: "a", canary: "x") + "\n")
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        services.start()
        services.startDiagnostics()
        #expect(services.store.diagnosticsActive && services.store.diagnosticsSince != nil)
        let monitor = DiagnosticsMonitor(diagnostics: services.diagnostics)
        monitor.sync()
        #expect(monitor.isInstalled)

        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()
        services.stopDiagnostics()
        monitor.sync()
        #expect(!monitor.isInstalled && !services.store.diagnosticsActive && services.store.diagnosticsHasData)
        #expect(box.preferences.bool(forKey: Diagnostics.activeKey) == false)

        let s = try session(box)
        let kinds = s.events.map(\.kind)
        #expect(kinds.first == .sessionStart)
        #expect(s.events.contains { $0.kind == .cacheLoad && $0.detail == .absent })
        #expect(s.events.contains { $0.kind == .refresh && $0.detail == .cold && $0.ms != nil })
        #expect(s.events.contains { $0.kind == .cacheSave && $0.detail == .saved && ($0.bytes ?? 0) > 0 })
        #expect(s.events.contains { $0.kind == .process && $0.footprintMB != nil })
        // Owner-only, like the usage cache.
        let mode = try FileManager.default.attributesOfItem(atPath: file(box).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)

        // Stopped: nothing more is kept, in memory or in the file.
        services.diagnostics.record(.stall, ms: 500)
        services.diagnostics.persist(force: true)
        #expect(try session(box).events.count == s.events.count)
    }

    @Test func eventsAreBounded() throws {
        let box = try Sandbox()
        let d = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences)
        d.start()
        for _ in 0..<(Diagnostics.maxEvents + 100) { d.record(.stall, ms: 120) }
        d.stop()
        let s = try session(box)
        #expect(s.events.count == Diagnostics.maxEvents)
        #expect(s.dropped == 101) // the start event and 100 stalls, oldest first
        #expect(s.events.first?.kind == .stall)
    }

    @Test func sessionStopsItselfAfterItsMaximumAge() throws {
        let box = try Sandbox()
        let clock = TestClock()
        let d = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now })
        d.start()
        clock.advance(Diagnostics.maxSessionAge)
        d.record(.stall, ms: 200)
        #expect(!d.isActive && !box.preferences.bool(forKey: Diagnostics.activeKey))
        #expect(try session(box).events.map(\.kind) == [.sessionStart])
    }

    @Test func activeSessionResumesAtLaunchUntilItsMaximumAge() throws {
        let box = try Sandbox()
        let clock = TestClock()
        let first = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now })
        first.start()
        first.record(.launch, ms: 300)
        first.persist(force: true) // as at quit

        clock.advance(3600)
        let relaunch = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now })
        relaunch.restore()
        #expect(relaunch.isActive)
        relaunch.persist(force: true)
        #expect(try session(box).events.map(\.kind) == [.sessionStart, .launch, .sessionResume])

        clock.advance(Diagnostics.maxSessionAge)
        let late = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now })
        late.restore()
        #expect(!late.isActive && !box.preferences.bool(forKey: Diagnostics.activeKey))
        #expect(late.hasData) // kept for export until its retention ends
    }

    @Test func stoppedSessionIsDeletedAfterRetention() throws {
        let box = try Sandbox()
        let clock = TestClock()
        let d = Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now })
        d.start()
        d.stop()
        clock.advance(Diagnostics.retention - 60)
        Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now }).restore()
        #expect(FileManager.default.fileExists(atPath: file(box).path))
        clock.advance(120)
        Diagnostics(directory: PrivateDirectory(url: box.appSupport), preferences: box.preferences, now: { clock.now }).restore()
        #expect(!FileManager.default.fileExists(atPath: file(box).path))
    }

    @Test func deleteStopsAndRemoves() throws {
        let box = try Sandbox()
        let services = ProviderServices(store: Store(), env: box.environment(transport: FakeTransport()))
        services.startDiagnostics()
        services.deleteDiagnostics()
        #expect(!services.diagnostics.isActive && !services.store.diagnosticsHasData)
        #expect(services.store.diagnosticsMessage == DiagnosticsText.deleted)
        #expect(!FileManager.default.fileExists(atPath: file(box).path))
        #expect(services.diagnostics.exportData() == nil)
    }

    /// The export holds numbers, the closed enums and a fixed environment, nothing from the data or the machine's
    /// identity: no transcript text, model name, path, user or host name.
    @Test func exportCarriesNoContentPathOrIdentity() async throws {
        let box = try Sandbox()
        let canary = "RVDIAGCANARY"
        try box.write(".claude/projects/\(canary)-project/s.jsonl",
                      Sandbox.transcriptLine(model: "claude-\(canary)-1", id: "a", canary: canary) + "\n")
        let transport = FakeTransport([Hosts.anthropic: [.json(#"{"error":"\#(canary)"}"#, status: 500)]])
        let services = ProviderServices(store: Store(), env: box.environment(
            transport: transport, credentials: FakeCredentialStore(FakeCredentialStore.synthetic())))
        services.start()
        services.startDiagnostics()
        await services.applyClaudeLimitsChoice(true) // a failing quota refresh, recorded by category only
        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()
        let data = try #require(services.diagnostics.exportData())
        let text = try #require(String(data: data, encoding: .utf8))

        for needle in [canary, "claude-", box.root.path, NSHomeDirectory(), NSUserName(), ProcessInfo.processInfo.hostName] {
            #expect(!text.contains(needle), "export contains \(needle)")
        }
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["environment", "session"])
        let env = try #require(json["environment"] as? [String: String])
        #expect(Set(env.keys) == ["app", "version", "build", "macOS", "arch", "cores"])
        let session = try #require(json["session"] as? [String: Any])
        #expect(Set(session.keys) == ["schema", "startedAt", "updatedAt", "dropped", "events"])
        let events = try #require(session["events"] as? [[String: Any]])
        #expect(events.contains { $0["kind"] as? String == "error" && $0["detail"] as? String == "claudeQuota" })
        let allowed: Set<String> = ["t", "kind", "detail", "ms", "bytes", "cpuPercent", "footprintMB"]
        let labels = Set(DiagnosticKind.allCases.map(\.rawValue) + DiagnosticDetail.allCases.map(\.rawValue))
        for e in events {
            #expect(Set(e.keys).isSubset(of: allowed))
            for (k, v) in e {
                if let s = v as? String { #expect(labels.contains(s), "\(k) = \(s)") } else { #expect(v is NSNumber) }
            }
        }
    }

    @Test func disclosureStatesTheLimits() {
        let t = DiagnosticsText.disclosure
        for phrase in ["never uploaded", "no file names, paths, transcript content, prompts, model names", "5,000 entries",
                       "24 hours", "7 days", "Export saves a copy where you choose"] {
            #expect(t.contains(phrase), "\(phrase)")
        }
    }
}
