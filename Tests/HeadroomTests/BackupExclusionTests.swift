import Foundation
import Testing
@testable import Headroom

/// Audit 0007, P4 (#70): the usage cache and its key are excluded from backup. Checked on the real filesystem: the
/// extended attribute Foundation's `isExcludedFromBackup` sets (which `tmutil isexcluded` reads) and a fresh-URL
/// `resourceValues` read, never a cached URL. Synthetic transcripts only, under a throwaway sandbox.
@MainActor
struct BackupExclusionTests {
    /// What `URLResourceValues.isExcludedFromBackup = true` writes on macOS (verified on APFS, macOS 26).
    nonisolated static let attribute = "com.apple.metadata:com_apple_backup_excludeItem"

    private struct Rig {
        let box: Sandbox
        let pricing: Pricing
        var storage: PrivateDirectory?

        init(storage: ((URL) -> PrivateDirectory)? = nil) throws {
            box = try Sandbox()
            pricing = Pricing(directory: box.appSupport, transport: FakeTransport())
            pricing.load()
            self.storage = storage?(box.appSupport)
        }

        func ledger() -> Ledger { Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing, storage: storage) }
        var cacheURL: URL { box.appSupport.appendingPathComponent(Ledger.cacheName) }
        var keyURL: URL { box.appSupport.appendingPathComponent(Ledger.keyName) }

