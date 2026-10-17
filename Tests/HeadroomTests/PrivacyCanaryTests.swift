import Foundation
import Testing
@testable import Headroom

/// #5: what SpanDeck keeps from Claude Code and Grok history, checked with synthetic canaries. Every sensitive field a
/// transcript can hold carries a canary: prompts, thinking, code, credential-shaped strings, repository and folder
/// names, paths, session and record ids, tool inputs and results, and broken lines. After each scenario (indexing,
/// an append, an in-place rewrite, a relaunch, an old cache replaced, a clear, a cache folder that can't be secured)
/// every file the app wrote and every string it would show is scanned.
///
/// Permitted, and asserted to be there: model ids (Claude in the cache and the UI; Grok in the UI only), token counts
/// and times. Everything else is leakage. Canaries contain `CANARY` so nothing here resembles a real secret.
struct PrivacyCanaryTests {
    // MARK: Canaries

    /// Must never appear in any file the app writes or any string it shows.
    static let forbidden = [
        "CANARYUSER", "CANARYREPO", "CANARY-PROMPT", "CANARY-THINKING", "CANARY-REPLY", "CANARYCODE", "sk-ant-CANARY",
        "AKIACANARY", "ghp_CANARY", "xai-CANARY", "CANARY-TOOL-INPUT", "CANARY-TOOL-RESULT", "CANARY-BRANCH",
        "CANARY-SESSION", "CANARY-UUID", "CANARY-SUMMARY", "CANARY-SYSTEM", "CANARY-TIER", "CANARY-ITER",
        "CANARYMSGID", "CANARYREQID", "CANARY-MALFORMED", "CANARY-UTF8", "CANARY-INVALID-USAGE", "CANARY-TS",
        "CANARY-PARTIAL", "CANARY-APPENDED", "CANARY-REWRITTEN", "CANARYGROKPROJ", "CANARYGROKSESSION",
        "CANARY-PLANTED", "canary_session_file", "CANARYCWD",
    ]
    /// Permitted model ids: shaped like a provider's, so kept as written (#66).
    static let claudeModel = "claude-CANARYMODEL-1"
    static let grokModel = "grok-CANARYGROKMODEL"

    static let projectDir = ".claude/projects/-Users-CANARYUSER-src-CANARYREPO"
    static let cwd = "/Users/CANARYUSER/src/CANARYREPO/CANARYCWD"

