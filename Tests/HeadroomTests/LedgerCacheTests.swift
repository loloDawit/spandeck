import Foundation
import Testing
@testable import Headroom

/// R8: the usage cache keeps no transcript paths, message or request ids, or content; it is owner-only; a version 3
/// cache is deleted and re-indexed; and clearing it is safe while the app runs. Synthetic transcripts only, under a
/// throwaway sandbox. Every Claude line is 100 input + 50 output tokens unless a test says otherwise.
@MainActor
struct LedgerCacheTests {
    nonisolated static let userCanary = "CANARYUSER9q2w"
    nonisolated static let projectCanary = "CANARYPROJ4e5r"
    nonisolated static let messageCanary = "CANARYMSG7f3a"
    nonisolated static let requestCanary = "CANARYREQ1b8c"
    nonisolated static let promptCanary = "CANARY-PROMPT-6d0e"
    nonisolated static let toolCanary = "CANARY-TOOL-ARG-3k7m"
    nonisolated static let projectDir = ".claude/projects/-Users-\(userCanary)-\(projectCanary)"

    /// One assistant line with explicit ids, token counts and content.
    nonisolated static func line(id: String, req: String, output: Int = 50, model: String = "claude-test-1", date: Date = Date(),
                     text: String = "x") -> String {
        let ts = ISO8601DateFormatter().string(from: date)
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(req)","message":{"id":"\#(id)","model":"\#(model)","#
            + #""content":[{"type":"text","text":"\#(text)"},{"type":"tool_use","name":"Bash","input":{"command":"\#(toolCanary)"}}],"#
            + #""usage":{"input_tokens":100,"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

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

        /// A new ledger over the same home and Application Support, as after a relaunch.
        func ledger() -> Ledger { Ledger(home: box.home, appSupport: box.appSupport, pricing: pricing, storage: storage) }

        var cacheURL: URL { box.appSupport.appendingPathComponent(Ledger.cacheName) }
        var keyURL: URL { box.appSupport.appendingPathComponent(Ledger.keyName) }

        func cacheJSON() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        }

