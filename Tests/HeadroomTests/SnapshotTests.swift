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

        // Split up so older compilers can type-check it in time.
        let products: [String] = s.grokPlan?.products.map(\.name) ?? []
        let claudeModels: [String] = s.claudeUsage?.models.map(\.model) ?? []
        let grokModels: [String] = s.grokUsage?.models.map(\.model) ?? []
        let limits: [String] = s.claudeLimits?.all.map(\.name) ?? []
        let parts: [String] = [s.claudeLimits?.plan ?? "", s.grokPlan?.periodName ?? "", products.joined(),
                               claudeModels.joined(), grokModels.joined(), limits.joined()]
        let text = parts.joined(separator: "|")
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

    // MARK: All or nothing (review of #39)

    private static func write(_ folder: URL, _ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }
    private static func read(_ folder: URL, _ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }
    private static func setImmutable(_ url: URL, _ on: Bool) throws {
        try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path)
    }

    /// An immutable second output: the first, already in place, is restored and nothing else changes.
    @Test func immutableOutputLeavesFolderUnchanged() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "strip-light.png", "old light")
        try Self.write(out, "strip-dark.png", "old dark")
        let dark = out.appendingPathComponent("strip-dark.png")
        try Self.setImmutable(dark, true)
        defer { try? Self.setImmutable(dark, false) }

        let r = Self.run(["Headroom", "--snapshot", out.path])
        #expect(r.code == 73 && r.log.first?.hasSuffix("Nothing was written.") == true, "\(r.log)")
        #expect(try Self.read(out, "strip-light.png") == "old light" && Self.read(out, "strip-dark.png") == "old dark")
        #expect(try Self.files(out) == ["strip-dark.png", "strip-light.png"]) // no popover, temp or set-aside file
    }

    /// A rename failing at the commit step, after two new images are in place (one replacing an old file, one new),
    /// removes both and restores the old one.
    @Test func commitFailureRestoresEverything() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "a.png", "old a")
        var commits = 0
        let failThirdCommit: (String, String) -> Int32 = { from, to in
            if from.contains(".tmp-") {
                commits += 1
                if commits == 3 { errno = EPERM; return -1 }
            }
            return rename(from, to)
        }
        let files: [(name: String, data: Data)] = [("a.png", Data("new a".utf8)), ("b.png", Data("new b".utf8)),
                                                   ("c.png", Data("new c".utf8))]
        #expect(throws: SnapshotWriteError.unchanged(EPERM)) {
            try SnapshotOutput.write(files, in: out, move: failThirdCommit)
        }
        #expect(try Self.files(out) == ["a.png"] && Self.read(out, "a.png") == "old a")

        // Success replaces the old outputs and leaves no set-aside copies.
        try SnapshotOutput.write(files, in: out)
        #expect(try Self.files(out) == ["a.png", "b.png", "c.png"] && Self.read(out, "a.png") == "new a")
    }

    /// If the old file can't be put back either, the error says the folder may have changed.
    @Test func failedRestoreReportedAsPartial() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "a.png", "old a")
        let failCommitAndRestore: (String, String) -> Int32 = { from, to in
            if from.contains(".tmp-") || from.contains(".old-") { errno = EPERM; return -1 }
            return rename(from, to)
        }
        var caught: Error?
        do { try SnapshotOutput.write([("a.png", Data("new a".utf8))], in: out, move: failCommitAndRestore) } catch { caught = error }
        #expect(caught as? SnapshotWriteError == .partial(EPERM))
        let text = SnapshotOutput.describe(try #require(caught), folder: out)
        #expect(text.contains("may have been replaced or removed") && !text.contains("Nothing was written"))
    }

    /// A folder (or FIFO) at an output name is never moved, hidden or replaced; nothing is written at all.
    @Test func nonFileAtOutputNameUntouched() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        let dir = out.appendingPathComponent("strip-light.png")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.write(dir, "mine.txt", "user content")
        let r = Self.run(["Headroom", "--snapshot", out.path])
        #expect(r.code == 73 && r.log.first?.contains("strip-light.png") == true, "\(r.log)")
        #expect(r.log.first?.hasSuffix("Nothing was written.") == true)
        #expect(try Self.files(out) == ["strip-light.png"] && Self.read(dir, "mine.txt") == "user content")

        let other = box.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(mkfifo(other.appendingPathComponent("popover.png").path, 0o644) == 0)
        #expect(Self.run(["Headroom", "--snapshot", other.path]).code == 73)
        #expect(try Self.files(other) == ["popover.png"])
    }

    /// A folder that appears at an output name between the check and the set-aside step stops the write and undoes it.
    @Test func folderAppearingLateIsNotMoved() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "a.png", "old a")
        var planted = false
        let plantFolder: (String, String) -> Int32 = { from, to in
            if !planted {
                planted = true
                try? FileManager.default.createDirectory(at: out.appendingPathComponent("b.png"), withIntermediateDirectories: true)
            }
            return rename(from, to)
        }
        #expect(throws: SnapshotWriteError.occupied("b.png")) {
            try SnapshotOutput.write([("a.png", Data("new a".utf8)), ("b.png", Data("new b".utf8))], in: out, move: plantFolder)
        }
        #expect(try Self.files(out) == ["a.png", "b.png"] && Self.read(out, "a.png") == "old a")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("b.png").path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// If a previous copy can't be removed after a successful write, that is reported, not ignored.
    @Test func leftoverOldCopyReported() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "a.png", "old a")
        let failOld: (String) -> Int32 = { path in
            if path.contains(".old-") { errno = EPERM; return -1 }
            return unlink(path)
        }
        var caught: Error?
        do { try SnapshotOutput.write([("a.png", Data("new a".utf8))], in: out, remove: failOld) } catch { caught = error }
        #expect(caught as? SnapshotWriteError == .oldCopyLeft(EPERM))
        #expect(try Self.read(out, "a.png") == "new a")
        #expect(SnapshotOutput.describe(try #require(caught), folder: out).contains("couldn't remove a previous copy"))
    }

    /// A folder found after an earlier output was set aside, and that output can't be put back: reported as partial,
    /// never as "Nothing was written".
    @Test func occupiedNameWithFailedRestoreIsPartial() throws {
        let box = try Sandbox()
        let out = box.root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Self.write(out, "a.png", "old a")
        var planted = false
        let plantThenFailRestore: (String, String) -> Int32 = { from, to in
            if from.contains(".old-") { errno = EPERM; return -1 } // putting a.png back fails
            if !planted {
                planted = true
                try? FileManager.default.createDirectory(at: out.appendingPathComponent("b.png"), withIntermediateDirectories: true)
            }
            return rename(from, to)
        }
        var caught: Error?
        do {
            try SnapshotOutput.write([("a.png", Data("new a".utf8)), ("b.png", Data("new b".utf8))], in: out,
                                     move: plantThenFailRestore)
        } catch { caught = error }
        #expect(caught as? SnapshotWriteError == .partial(EEXIST))
        let text = SnapshotOutput.describe(try #require(caught), folder: out)
        #expect(!text.contains("Nothing was written") && text.contains("may have been replaced or removed"))
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("a.png").path)) // really hidden
    }
}