        func transcript(_ ids: [String], file: String = "s1.jsonl") throws {
            try box.write("\(LedgerCacheTests.projectDir)/\(file)",
                          ids.map { LedgerCacheTests.line(id: "msg_\($0)", req: "req_\($0)") }.joined(separator: "\n") + "\n")
        }
    }

    /// The attribute on the file itself, read with getxattr(2) without following a link.
    static func hasAttribute(_ url: URL) -> Bool {
        getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// What Foundation reports, through a new URL so no cached resource value is read.
    static func foundationExcluded(_ url: URL) throws -> Bool {
        try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true
    }

    static func excluded(_ url: URL) throws -> Bool {
        let a = hasAttribute(url), f = try foundationExcluded(url)
        #expect(a == f, "getxattr and Foundation disagree for \(url.lastPathComponent)")
        return a && f
    }

    static func attributeNames(_ url: URL) -> [String] {
        let size = listxattr(url.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: size)
        _ = listxattr(url.path, &buf, size, XATTR_NOFOLLOW)
        return buf.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }

    static func inode(_ url: URL) throws -> UInt64 {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber).uint64Value
    }

    static func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    /// As a file written before #70: same bytes and inode, no attribute.
    static func unmark(_ url: URL) throws {
        if hasAttribute(url) { #expect(removexattr(url.path, attribute, XATTR_NOFOLLOW) == 0) }
        #expect(try !excluded(url))
    }

    static func tokens(_ ledger: Ledger) async -> Int { await refreshLedger(ledger).claude.month.tokens }

    static func clear(_ ledger: Ledger) async -> LedgerClearFailure? {
        await withCheckedContinuation { c in ledger.clearCache { c.resume(returning: $0) } }
    }

    // MARK: New installs, rewrites, clearing

    @Test func newCacheAndKeyAreExcluded() async throws {
        let rig = try Rig()
        try rig.transcript(["A"])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(ledger.cacheIssue == nil)
        #expect(try Self.excluded(rig.cacheURL) && Self.excluded(rig.keyURL))
        #expect(try Self.mode(rig.cacheURL) == 0o600 && Self.mode(rig.keyURL) == 0o600)
        #expect(try Self.mode(rig.box.appSupport) == 0o700)
    }

    /// Every save replaces the cache with a new file (rename(2)); each replacement carries the attribute.
    @Test func atomicReplacementKeepsExclusion() async throws {
        let rig = try Rig()
        try rig.transcript(["A"])
        let first = rig.ledger()
        _ = await Self.tokens(first)
        first.flush()
        let before = try Self.inode(rig.cacheURL)
        for (n, ids) in [["A", "B"], ["A", "B", "C"]].enumerated() {
            try rig.transcript(ids)
            let ledger = rig.ledger()
            #expect(await Self.tokens(ledger) == 150 * ids.count)
            ledger.flush()
            #expect(try Self.inode(rig.cacheURL) != before, "save \(n) didn't replace the file")
            #expect(try Self.excluded(rig.cacheURL) && Self.excluded(rig.keyURL))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.box.appSupport.path).allSatisfy { !$0.contains(".tmp-") })
    }

    /// After a clear, the next save makes a new key and cache, both excluded.
    @Test func regeneratedAfterClearAreExcluded() async throws {
        let rig = try Rig()
        try rig.transcript(["A"])
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        ledger.flush()
        let oldKey = try Data(contentsOf: rig.keyURL)
        #expect(await Self.clear(ledger) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
        #expect(!FileManager.default.fileExists(atPath: rig.keyURL.path))
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(try Data(contentsOf: rig.keyURL) != oldKey)
        #expect(try Self.excluded(rig.cacheURL) && Self.excluded(rig.keyURL))
    }

    // MARK: Existing installs

    /// A cache and key written before #70 are marked when they're loaded, even with nothing new to save: the key keeps
    /// its bytes and inode, the cache isn't rewritten or re-indexed, and nothing is counted twice.
    @Test func existingFilesAreMarkedAtLoad() async throws {
        let rig = try Rig()
        try rig.transcript(["A"])
        let first = rig.ledger()
        _ = await Self.tokens(first)
        first.flush()
        try Self.unmark(rig.cacheURL)
        try Self.unmark(rig.keyURL)
        let key = try Data(contentsOf: rig.keyURL), cache = try Data(contentsOf: rig.cacheURL)
        let keyInode = try Self.inode(rig.keyURL), cacheInode = try Self.inode(rig.cacheURL)

        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 150)
        #expect(relaunched.cacheIssue == nil)
        #expect(try Self.excluded(rig.keyURL) && Self.excluded(rig.cacheURL))
        #expect(try Data(contentsOf: rig.keyURL) == key && Self.inode(rig.keyURL) == keyInode)
        #expect(try Data(contentsOf: rig.cacheURL) == cache && Self.inode(rig.cacheURL) == cacheInode)
        #expect(try Self.mode(rig.cacheURL) == 0o600 && Self.mode(rig.keyURL) == 0o600)
    }

    /// An existing key is marked even when its cache is discarded at load (here: corrupt) and rebuilt.
    @Test func existingKeyMarkedWhenCacheIsRebuilt() async throws {
        let rig = try Rig()
        try rig.transcript(["A"])
        let first = rig.ledger()
        _ = await Self.tokens(first)
        first.flush()
        try Self.unmark(rig.keyURL)
        let key = try Data(contentsOf: rig.keyURL)
        try Data("not json".utf8).write(to: rig.cacheURL)

        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 150)
        relaunched.flush()
        #expect(try Data(contentsOf: rig.keyURL) == key)
        #expect(try Self.excluded(rig.keyURL) && Self.excluded(rig.cacheURL))
    }

    // MARK: What isn't touched

    /// Headroom's state gets no attribute and keeps its bytes; SpanDeck's price file isn't marked either (out of
    /// scope: public data), and neither is the folder.
    @Test func otherFilesGetNoAttribute() async throws {
        let rig = try Rig()
        let legacy = rig.box.root.appendingPathComponent("Headroom")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let legacyFiles = [Ledger.cacheName, Ledger.keyName, "pricing.json"].map { legacy.appendingPathComponent($0) }
        for f in legacyFiles { try Data("legacy \(f.lastPathComponent)".utf8).write(to: f) }
        try Data("prices".utf8).write(to: rig.box.appSupport.appendingPathComponent("pricing-source.json"))
        try rig.transcript(["A"])
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        ledger.flush()
        #expect(await Self.clear(ledger) == nil)
        _ = await Self.tokens(ledger)
        ledger.flush()

        #expect(try Self.excluded(rig.cacheURL))
        for f in legacyFiles + [legacy, rig.box.appSupport, rig.box.appSupport.appendingPathComponent("pricing-source.json")] {
            #expect(Self.attributeNames(f).filter { $0.contains("backup") } == [], "\(f.lastPathComponent)")
        }
        for f in legacyFiles {
            #expect(try String(contentsOf: f, encoding: .utf8) == "legacy \(f.lastPathComponent)")
        }
    }

    // MARK: Failures

    /// Names the marker was called with; it fails for the names `failing` accepts.
    final class Marker: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var failing: (String) -> Bool

        init(failing: @escaping (String) -> Bool = { _ in false }) { self.failing = failing }

        var calls: [String] { lock.withLock { names } }

        func storage(_ url: URL) -> PrivateDirectory {
            var d = PrivateDirectory(url: url)
            d.markExcluded = { [self] file in
                let name = file.lastPathComponent
                let fail = lock.withLock { names.append(name); return failing(name) }
                if fail { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path]) }
                try PrivateDirectory.setExcludedFromBackup(file)
            }
            return d
        }
    }

    /// A new file's temporary file is marked before any of its data is written (review of #90): a process that exits
    /// mid-write, as a quit that times out may (#86), leaves no unmarked temporary file holding cache data.
    @Test func temporaryFileIsMarkedBeforeItsData() throws {
        let box = try Sandbox()
        let sizes = Marker()
        var d = PrivateDirectory(url: box.appSupport)
        var seen: [Int] = []
        d.markExcluded = { file in
            seen.append(((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? -1)
            try PrivateDirectory.setExcludedFromBackup(file)
        }
        _ = sizes
        try d.write(Data(repeating: 7, count: 4096), to: "probe.json", excludedFromBackup: true)
        #expect(seen == [0], "marked while still empty: \(seen)")
        #expect(try Data(contentsOf: box.appSupport.appendingPathComponent("probe.json")).count == 4096)
    }

    /// A new cache or key is marked as a temporary file, before rename(2) puts it in place; the final name is only
    /// marked when it already existed at load.
    @Test func newFilesAreMarkedBeforeTheyAreInPlace() async throws {
        let marker = Marker()
        let rig = try Rig(storage: marker.storage)
        try rig.transcript(["A"])
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        ledger.flush()
        #expect(!marker.calls.isEmpty)
        #expect(marker.calls.allSatisfy { $0.hasPrefix(".") && $0.contains(".tmp-") }, "\(marker.calls)")
        // Typed in steps so older compilers (Xcode 16.4 on CI) type-check it quickly.
        let stems: Set<String> = Set(marker.calls.map { (name: String) -> String in
            String(name.dropFirst().prefix { $0 != "." })
        })
        #expect(stems == ["claude-ledger"])
    }

    /// Fail closed: a new cache or key that can't be marked is never moved into place. Nothing is written anywhere,
    /// no temporary file is left, usage is still counted in memory, and the reason is shown.
    @Test func unmarkableNewFilesAreNotWritten() async throws {
        let marker = Marker(failing: { _ in true })
        let rig = try Rig(storage: marker.storage)
        try rig.transcript(["A"])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.backupExclusion))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.box.appSupport.path).filter { $0.contains("claude-ledger") } == [])
    }

    /// An existing cache and key that can't be marked are kept and used, never deleted to enforce exclusion, and the
    /// reason is shown.
    @Test func unmarkableExistingFilesAreKeptAndReported() async throws {
        let plain = try Rig()
        try plain.transcript(["A"])
        let first = plain.ledger()
        _ = await Self.tokens(first)
        first.flush()
        try Self.unmark(plain.cacheURL)
        try Self.unmark(plain.keyURL)
        let key = try Data(contentsOf: plain.keyURL), cache = try Data(contentsOf: plain.cacheURL)

        var rig = plain
        let marker = Marker(failing: { _ in true })
        rig.storage = marker.storage(plain.box.appSupport)
        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 150)
        #expect(relaunched.cacheIssue == .notExcludedFromBackup)
        #expect(try Data(contentsOf: rig.keyURL) == key && Data(contentsOf: rig.cacheURL) == cache)
        #expect(try !Self.excluded(rig.keyURL) && !Self.excluded(rig.cacheURL))
    }

    /// The key is written once. If it can't be marked, a later successful cache save doesn't hide that; once it can
    /// be marked, the next save does so and the issue goes.
    @Test func cacheSaveDoesNotHideAnUnmarkedKey() async throws {
        let plain = try Rig()
        try plain.transcript(["A"])
        let first = plain.ledger()
        _ = await Self.tokens(first)
        first.flush()
        try Self.unmark(plain.keyURL)

        var rig = plain
        let marker = Marker(failing: { $0 == Ledger.keyName })
        rig.storage = marker.storage(plain.box.appSupport)
        try rig.transcript(["A", "B"])
        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 300)
        relaunched.flush()
        #expect(try Self.excluded(rig.cacheURL) && !Self.excluded(rig.keyURL))
        #expect(relaunched.cacheIssue == .notExcludedFromBackup)

        marker.failing = { _ in false }
        try rig.transcript(["A", "B", "C"])
        #expect(await Self.tokens(relaunched) == 450)
        relaunched.flush()
        #expect(try Self.excluded(rig.keyURL) && Self.excluded(rig.cacheURL))
        #expect(relaunched.cacheIssue == nil)
    }

    @Test func failureTextsAreFixed() {
        #expect(StorageFailure.backupExclusion.text == "the cache or its key couldn't be excluded from backups")
        #expect(LedgerCacheIssue.notSaved(.backupExclusion).text
                == "Usage cache not saved: the cache or its key couldn't be excluded from backups. Totals are kept in memory only.")
        #expect(LedgerCacheIssue.notExcludedFromBackup.text
                == "The usage cache or its key couldn't be excluded from backups. It is kept and still used, so backups may include it.")
    }
}