        @discardableResult
        func transcript(_ lines: [String], file: String = "s1.jsonl", newline: Bool = true) throws -> URL {
            try box.write("\(LedgerCacheTests.projectDir)/\(file)", lines.joined(separator: "\n") + (newline ? "\n" : ""))
        }
    }

    private static func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    /// The single-id keys in `links` (#55), after checking that each points to an operation in `seen` (or none).
    private static func linkIDs(_ json: [String: Any]) -> [String] {
        let links = json["links"] as? [String: [String: Any]] ?? [:]
        let seen = Set((json["seen"] as? [String: Any] ?? [:]).keys)
        for target in links.values.map({ $0["target"] as? String ?? "" }) {
            #expect(target == "ambiguous" || seen.contains(target))
        }
        return Array(links.keys)
    }

    private static func tokens(_ ledger: Ledger) async -> Int { await refreshLedger(ledger).claude.month.tokens }

    private static func clear(_ ledger: Ledger) async -> LedgerClearFailure? {
        await withCheckedContinuation { c in ledger.clearCache { c.resume(returning: $0) } }
    }

    // MARK: What is stored

    /// Tests 1-4: no absolute path, user or project name, message or request id, prompt or tool content.
    @Test func cacheHoldsNoPathsIdsOrContent() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_\(Self.messageCanary)", req: "req_\(Self.requestCanary)", text: Self.promptCanary)])
        try rig.box.write("\(Self.projectDir)/s1/subagents/agent-1.jsonl",
                          Self.line(id: "msg_sub", req: "req_sub", text: Self.promptCanary) + "\n")
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 300)

        let cache = String(decoding: try Data(contentsOf: rig.cacheURL), as: UTF8.self)
        let key = try Data(contentsOf: rig.keyURL)
        for canary in [Self.userCanary, Self.projectCanary, Self.messageCanary, Self.requestCanary, Self.promptCanary,
                       Self.toolCanary, rig.box.root.lastPathComponent, "s1.jsonl", "agent-1", "subagents", "msg_", "req_",
                       ".claude", "Users"] {
            #expect(!cache.contains(canary), "\(canary)")
            #expect(!String(decoding: key, as: UTF8.self).contains(canary), "\(canary)")
        }
        #expect(!cache.contains("/") && !cache.contains("\\/")) // no path at all, escaped or not
        let json = try rig.cacheJSON()
        #expect(json["version"] as? Int == 5)
        let ids = Array((json["files"] as? [String: Any] ?? [:]).keys) + Array((json["seen"] as? [String: Any] ?? [:]).keys)
            + Self.linkIDs(json)
        #expect(ids.count == 8 && Set(ids).count == 8) // 2 files, 2 messages, each message's 2 single ids
        #expect(ids.allSatisfy { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
        #expect(key.count == 32)
    }

    /// Tests 5-6: a relaunch reuses the same ids and offsets: nothing is read again and nothing is counted twice.
    @Test func relaunchKeepsIdsAndOffsets() async throws {
        let rig = try Rig()
        let file = try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let first = rig.ledger()
        #expect(await Self.tokens(first) == 150)
        first.flush()
        let before = try rig.cacheJSON()

        // Same size, different message id: only a ledger that ignored the saved offset would count it.
        try Data((Self.line(id: "msg_B", req: "req_A") + "\n").utf8).write(to: file)
        let second = rig.ledger()
        #expect(await Self.tokens(second) == 150)
        second.flush()
        let after = try rig.cacheJSON()
        #expect(Set((before["files"] as? [String: Any] ?? [:]).keys) == Set((after["files"] as? [String: Any] ?? [:]).keys))
        #expect(Set((before["seen"] as? [String: Any] ?? [:]).keys) == Set((after["seen"] as? [String: Any] ?? [:]).keys))

        // New data after the relaunch is still counted once.
        try rig.transcript([Self.line(id: "msg_B", req: "req_A"), Self.line(id: "msg_C", req: "req_C")])
        #expect(await Self.tokens(second) == 300)
    }

    /// Test 7: different files and different messages keep different ids; the same message in two files counts once.
    @Test func distinctInputsStayDistinct() async throws {
        let rig = try Rig()
        // The last two only differ in where the id ends and the request id starts.
        try rig.transcript([Self.line(id: "msg_A", req: "req_A"), Self.line(id: "msg_A", req: "req_B"),
                            Self.line(id: "msg_AB", req: "req_X"), Self.line(id: "msg_ABreq_", req: "X")])
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")], file: "s2.jsonl") // a resumed session repeats it
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 4 * 150)
        ledger.flush()
        let json = try rig.cacheJSON()
        #expect((json["files"] as? [String: Any])?.count == 2)
        #expect((json["seen"] as? [String: Any])?.count == 4)
    }

    /// Test 8: a streamed message logged again with growing counts is counted once, also across a relaunch.
    @Test func streamingGrowthCountedOnce() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_S", req: "req_S", output: 50), Self.line(id: "msg_S", req: "req_S", output: 80)])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 180)
        ledger.flush()

        try rig.transcript([Self.line(id: "msg_S", req: "req_S", output: 50), Self.line(id: "msg_S", req: "req_S", output: 80),
                            Self.line(id: "msg_S", req: "req_S", output: 120)])
        #expect(await Self.tokens(rig.ledger()) == 220)
    }

    /// Test 9: a partial last line waits for its newline; a rewritten, shorter file is re-read without double counting.
    @Test func partialAndRewrittenFiles() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A"), Self.line(id: "msg_B", req: "req_B")], newline: false)
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A"), Self.line(id: "msg_B", req: "req_B")])
        #expect(await Self.tokens(ledger) == 300)
        ledger.flush()

        // Rewritten shorter (e.g. compacted): earlier lines are skipped by their ids, a new one is counted.
        try rig.transcript([Self.line(id: "msg_C", req: "req_C")])
        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 450)
        try rig.transcript([Self.line(id: "msg_C", req: "req_C"), Self.line(id: "msg_A", req: "req_A")])
        #expect(await Self.tokens(relaunched) == 450)
    }

    // MARK: Permissions

    /// Tests 10-12: 0700 folder, 0600 cache and key, kept when a 0644 file is replaced; no temp file left.
    @Test func ownerOnlyModes() async throws {
        let rig = try Rig()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.box.appSupport.path)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        #expect(try Self.mode(rig.box.appSupport) == 0o700)
        #expect(try Self.mode(rig.cacheURL) == 0o600 && Self.mode(rig.keyURL) == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.cacheURL.path)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A"), Self.line(id: "msg_B", req: "req_B")])
        _ = await Self.tokens(ledger)
        ledger.flush()
        #expect(try Self.mode(rig.cacheURL) == 0o600)
        let items = try FileManager.default.contentsOfDirectory(atPath: rig.box.appSupport.path)
        #expect(!items.contains { $0.contains(".tmp-") })
    }

    /// Test 13: a permissive cache and key from an earlier run are tightened when loaded, before any save.
    @Test func permissiveFilesTightenedOnLoad() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        for url in [rig.cacheURL, rig.keyURL, rig.box.appSupport] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let relaunched = rig.ledger()
        #expect(await Self.tokens(relaunched) == 150)
        #expect(try Self.mode(rig.box.appSupport) == 0o700)
        #expect(try Self.mode(rig.cacheURL) == 0o600 && Self.mode(rig.keyURL) == 0o600)
    }

    /// Test 14: if the folder can't be made owner-only, nothing is written (there or anywhere else) and it's reported.
    @Test func failedTighteningWritesNothing() async throws {
        let rig = try Rig(storage: { url in
            var d = PrivateDirectory(url: url)
            d.setMode = { _, _ in -1 }
            return d
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.box.appSupport.path)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150) // usage still counted, in memory
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.permissions))
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
        #expect(!FileManager.default.fileExists(atPath: rig.keyURL.path))
        #expect(try Self.files(under: rig.box.root).allSatisfy { !$0.contains("claude-ledger") })
        #expect(try Self.mode(rig.box.appSupport) == 0o755)
    }

    /// A symlinked cache folder is never written through, read or cleared.
    @Test func symlinkedFolderRefused() async throws {
        let rig = try Rig()
        let elsewhere = rig.box.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: elsewhere.appendingPathComponent(Ledger.cacheName))
        try FileManager.default.removeItem(at: rig.box.appSupport)
        try FileManager.default.createSymbolicLink(at: rig.box.appSupport, withDestinationURL: elsewhere)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])

        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.unsafeLocation))
        #expect(await Self.clear(ledger) == .cache(.unsafeLocation))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path) == [Ledger.cacheName])
        #expect(try String(contentsOf: elsewhere.appendingPathComponent(Ledger.cacheName), encoding: .utf8) == "unrelated")
    }

    /// A symlink at the cache path is removed (the link, not its target) and never read.
    @Test func symlinkedCacheFileRemovedNotFollowed() async throws {
        let rig = try Rig()
        let target = rig.box.root.appendingPathComponent("target.json")
        try Data("keep me".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: rig.cacheURL, withDestinationURL: target)
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep me")
        #expect(try FileManager.default.attributesOfItem(atPath: rig.cacheURL.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Self.mode(rig.cacheURL) == 0o600) // a regular file now
    }

    /// One assistant line with only the given ids (#55); `nil` leaves the field out.
    nonisolated static func partialLine(id: String?, req: String?, output: Int = 50, date: Date = Date()) -> String {
        let ts = ISO8601DateFormatter().string(from: date)
        let r = req.map { #""requestId":"\#($0)","# } ?? ""
        let m = id.map { #""id":"\#($0)","# } ?? ""
        return #"{"type":"assistant","timestamp":"\#(ts)",\#(r)"message":{\#(m)"model":"claude-test-1","#
            + #""content":[{"type":"text","text":"\#(promptCanary)"}],"#
            + #""usage":{"input_tokens":100,"output_tokens":\#(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }

    /// #55: operations known by one id or by a fingerprint are stored as opaque ids too, never as ids or content.
    @Test func partialAndKeylessOperationsStoreNoIds() async throws {
        let rig = try Rig()
        try rig.transcript([Self.partialLine(id: "msg_\(Self.messageCanary)", req: nil),
                            Self.partialLine(id: nil, req: "req_\(Self.requestCanary)"),
                            Self.partialLine(id: nil, req: nil), Self.partialLine(id: "  ", req: "", output: 60)])
        let ledger = rig.ledger()
        let s = await refreshLedger(ledger).claude
        #expect(s.month.tokens == 3 * 150 + 160)
        #expect(s.month.identity == IdentityCoverage(incomplete: 2, fingerprinted: 2))
        ledger.flush()

        let cache = String(decoding: try Data(contentsOf: rig.cacheURL), as: UTF8.self)
        for canary in [Self.messageCanary, Self.requestCanary, Self.promptCanary, "msg_", "req_", Self.userCanary] {
            #expect(!cache.contains(canary), "\(canary)")
        }
        let json = try rig.cacheJSON()
        let seen = Array((json["seen"] as? [String: Any] ?? [:]).keys)
        #expect(seen.count == 4 && seen.allSatisfy { $0.count == 32 && $0.allSatisfy(\.isHexDigit) })
        #expect(Self.linkIDs(json).isEmpty) // links come from pairs only
        #expect(try Self.mode(rig.cacheURL) == 0o600 && Self.mode(rig.box.appSupport) == 0o700)
    }

    // MARK: Migration

    /// #55: a version 4 cache, even under the right key, is deleted and the transcripts re-indexed into version 5. A
    /// version 4 ledger counted records without ids on every read and merged records with empty ids, so its totals
    /// can't be kept, and none of them are mixed into the new ones. The key file is kept.
    @Test func version4CacheReplaced() async throws {
        let rig = try Rig()
        try rig.transcript([Self.partialLine(id: nil, req: nil)])
        let first = rig.ledger()
        #expect(await Self.tokens(first) == 150)
        first.flush()
        let keyCheck = try #require(try rig.cacheJSON()["keyCheck"] as? String)
        let key = try Data(contentsOf: rig.keyURL)
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let agg = #"{"input":987654321,"output":0,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":3}"#
        let v4 = #"{"version":4,"keyCheck":"\#(keyCheck)","files":{},"seen":{},"hours":{"\#(hour)":{"claude-test-1":\#(agg)}}}"#
        try Data(v4.utf8).write(to: rig.cacheURL)
        let transcripts = try rig.box.snapshot(".claude")

        let second = rig.ledger()
        let s = await refreshLedger(second).claude
        #expect(s.month.tokens == 150 && s.month.identity == IdentityCoverage(fingerprinted: 1)) // nothing from v4
        #expect(second.cacheIssue == nil)
        let cache = String(decoding: try Data(contentsOf: rig.cacheURL), as: UTF8.self)
        #expect(!cache.contains("987654321"))
        #expect(try rig.cacheJSON()["version"] as? Int == 5 && Self.mode(rig.cacheURL) == 0o600)
        #expect(try Data(contentsOf: rig.keyURL) == key)
        #expect(try rig.box.snapshot(".claude") == transcripts)
    }

    /// #55: a migration interrupted before the new cache is saved. If the folder can't be prepared, nothing is read
    /// or deleted and the version 4 cache waits for the next launch. If the app stops after the old cache was deleted
    /// but before the new one was saved, the next launch finds no cache and indexes again. Either way the totals are
    /// the transcripts', counted once.
    @Test func interruptedMigrationCountsOnce() async throws {
        let rig = try Rig()
        try rig.transcript([Self.partialLine(id: "msg_A", req: nil), Self.partialLine(id: nil, req: nil)])
        let v4 = #"{"version":4,"keyCheck":"x","files":{},"seen":{},"hours":{}}"#
        try Data(v4.utf8).write(to: rig.cacheURL)

        var blocked = PrivateDirectory(url: rig.box.appSupport)
        blocked.setMode = { _, _ in -1 }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.box.appSupport.path)
        let refused = Ledger(home: rig.box.home, appSupport: rig.box.appSupport, pricing: rig.pricing, storage: blocked)
        #expect(await Self.tokens(refused) == 300) // counted in memory
        refused.flush()
        #expect(refused.cacheIssue == .notSaved(.permissions))
        #expect(try Data(contentsOf: rig.cacheURL) == Data(v4.utf8)) // untouched, not mixed

        let migrated = rig.ledger()
        #expect(await Self.tokens(migrated) == 300)
        migrated.flush()
        #expect(try rig.cacheJSON()["version"] as? Int == 5 && Self.mode(rig.box.appSupport) == 0o700)

        // The state a stop between deleting the old cache and saving the new one leaves: no cache, the key kept.
        try FileManager.default.removeItem(at: rig.cacheURL)
        let relaunched = rig.ledger()
        let s = await refreshLedger(relaunched).claude
        #expect(s.month.tokens == 300 && s.month.identity == IdentityCoverage(incomplete: 1, fingerprinted: 1))
        relaunched.flush()
        #expect(await Self.tokens(rig.ledger()) == 300) // and again from the saved cache
    }

    /// #55: identity coverage is saved with the totals, and rebuilt the same after clearing the cache.
    @Test func identityCoverageSurvivesRelaunchAndClear() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A"), Self.partialLine(id: "msg_A", req: nil, output: 60),
                            Self.partialLine(id: nil, req: nil)])
        let ledger = rig.ledger()
        let want = IdentityCoverage(incomplete: 1, fingerprinted: 1)
        let first = await refreshLedger(ledger).claude
        #expect(first.month.tokens == 160 + 150 && first.month.identity == want && first.today.identity == want)
        ledger.flush()
        let relaunched = await refreshLedger(rig.ledger()).claude
        #expect(relaunched.month.tokens == 310 && relaunched.month.identity == want)
        #expect(await Self.clear(ledger) == nil)
        let rebuilt = await refreshLedger(ledger).claude
        #expect(rebuilt.month.tokens == 310 && rebuilt.month.identity == want)
    }

    /// Tests 15-16: a version 3 cache (raw paths and ids) is deleted and the transcripts re-indexed into version 5,
    /// with the same totals; its bytes don't survive.
    @Test func legacyCacheReplaced() async throws {
        let rig = try Rig()
        let file = try rig.transcript([Self.line(id: "msg_\(Self.messageCanary)", req: "req_\(Self.requestCanary)")])
        let hour = Int(Date().timeIntervalSince1970 / 3600)
        let v3 = #"{"version":3,"files":{"\#(file.path)":{"offset":5}},"seen":{"msg_\#(Self.messageCanary):req_\#(Self.requestCanary)":"#
            + #"{"hour":\#(hour),"parts":{"claude-test-1":{"input":987654321,"output":0,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":1}}}},"#
            + #""hours":{"\#(hour)":{"claude-test-1":{"input":987654321,"output":0,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":1}}}}"#
        try Data(v3.utf8).write(to: rig.cacheURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.cacheURL.path)
        let transcripts = try rig.box.snapshot(".claude")

        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150) // re-indexed; nothing from the old cache
        #expect(ledger.cacheIssue == nil)
        let cache = String(decoding: try Data(contentsOf: rig.cacheURL), as: UTF8.self)
        #expect(!cache.contains(Self.messageCanary) && !cache.contains(Self.userCanary) && !cache.contains("987654321"))
        #expect(try rig.cacheJSON()["version"] as? Int == 5 && Self.mode(rig.cacheURL) == 0o600)
        #expect(try rig.box.snapshot(".claude") == transcripts) // transcripts untouched
    }

    /// The old cache is deleted when found, even if the new one is never saved.
    @Test func legacyCacheDeletedBeforeAnySave() async throws {
        let rig = try Rig()
        try Data(#"{"version":3,"files":{"/Users/\#(Self.userCanary)/x.jsonl":{"offset":1}},"seen":{},"hours":{}}"#.utf8)
            .write(to: rig.cacheURL)
        let ledger = rig.ledger() // no transcripts: nothing to save
        #expect(await Self.tokens(ledger) == 0)
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
    }

    /// A corrupt cache, or a cache whose key is gone, is deleted and rebuilt; leftover temp files go too.
    @Test func unusableCacheRebuilt() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let first = rig.ledger()
        _ = await Self.tokens(first)
        try FileManager.default.removeItem(at: rig.keyURL)
        let temp = rig.box.appSupport.appendingPathComponent(".\(Ledger.cacheName).tmp-leftover")
        try Data("partial".utf8).write(to: temp)

        #expect(await Self.tokens(rig.ledger()) == 150)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: rig.keyURL.path))

        try Data("{not json".utf8).write(to: rig.cacheURL)
        #expect(await Self.tokens(rig.ledger()) == 150)
        #expect(try rig.cacheJSON()["version"] as? Int == 5)
    }

    /// A cache next to a different key (e.g. an old cache restored after a clear made a new key) is rebuilt, not
    /// loaded: its ids would all miss and every transcript would be counted again on top of its totals.
    @Test func cacheWithOtherKeyRebuilt() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let first = rig.ledger()
        #expect(await Self.tokens(first) == 150)
        try Data(repeating: 7, count: 32).write(to: rig.keyURL)

        #expect(await Self.tokens(rig.ledger()) == 150)
        #expect(await Self.tokens(rig.ledger()) == 150) // the rebuilt cache loads with the file's key
        #expect(try Data(contentsOf: rig.keyURL) == Data(repeating: 7, count: 32))
    }

    /// An old cache that can't be deleted is reported; usage is still counted from the transcripts.
    @Test func undeletableLegacyCacheReported() async throws {
        let rig = try Rig()
        try Data(#"{"version":3,"files":{},"seen":{},"hours":{}}"#.utf8).write(to: rig.cacheURL)
        try Self.setImmutable(rig.cacheURL, true)
        defer { try? Self.setImmutable(rig.cacheURL, false) }

        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 0) // nothing to save yet, so the load's report stands
        #expect(ledger.cacheIssue == .legacyNotRemoved(.io(EPERM)))
        #expect(FileManager.default.fileExists(atPath: rig.cacheURL.path))

        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.io(EPERM))) // the new cache can't replace it either
    }

    // MARK: Clearing

    /// Test 17: only the cache, its key and temp files are deleted; price files, other files and transcripts stay.
    @Test func clearRemovesOnlyCacheFiles() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        for name in ["pricing-source.json", "pricing.json", "unrelated.txt"] {
            try Data(name.utf8).write(to: rig.box.appSupport.appendingPathComponent(name))
        }
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        // Planted after launch (which sweeps leftovers), so only the clear can remove them.
        for name in [".\(Ledger.keyName).tmp-x", ".\(Ledger.cacheName).tmp-y"] {
            try Data("partial".utf8).write(to: rig.box.appSupport.appendingPathComponent(name))
        }
        let transcripts = try rig.box.snapshot(".claude")

        #expect(await Self.clear(ledger) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.box.appSupport.path).sorted()
                == ["pricing-source.json", "pricing.json", "unrelated.txt"])
        #expect(try rig.box.snapshot(".claude") == transcripts)
    }

    /// Tests 19-20: quitting right after a clear writes nothing; the next refresh rebuilds every file, including ones
    /// not touched recently, with correct totals and a new key.
    @Test func clearThenQuitWritesNothingAndRebuildIsComplete() async throws {
        let rig = try Rig()
        let cold = try rig.transcript([Self.line(id: "msg_A", req: "req_A")], file: "old.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6 * 3600)], ofItemAtPath: cold.path)
        try rig.transcript([Self.line(id: "msg_B", req: "req_B")])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 300)
        let oldKey = try Data(contentsOf: rig.keyURL)
        // Counted but not saved yet (saves are at most every 10 minutes): the clear must drop it too.
        try rig.transcript([Self.line(id: "msg_B", req: "req_B"), Self.line(id: "msg_C", req: "req_C")])
        #expect(await Self.tokens(ledger) == 450)

        #expect(await Self.clear(ledger) == nil)
        ledger.flush() // what quitting does
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
        #expect(!FileManager.default.fileExists(atPath: rig.keyURL.path))

        #expect(await Self.tokens(ledger) == 450)
        ledger.flush()
        #expect(try Data(contentsOf: rig.keyURL) != oldKey)
        #expect(await Self.tokens(rig.ledger()) == 450)
    }

    /// Test 18: after a clear, totals come only from the transcripts on disk, never from memory or old summaries.
    @Test func clearNeverResurrectsOldTotals() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        try FileManager.default.removeItem(at: rig.box.home.appendingPathComponent(".claude"))

        // A refresh queued just before the clear runs first; the clear then removes what it saved.
        ledger.refresh(windowStart: nil, progress: { _ in }, completion: { _, _, _ in })
        #expect(await Self.clear(ledger) == nil)
        ledger.flush()
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
        #expect(await Self.tokens(ledger) == 0)
        #expect(await Self.tokens(rig.ledger()) == 0)
    }

    /// A refresh that started before a clear can't publish its totals afterwards; the next one publishes the rebuild.
    @Test func staleRefreshNotPublishedAfterClear() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let services = ProviderServices(store: Store(), env: rig.box.environment(transport: FakeTransport()))
        let stale = Task { @MainActor in await services.refreshUsage(windowStart: nil) }
        await Task.yield() // the refresh is queued on the ledger before the clear
        await services.clearUsageCache()
        #expect(await stale.value == nil)
        #expect(services.store.claudeUsage == nil && services.store.usageUpdated == nil)
        #expect(services.store.usageCacheResult == UsageCacheText.cleared)

        #expect(await services.refreshUsage(windowStart: nil) != nil)
        #expect(services.store.claudeUsage?.month.tokens == 150)
    }

    /// Test 7 of #6: a failed delete reports failure and changes nothing.
    @Test func failedClearChangesNothing() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let services = ProviderServices(store: Store(), env: rig.box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()
        let cache = try Data(contentsOf: rig.cacheURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.box.appSupport.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.box.appSupport.path) }
        await services.clearUsageCache()
        #expect(services.store.usageCacheResult == LedgerClearFailure.cache(.io(EACCES)).text)
        #expect(services.store.usageCacheResult?.contains("Nothing was cleared") == true)
        #expect(services.store.claudeUsage?.month.tokens == 150)
        #expect(try Data(contentsOf: rig.cacheURL) == cache)
        // In-memory state was kept too: a refresh doesn't count the transcript again.
        await services.refreshUsage(windowStart: nil)
        #expect(services.store.claudeUsage?.month.tokens == 150)
    }

    /// If only the key can't be deleted, the clear still drops usage but says the key remained.
    @Test func undeletableKeyReported() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let services = ProviderServices(store: Store(), env: rig.box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        try Self.setImmutable(rig.keyURL, true)
        defer { try? Self.setImmutable(rig.keyURL, false) }

        await services.clearUsageCache()
        #expect(services.store.usageCacheResult == LedgerClearFailure.incomplete(.io(EPERM)).text)
        #expect(services.store.usageCacheResult != UsageCacheText.cleared)
        #expect(services.store.claudeUsage == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.cacheURL.path))
    }

    /// A folder that can be written but not listed (0300): leftover temp files can't be found, so the clear fails
    /// before deleting anything instead of reporting success with temp files left behind.
    @Test func unlistableFolderClearsNothing() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        let services = ProviderServices(store: Store(), env: rig.box.environment(transport: FakeTransport()))
        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()
        let temp = rig.box.appSupport.appendingPathComponent(".\(Ledger.cacheName).tmp-leftover")
        try Data("partial".utf8).write(to: temp)

        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: rig.box.appSupport.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.box.appSupport.path) }
        await services.clearUsageCache()
        #expect(services.store.usageCacheResult == LedgerClearFailure.cache(.io(EACCES)).text)
        #expect(services.store.claudeUsage?.month.tokens == 150)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.box.appSupport.path)
        #expect(FileManager.default.fileExists(atPath: rig.cacheURL.path) && FileManager.default.fileExists(atPath: temp.path))
        #expect(FileManager.default.fileExists(atPath: rig.keyURL.path))
    }

    /// At launch an unlistable folder is tightened to 0700 first, so leftover temp files are still found and removed.
    @Test func unlistableFolderSweptAtLaunch() async throws {
        let rig = try Rig()
        let temp = rig.box.appSupport.appendingPathComponent(".\(Ledger.keyName).tmp-leftover")
        try Data("partial".utf8).write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: rig.box.appSupport.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.box.appSupport.path) }
        let ledger = rig.ledger()
        _ = await Self.tokens(ledger)
        #expect(ledger.cacheIssue == nil)
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(try Self.mode(rig.box.appSupport) == 0o700)
    }

    /// If the folder can't be made 0700 (and so listable) at launch, nothing is loaded or saved and it's reported.
    @Test func unlistableFolderAtLaunchReported() async throws {
        let rig = try Rig(storage: { url in
            var d = PrivateDirectory(url: url)
            d.setMode = { _, _ in 0 } // claims success but leaves 0300
            return d
        })
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: rig.box.appSupport.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.box.appSupport.path) }
        let ledger = rig.ledger()
        #expect(await Self.tokens(ledger) == 150)
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.permissions))
    }

    /// Test 22: clearing and rebuilding touch no Keychain, network, CLI or login item.
    @Test func clearHasNoOtherSideEffects() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A")])
        try rig.box.installGrok()
        let transport = FakeTransport(), runner = FakeProcessRunner(), creds = FakeCredentialStore(nil), login = FakeLoginItem()
        let grokAuth = CountingGrokAuth(home: rig.box.home)
        let services = ProviderServices(store: Store(), env: rig.box.environment(
            transport: transport, runner: runner, credentials: creds, grokCredentials: grokAuth, loginItem: login))
        let grokFiles = try rig.box.grokFiles()

        await services.refreshUsage(windowStart: nil)
        await services.clearUsageCache()
        await services.refreshUsage(windowStart: nil)
        services.ledger.flush()

        #expect(services.store.claudeUsage?.month.tokens == 150 && services.store.grokUsage?.month.tokens == 150)
        #expect(transport.requests.isEmpty && runner.calls.isEmpty && creds.reads == 0 && grokAuth.reads == 0)
        #expect(login.registers == 0 && login.unregisters == 0)
        #expect(try rig.box.grokFiles() == grokFiles)
    }

    /// Test 21: R7 cost coverage is the same after a clear and rebuild.
    @Test func costCoverageSurvivesRebuild() async throws {
        let rig = try Rig()
        try rig.transcript([Self.line(id: "msg_A", req: "req_A", model: "claude-haiku-4-5-20251001"),
                            Self.line(id: "msg_B", req: "req_B", model: "claude-test-1")])
        let ledger = rig.ledger()
        let before = await refreshLedger(ledger).claude.month.cost
        #expect(before.coverage == .partial && before.knownTokens == 150 && before.unknownTokens == 150)
        #expect(await Self.clear(ledger) == nil)
        #expect(await refreshLedger(ledger).claude.month.cost == before)
    }

    /// The user immutable flag (chflags uchg): unlink and rename onto the file fail with EPERM in a folder we own.
    private static func setImmutable(_ url: URL, _ on: Bool) throws {
        try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path)
    }

    private static func files(under root: URL) throws -> [String] {
        guard let en = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return en.compactMap { $0 as? String }
    }
}
