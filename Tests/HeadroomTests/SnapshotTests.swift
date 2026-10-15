import AppKit
import Foundation
import Testing
@testable import Headroom

/// R10: `--snapshot` never exports real data. Release builds refuse it; debug builds render a synthetic store, decided
/// before any live service exists. Output goes to a throwaway sandbox folder only.
@MainActor
struct SnapshotTests {
    private static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func files(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private static func run(_ args: [String], debugBuild: Bool = true) -> (code: Int32?, log: [String]) {
        var log: [String] = []
        let code = SnapshotMode.run(arguments: args, debugBuild: debugBuild, log: { log.append($0) })
        return (code, log)
    }

    // MARK: Decision

    @Test func decision() {
        let folder = "/tmp/out"
        #expect(SnapshotMode.decide(arguments: ["Headroom"], debugBuild: true) == .normal)
        #expect(SnapshotMode.decide(arguments: ["Headroom"], debugBuild: false) == .normal)
        #expect(SnapshotMode.decide(arguments: ["Headroom", "-NSDocumentRevisionsDebugMode", "YES"], debugBuild: false) == .normal)
        #expect(SnapshotMode.decide(arguments: ["Headroom", "--snapshot", folder], debugBuild: false)
                == .rejected(SnapshotMode.releaseRefusal))
        #expect(SnapshotMode.decide(arguments: ["Headroom", "--snapshot", folder], debugBuild: true)
                == .snapshot(URL(fileURLWithPath: folder)))
        for args in [["Headroom", "--snapshot"], ["Headroom", "--snapshot", ""], ["Headroom", "--snapshot", "--other"]] {
            #expect(SnapshotMode.decide(arguments: args, debugBuild: true) == .rejected(SnapshotMode.missingFolder))
        }
        #expect(BuildConfig.isDebug) // tests build the debug configuration
    }

    /// Normal startup is untouched: no flag, no handling.
    @Test func normalLaunchNotHandled() {
        #expect(Self.run(["Headroom"]).code == nil && Self.run(["Headroom"], debugBuild: false).code == nil)
        #expect(Self.run(["Headroom"]).log.isEmpty)
    }

    // MARK: Release

    /// A release build refuses the flag and writes nothing.
    @Test func releaseWritesNothing() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let before = AppEnvironment.realEnvironmentsMade

        let r = Self.run(["Headroom", "--snapshot", out.path], debugBuild: false)
        #expect(r.code == 64 && r.log == [SnapshotMode.releaseRefusal])
        #expect(try Self.files(out).isEmpty)
        #expect(AppEnvironment.realEnvironmentsMade == before)
    }

    // MARK: Debug

    /// A debug snapshot writes the three images from the synthetic store, and builds no live environment (so no
    /// transcript scan, Keychain read, Grok CLI, request, sampling or login item can happen).
    @Test func debugWritesSyntheticImages() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let before = AppEnvironment.realEnvironmentsMade

        let r = Self.run(["Headroom", "--snapshot", out.path])
        #expect(r.code == 0, "\(r.log)")
        #expect(try Self.files(out) == SnapshotRenderer.fileNames.sorted())
        for name in SnapshotRenderer.fileNames {
            let data = try Data(contentsOf: out.appendingPathComponent(name))
            #expect(Array(data.prefix(8)) == Self.png && data.count > 1000, "\(name)")
        }
        #expect(r.log.last?.contains("synthetic data") == true)
        #expect(AppEnvironment.realEnvironmentsMade == before)
        // The preference override is in memory only and undone afterwards (no test passes these as arguments).
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #expect(SnapshotFixture.preferences.keys.allSatisfy { arguments[$0] == nil })
    }

    /// Every value comes from the fixture; nothing about this machine or user.
    @Test func fixtureIsSyntheticOnly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let s = SnapshotFixture.store(now: now)
        #expect(s.cpu?.total == 23 && s.gpu == 12 && s.memory?.total == 32 << 30 && s.battery?.percent == 82)
        #expect(s.claudeLimits?.session?.percent == 42 && s.claudeLimits?.plan == SnapshotFixture.plan)
        #expect(s.grokPlan?.percent == 18)
        #expect(Set(s.claudeUsage?.models.map(\.model) ?? []) == Set(SnapshotFixture.claudeModels))
        #expect(s.grokUsage?.models.map(\.model) == [SnapshotFixture.grokModel])
        #expect(s.claudeUsage?.month.tokens == 14 * 600_000 && s.claudeUsage?.month.cost.coverage == .complete)
        #expect(s.claudeError == nil && s.grokFailure == nil && s.indexing == nil)

        let text = [s.claudeLimits?.plan ?? "", s.grokPlan?.periodName ?? "", s.grokPlan?.products.map(\.name).joined() ?? "",
                    (s.claudeUsage?.models.map(\.model) ?? []).joined(), (s.grokUsage?.models.map(\.model) ?? []).joined(),
                    (s.claudeLimits?.all.map(\.name) ?? []).joined()].joined(separator: "|")
        for personal in [NSUserName(), NSFullUserName(), NSHomeDirectory(), Host.current().localizedName ?? "",
                         ProcessInfo.processInfo.hostName] where personal.count > 2 {
            #expect(!text.localizedCaseInsensitiveContains(personal), "\(personal)")
        }
        // Same input, same store.
        let again = SnapshotFixture.store(now: now)
        #expect(again.claudeUsage?.bars.map(\.tokens) == s.claudeUsage?.bars.map(\.tokens))
        #expect(again.cpuHistory.map(\.v) == s.cpuHistory.map(\.v))
    }

    // MARK: Output folder

    /// A missing folder, a file, a symlink to a folder or a read-only folder: nothing is written anywhere.
    @Test func invalidFoldersFailSafely() throws {
        let box = try Sandbox()
        let real = box.root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let file = box.root.appendingPathComponent("file.txt")
        try Data("x".utf8).write(to: file)
        let link = box.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let readOnly = box.root.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let missing = box.root.appendingPathComponent("missing/deeper")

        for target in [missing, file, link, readOnly] {
            let r = Self.run(["Headroom", "--snapshot", target.path])
            #expect(r.code == 73, "\(target.lastPathComponent)")
            #expect(r.log.first?.hasSuffix("Nothing was written.") == true)
        }
        #expect(try Self.files(real).isEmpty && Self.files(readOnly).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        #expect(try Data(contentsOf: file) == Data("x".utf8))
    }

    /// A symlink planted at an output file name is replaced, never written through.
    @Test func symlinkAtFileNameNotFollowed() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let target = box.root.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: out.appendingPathComponent("popover.png"), withDestinationURL: target)

        #expect(Self.run(["Headroom", "--snapshot", out.path]).code == 0)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("popover.png").path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
    }

    /// If writing fails part way, no image and no temporary file is left.
    @Test func failedWriteLeavesNothing() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files: [(name: String, data: Data)] = [("a.png", Data("a".utf8)), ("../escape/b.png", Data("b".utf8))]
        #expect(throws: (any Error).self) { try SnapshotOutput.write(files, in: out) }
        #expect(try Self.files(out).isEmpty)
    }
}