    private static func ts(_ offset: TimeInterval = 0) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset - 600))
    }

    /// The fields Claude Code writes around a record, each with a canary.
    private static func envelope(_ n: String) -> String {
        #""cwd":"\#(cwd)","gitBranch":"CANARY-BRANCH-\#(n)","sessionId":"CANARY-SESSION-\#(n)","uuid":"CANARY-UUID-\#(n)","parentUuid":"CANARY-UUID-p\#(n)","version":"2.0.0","userType":"external""#
    }

    /// A realistic session: a user prompt, an assistant reply with thinking, text, code and a tool call, the tool
    /// result, a summary and a system record, plus usage with a non-counter field and a sub-call in `iterations`.
    private static func session(_ n: String, model: String = claudeModel) -> [String] {
        let creds = "sk-ant-CANARY-KEY-\(n) AKIACANARY\(n)AWSKEY ghp_CANARYGITHUB\(n)"
        return [
            #"{"type":"user",\#(envelope(n)),"timestamp":"\#(ts())","message":{"role":"user","content":"CANARY-PROMPT-\#(n): please fix func CANARYCODE_\#(n)() { let key = \"\#(creds)\" }"}}"#,
            #"{"type":"assistant",\#(envelope(n)),"timestamp":"\#(ts(1))","requestId":"req_CANARYREQID_\#(n)","message":{"id":"msg_CANARYMSGID_\#(n)","type":"message","role":"assistant","model":"\#(model)","content":[{"type":"thinking","thinking":"CANARY-THINKING-\#(n)"},{"type":"text","text":"CANARY-REPLY-\#(n) func CANARYCODE_\#(n)()"},{"type":"tool_use","id":"toolu_CANARYMSGID_\#(n)","name":"Bash","input":{"command":"cat /Users/CANARYUSER/.env # CANARY-TOOL-INPUT-\#(n) \#(creds)"}}],"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":10,"ephemeral_1h_input_tokens":20},"cache_read_input_tokens":5,"service_tier":"CANARY-TIER-\#(n)","iterations":[{"type":"advisor","model":"claude-haiku-4-5-20251001","note":"CANARY-ITER-\#(n)","input_tokens":7,"output_tokens":3}]}}}"#,
            #"{"type":"user",\#(envelope(n)),"timestamp":"\#(ts(2))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_CANARYMSGID_\#(n)","content":"CANARY-TOOL-RESULT-\#(n) \#(creds)"}]},"toolUseResult":{"stdout":"CANARY-TOOL-RESULT-\#(n)"}}"#,
            #"{"type":"summary","summary":"CANARY-SUMMARY-\#(n)","leafUuid":"CANARY-UUID-\#(n)"}"#,
            #"{"type":"system",\#(envelope(n)),"timestamp":"\#(ts(3))","content":"CANARY-SYSTEM-\#(n)","level":"info"}"#,
        ]
    }

    /// Lines SpanDeck can't read, each carrying canaries, with a usage key so they reach the parser.
    private static let broken: [Data] = [
        Data(#"{"type":"assistant","timestamp":"\#(ts())","message":{"usage":{"input_tokens":1}},"text":"CANARY-MALFORMED sk-ant-CANARY-M""#.utf8),
        Data(#"{"type":"assistant","timestamp":"\#(ts())","message":{"model":"claude-x","usage":"CANARY-INVALID-USAGE"}}"#.utf8),
        Data(#"{"type":"assistant","timestamp":"CANARY-TS","message":{"model":"claude-x","usage":{"input_tokens":1}}}"#.utf8),
        Data(#"{"type":"assistant","usage":{"input_tokens":1},"text":"CANARY-UTF8 "#.utf8) + Data([0xFF, 0xFE]) + Data(#""}"#.utf8),
    ]
    /// No newline after it: pending, never parsed.
    private static let partial = #"{"type":"assistant","timestamp":"\#(ts())","message":{"text":"CANARY-PARTIAL sk-ant-CANARY-P","usage":{"inp"#

    // MARK: Rig

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
        var main: URL { box.home.appendingPathComponent("\(PrivacyCanaryTests.projectDir)/canary_session_file.jsonl") }
        var cacheURL: URL { box.appSupport.appendingPathComponent(Ledger.cacheName) }

        func writeFixtures() throws {
            var d = Data((PrivacyCanaryTests.session("A") + PrivacyCanaryTests.session("B")).joined(separator: "\n").utf8)
            d.append(0x0A)
            for b in PrivacyCanaryTests.broken { d.append(b); d.append(0x0A) }
            d.append(Data(PrivacyCanaryTests.partial.utf8))
            try box.write("\(PrivacyCanaryTests.projectDir)/canary_session_file.jsonl", "")
            try d.write(to: main)
            // A subagent transcript, and a Grok session with its CLI key (never read by the ledger).
            try box.write("\(PrivacyCanaryTests.projectDir)/canary_session_file/subagents/agent-CANARY-SESSION.jsonl",
                          PrivacyCanaryTests.session("S").joined(separator: "\n") + "\n")
            try box.write(".grok/auth.json", #"{"key":"xai-CANARY-GROK-KEY-0000"}"#)
            let ended = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-300))
            try box.write(".grok/sessions/CANARYGROKPROJ/CANARYGROKSESSION/usage.json",
                          #"{"turns":[{"endedAt":"\#(ended)","inputTokens":100,"outputTokens":50,"cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"totalTokens":150,"costUsdTicks":10,"primaryModelId":"\#(PrivacyCanaryTests.grokModel)","prompt":"CANARY-PROMPT-GROK"}]}"#)
        }

        /// Every regular file under the sandbox outside the fixtures (`~/.claude`, `~/.grok`): what the app wrote.
        func written() throws -> [URL] {
            let fixtures = [box.home.appendingPathComponent(".claude").path, box.home.appendingPathComponent(".grok").path]
            guard let en = FileManager.default.enumerator(at: box.root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
            var out: [URL] = []
            for case let url as URL in en {
                let p = url.resolvingSymlinksInPath().path
                if fixtures.contains(where: { p.hasPrefix(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path) }) { continue }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { out.append(url) }
            }
            return out
        }
    }

    private static func refresh(_ l: Ledger) async -> (claude: UsageSummary, grok: UsageSummary) {
        await withCheckedContinuation { c in
            l.refresh(windowStart: Date().addingTimeInterval(-5 * 3600), progress: { _ in },
                      completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
        }
    }

    /// Every string the usage card, the cost note and their tooltips would show for these summaries, plus the cache
    /// issue, but not the model rows (checked separately: model ids are permitted).
    private static func shown(_ s: (claude: UsageSummary, grok: UsageSummary), issue: LedgerCacheIssue?) -> [String] {
        var out: [String] = []
        for n in UsageNotes.notes(s.claude) { out += [n.text, n.detail] }
        out.append(PricingText.coverageNote(claude: s.claude, grok: s.grok) ?? "")
        for t in [s.claude.today, s.claude.week, s.claude.month, s.grok.today, s.grok.week, s.grok.month] {
            out += [Fmt.cost(t.cost), Fmt.costDetail(t.cost), Fmt.spokenCost(t.cost), Fmt.tokens(t.tokens)]
        }
        if let w = s.claude.window { out += [Fmt.costDetail(w.cost), Fmt.spokenCost(w.cost)] }
        out += (s.claude.bars + s.grok.bars).map(\.family)
        out.append(issue?.text ?? "")
        return out
    }

    /// The checks every scenario ends with.
    private static func check(_ rig: Rig, _ s: (claude: UsageSummary, grok: UsageSummary), _ ledger: Ledger,
                              _ label: String, malformed: Int = 2, cacheExpected: Bool = true) throws {
        // Files: raw bytes and their JSON-escaped forms.
        let files = try rig.written()
        for url in files {
            let bytes = try Data(contentsOf: url)
            let text = String(decoding: bytes, as: UTF8.self)
            for c in forbidden {
                #expect(bytes.range(of: Data(c.utf8)) == nil && !text.contains(c.replacingOccurrences(of: "/", with: "\\/")),
                        "\(label): \(c) in \(url.lastPathComponent)")
            }
            #expect(!text.contains(grokModel), "\(label): Grok model in \(url.lastPathComponent): Grok usage is never cached")
            #expect(!text.contains("/Users") && !text.contains("\\/Users"), "\(label): a path in \(url.lastPathComponent)")
        }
        let cache = files.first { $0.lastPathComponent == Ledger.cacheName }
        #expect((cache != nil) == cacheExpected, "\(label): cache file present: \(cache != nil)")
        if let cache {
            // The permitted model id is there: it's what models are counted by, and what the list shows.
            #expect(String(decoding: try Data(contentsOf: cache), as: UTF8.self).contains(claudeModel), "\(label)")
        }
        // Shown strings: model ids may appear (the cost note names unpriced models, the chart labels unknown
        // families by model); nothing else may.
        for string in shown(s, issue: ledger.cacheIssue) {
            for c in forbidden + ["/Users"] { #expect(!string.contains(c), "\(label): \(c) shown in \(string)") }
        }
        // Model rows: permitted ids only.
        let claudeModels = Set(s.claude.models.map(\.model)), grokModels = Set(s.grok.models.map(\.model))
        #expect(claudeModels == [claudeModel, "claude-haiku-4-5-20251001"], "\(label): \(claudeModels)")
        #expect(grokModels == [grokModel], "\(label): \(grokModels)")
        for m in claudeModels.union(grokModels) { for c in forbidden { #expect(!m.contains(c), "\(label): \(m)") } }
        // What couldn't be read is reported as counts, never content.
        #expect(s.claude.month.completeness.malformed == malformed && s.claude.month.completeness.undated == 1
                && s.claude.month.completeness.invalidUsage == 1 && s.claude.month.completeness.pending == 1, "\(label)")
    }

    // MARK: Scenarios

    @Test func indexAppendRewriteRelaunchAndClear() async throws {
        let rig = try Rig()
        try rig.writeFixtures()
        let ledger = rig.ledger()
        var s = await Self.refresh(ledger)
        #expect(s.claude.month.identity.identified == 3 && s.grok.month.tokens == 150)
        try Self.check(rig, s, ledger, "index")

        // Append (the hot-file tail path): a new session, still before the incomplete last line's fate.
        var appended = try Data(contentsOf: rig.main)
        appended.append(Data(("\n" + Self.session("C").joined(separator: "\n") + "\n").utf8))
        appended.append(Data(Self.partial.utf8))
        try appended.write(to: rig.main)
        s = await Self.refresh(ledger)
        #expect(s.claude.month.identity.identified == 4)
        try Self.check(rig, s, ledger, "append", malformed: 3) // the first incomplete line is now complete

        // An in-place rewrite (#56), byte for byte apart from one reply: read again from the start.
        var rewritten = try Data(contentsOf: rig.main)
        let at = try #require(rewritten.range(of: Data("CANARY-REPLY-C".utf8)))
        rewritten.replaceSubrange(at, with: Data("CANARY-REWRITTEN".utf8))
        let h = try FileHandle(forWritingTo: rig.main)
        try h.write(contentsOf: rewritten)
        try h.close()
        s = await Self.refresh(ledger)
        try Self.check(rig, s, ledger, "rewrite", malformed: 3)
        ledger.flush()

        // Relaunch from the saved cache.
        let relaunched = rig.ledger()
        s = await Self.refresh(relaunched)
        #expect(s.claude.month.identity.identified == 4)
        try Self.check(rig, s, relaunched, "relaunch", malformed: 3)
        relaunched.flush()

        // Clear: the cache and its key are gone; nothing is left behind but the public price data.
        let cleared = await withCheckedContinuation { c in relaunched.clearCache { c.resume(returning: $0) } }
        #expect(cleared == nil)
        let left = try rig.written().map(\.lastPathComponent)
        #expect(!left.contains(Ledger.cacheName) && !left.contains(Ledger.keyName) && !left.contains { $0.contains(".tmp-") },
                "after clear: \(left)")
        s = await Self.refresh(relaunched) // re-indexes what is still on disk
        try Self.check(rig, s, relaunched, "after clear", malformed: 3)
    }

    /// Older caches holding raw paths, ids and other content are deleted, never carried over (R8, #55, #58, #57).
    @Test(arguments: [3, 6])
    func oldCachesAreReplaced(_ version: Int) async throws {
        let rig = try Rig()
        try rig.writeFixtures()
        let first = rig.ledger()
        _ = await Self.refresh(first)
        first.flush()
        let keyCheck = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: rig.cacheURL)) as? [String: Any])?["keyCheck"] as? String)
        let planted: String
        if version == 3 {
            planted = #"{"version":3,"files":{"/Users/CANARYUSER/src/CANARYREPO/x.jsonl":{"offset":1}},"seen":{"msg_CANARYMSGID_old:req_CANARYREQID_old":{"hour":1,"parts":{}}},"hours":{},"note":"CANARY-PLANTED"}"#
        } else {
            planted = #"{"version":6,"keyCheck":"\#(keyCheck)","files":{},"seen":{},"links":{},"hours":{"1":{"CANARY-PLANTED-model":{"input":1,"output":0,"cacheWrite5m":0,"cacheWrite1h":0,"cacheRead":0,"calls":1}}},"identity":{},"flawed":{},"unread":{}}"#
        }
        try Data(planted.utf8).write(to: rig.cacheURL)
        let ledger = rig.ledger()
        let s = await Self.refresh(ledger)
        ledger.flush()
        try Self.check(rig, s, ledger, "v\(version) replaced")
    }

    /// A cache folder that can't be made owner-only: nothing is written, totals stay in memory, and the reason shown
    /// names no path and no content.
    @Test func unsecuredFolderWritesNothingAndSaysNothingSensitive() async throws {
        let rig = try Rig(storage: { url in
            var d = PrivateDirectory(url: url)
            d.setMode = { _, _ in -1 }
            return d
        })
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.box.appSupport.path)
        try rig.writeFixtures()
        let ledger = rig.ledger()
        let s = await Self.refresh(ledger)
        ledger.flush()
        #expect(ledger.cacheIssue == .notSaved(.permissions))
        try Self.check(rig, s, ledger, "unsecured", cacheExpected: false)
    }

    /// Finding P1 in docs/audits/0007-privacy-verification.md (#66): a model id that isn't shaped like a provider's
    /// (here 2,000 characters with spaces and slashes) is counted as `unknown`, with its tokens, and the raw text is
    /// neither cached nor shown. `ModelIdentifierTests` covers the policy itself.
    @Test func invalidModelIdIsNotKept() async throws {
        let rig = try Rig()
        let model = "claude-" + String(repeating: "x", count: 2000) + "-CANARY-IN-MODEL id with spaces/and slashes"
        try rig.box.write("\(Self.projectDir)/m.jsonl", Self.session("M", model: model).joined(separator: "\n") + "\n")
        let ledger = rig.ledger()
        let s = await Self.refresh(ledger)
        ledger.flush()
        #expect(Set(s.claude.models.map(\.model)) == ["unknown", "claude-haiku-4-5-20251001"])
        #expect(s.claude.models.first { $0.model == "unknown" }?.tokens == 185)
        let cache = String(decoding: try Data(contentsOf: rig.cacheURL), as: UTF8.self)
        #expect(!cache.contains("CANARY-IN-MODEL") && !cache.contains("xxxxxxxx"))
        for text in Self.shown(s, issue: ledger.cacheIssue) + s.claude.models.map(\.model) {
            #expect(!text.contains("CANARY-IN-MODEL") && !text.contains("xxxxxxxx"), "\(text)")
        }
        // Nothing else from the record is kept.
        for c in Self.forbidden { #expect(!cache.contains(c), "\(c)") }
    }

    /// Every failure text a cache problem can show: fixed wording plus `strerror`, never a path.
    @Test func failureTextsNameNoPath() {
        let failures: [StorageFailure] = [.unsafeLocation, .notOwned, .permissions, .io(EACCES), .io(ENOENT), .io(EPERM)]
        for f in failures {
            for text in [LedgerCacheIssue.notSaved(f).text, LedgerCacheIssue.legacyNotRemoved(f).text,
                         LedgerClearFailure.cache(f).text, LedgerClearFailure.incomplete(f).text] {
                #expect(!text.contains("/") && !text.contains("Users") && !text.contains("claude-ledger"), "\(text)")
            }
        }
    }
}
