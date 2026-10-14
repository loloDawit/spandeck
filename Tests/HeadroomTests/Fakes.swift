import Foundation
@testable import Headroom

/// Records every request and answers from canned responses keyed by host. Unknown hosts fail as offline
/// and are recorded in `unexpected`, so a test can assert that nothing left the allowlist.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    struct Response { var status: Int; var body: Data }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _unexpected: [String] = []
    private let responses: [String: [Response]]
    private var served: [String: Int] = [:]

    /// `responses[host]` is served in order; the last one repeats. A host with no entry is unexpected.
    init(_ responses: [String: [Response]] = [:]) { self.responses = responses }

    var requests: [URLRequest] { lock.withLock { _requests } }
    var unexpected: [String] { lock.withLock { _unexpected } }
    var hosts: [String] { requests.compactMap { $0.url?.host } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let host = request.url?.host ?? ""
        let response: Response? = lock.withLock {
            _requests.append(request)
            guard let list = responses[host], !list.isEmpty else { _unexpected.append(host); return nil }
            let i = served[host, default: 0]
            served[host] = i + 1
            return list[min(i, list.count - 1)]
        }
        guard let response else { throw URLError(.notConnectedToInternet) }
        if response.status == FakeTransport.Response.timeout.status { throw URLError(.timedOut) }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }
}

/// Holds every request until the test answers it, to exercise results that arrive late.
/// Tests must `close()` it (e.g. in `defer`) so no request can stay suspended after the test ends.
final class DeferredTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = []
    private var _started = 0
    private var closed = false

    var started: Int { lock.withLock { _started } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { c in
            let rejected: Bool = lock.withLock {
                guard !closed else { return true }
                pending.append((request, c))
                _started += 1
                return false
            }
            if rejected { c.resume(throwing: URLError(.cancelled)) }
        }
    }

    /// Fails every pending request and every later one, so nothing waits on a response that will never come.
    func close() {
        let waiting: [(URLRequest, CheckedContinuation<(Data, URLResponse), Error>)] = lock.withLock {
            closed = true
            defer { pending = [] }
            return pending
        }
        waiting.forEach { $0.1.resume(throwing: URLError(.cancelled)) }
    }

    /// Waits for `count` requests to start. On timeout, closes the transport so `task` can't hang,
    /// waits for `task` to finish, and returns false.
    func awaitRequests<T>(_ count: Int, from task: Task<T, Never>, timeout: TimeInterval = 2) async -> Bool {
        if await waitForRequests(count, timeout: timeout) { return true }
        close()
        _ = await task.value
        return false
    }

    /// Waits until `count` requests have been started; false if that doesn't happen within `timeout`.
    func waitForRequests(_ count: Int, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while started < count {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    /// Waits for `task` to finish. If it is still running after `timeout` (for example it sent a request nobody will
    /// answer), closes the transport so it can finish, and returns false. Never waits unboundedly.
    func join<T>(_ task: Task<T, Never>, timeout: TimeInterval = 2) async -> Bool {
        let finished = Flag()
        let watchdog = Task { [weak self] () -> Bool in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !finished.isSet else { return false }
            self?.close()
            return true
        }
        _ = await task.value
        finished.set()
        watchdog.cancel()
        return !(await watchdog.value)
    }

    /// Answers the oldest pending request, or the newest with `newest`. Returns false (instead of crashing the test
    /// process) if none is pending, e.g. after `join` closed the transport.
    @discardableResult
    func respond(_ response: FakeTransport.Response, newest: Bool = false) -> Bool {
        guard let (request, c) = lock.withLock({ pending.isEmpty ? nil : newest ? pending.removeLast() : pending.removeFirst() })
        else { return false }
        c.resume(returning: (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status,
                                                            httpVersion: nil, headerFields: nil)!))
        return true
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Records calls; never executes anything. With `pausing`, the first call blocks (off the main actor) until
/// `resume()` or a 2 s timeout, so a test can change settings while `grok models` is "running".
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(path: String, args: [String])] = []
    private let gate: DispatchSemaphore?
    private let entered = Flag()
    var result: (status: Int32, output: Data)? = (0, Data())

    init(pausing: Bool = false) { gate = pausing ? DispatchSemaphore(value: 0) : nil }

    var calls: [(path: String, args: [String])] { lock.withLock { _calls } }

    func run(_ path: String, _ args: [String], timeout: TimeInterval, captureOutput: Bool) -> (status: Int32, output: Data)? {
        let first: Bool = lock.withLock { _calls.append((path, args)); return _calls.count == 1 }
        if first, let gate {
            entered.set()
            _ = gate.wait(timeout: .now() + 2)
        }
        return result
    }

    /// Waits until the first call has started; false after `timeout`.
    func waitUntilRunning(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !entered.isSet {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    func resume() { gate?.signal() }
}

final class FakeCredentialStore: CredentialStore {
    var json: Data?
    private(set) var reads = 0
    init(_ json: Data?) { self.json = json }
    func claudeCredentialJSON() -> Data? { reads += 1; return json }

    /// Synthetic Claude Code credential blob; the token is a canary, never a real secret.
    static func synthetic(expiresIn: TimeInterval = 3600) -> Data {
        let ms = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return Data(#"{"claudeAiOauth":{"accessToken":"CANARY-NOT-A-TOKEN","expiresAt":\#(ms),"subscriptionType":"pro"}}"#.utf8)
    }
}

/// In-memory preferences; never touches a real defaults domain.
final class InMemoryPreferences: PreferenceStore {
    private var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
    func object(forKey key: String) -> Any? { values[key] }
}

/// Reads the sandbox's `~/.grok/auth.json` like the real source, and counts every read.
final class CountingGrokAuth: GrokCredentialSource, @unchecked Sendable {
    private let file: GrokAuthFile
    private let lock = NSLock()
    private var _reads = 0
    init(home: URL) { file = GrokAuthFile(home: home) }
    var reads: Int { lock.withLock { _reads } }
    func grokAuthJSON() -> Data? {
        lock.withLock { _reads += 1 }
        return file.grokAuthJSON()
    }
}

/// Like `CountingGrokAuth`, but the first read blocks (off the main actor) until `resume()` or a 2 s timeout,
/// so a test can change consent while the key is being read.
final class PausingGrokAuth: GrokCredentialSource, @unchecked Sendable {
    private let file: GrokAuthFile
    private let gate = DispatchSemaphore(value: 0)
    private let entered = Flag()
    private let lock = NSLock()
    private var _reads = 0
    init(home: URL) { file = GrokAuthFile(home: home) }
    var reads: Int { lock.withLock { _reads } }

    func grokAuthJSON() -> Data? {
        let first: Bool = lock.withLock { _reads += 1; return _reads == 1 }
        if first {
            entered.set()
            _ = gate.wait(timeout: .now() + 2)
        }
        return file.grokAuthJSON()
    }

    /// Waits until the first read has started; false after `timeout`.
    func waitUntilReading(timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !entered.isSet {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return true
    }

    func resume() { gate.signal() }
}

final class FakeLoginItem: LoginItemService {
    private(set) var registers = 0
    private(set) var unregisters = 0
    private(set) var isEnabled: Bool
    init(enabled: Bool = false) { isEnabled = enabled }
    func register() throws { registers += 1; isEnabled = true }
    func unregister() throws { unregisters += 1; isEnabled = false }
}

/// A throwaway home and Application Support under a temp directory (removed on deinit), plus in-memory preferences.
final class Sandbox {
    let root: URL
    let home: URL
    let appSupport: URL
    let preferences = InMemoryPreferences()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("spandeck-tests-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        appSupport = root.appendingPathComponent("appsupport")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func environment(transport: HTTPTransport, runner: FakeProcessRunner = FakeProcessRunner(),
                     credentials: FakeCredentialStore = FakeCredentialStore(nil),
                     grokCredentials: GrokCredentialSource? = nil,
                     loginItem: FakeLoginItem = FakeLoginItem()) -> AppEnvironment {
        AppEnvironment(providerTransport: transport, pricingTransport: transport, processRunner: runner,
                       credentials: credentials, grokCredentials: grokCredentials ?? CountingGrokAuth(home: home),
                       loginItem: loginItem, preferences: preferences, home: home, appSupport: appSupport)
    }

    /// A synthetic Grok CLI install: auth.json with a canary key, an executable `bin/grok` that is never run,
    /// and one local session usage file (150 tokens, $0.25) dated now.
    @discardableResult
    func installGrok(expiresIn: TimeInterval? = nil) throws -> URL {
        let expiry = expiresIn.map { #","expires_at":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval($0)))""# } ?? ""
        try write(".grok/auth.json", #"{"default":{"key":"CANARY-GROK-KEY"\#(expiry)}}"#)
        let ended = ISO8601DateFormatter().string(from: Date())
        try write(".grok/sessions/proj/s1/usage.json", #"{"turns":[{"endedAt":"\#(ended)","inputTokens":100,"outputTokens":50,"#
                  + #""cachedReadTokens":0,"cacheCreationTokens":0,"modelCalls":1,"costUsdTicks":2500000000,"totalTokens":150,"#
                  + #""primaryModelId":"grok-test"}]}"#)
        return try write(".grok/bin/grok", "#!/bin/sh\nexit 1\n", executable: true)
    }

    /// Path → contents of every file under `~/.grok`, to prove nothing was changed or removed.
    func grokFiles() throws -> [String: Data] {
        let root = home.appendingPathComponent(".grok")
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: Data] = [:]
        for case let url as URL in en where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            out[url.path] = try Data(contentsOf: url)
        }
        return out
    }

    /// Writes `contents` to a path relative to the sandbox home, creating folders.
    @discardableResult
    func write(_ relative: String, _ contents: String, executable: Bool = false) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    /// One synthetic Claude Code assistant line with usage, timestamped now, with `canary` in the message body.
    static func transcriptLine(model: String, id: String, canary: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
        return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"req_\#(id)","message":{"id":"msg_\#(id)","model":"\#(model)","content":[{"type":"text","text":"\#(canary)"}],"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}"#
    }
}

enum Hosts {
    static let anthropic = "api.anthropic.com"
    static let grok = "cli-chat-proxy.grok.com"
    static let pricing = "raw.githubusercontent.com"
}

extension FakeTransport.Response {
    static func json(_ s: String, status: Int = 200) -> Self { .init(status: status, body: Data(s.utf8)) }
    static let claudeUsage = json(#"{"limits":[{"kind":"session","percent":42,"resets_at":"2030-01-01T00:00:00Z"}]}"#)
    static let pricingTable = json(#"{"claude-test-1":{"input_cost_per_token":0.000001,"output_cost_per_token":0.000002}}"#)
    static let unauthorized = json("{}", status: 401)
    static let grokBilling = json(#"{"config":{"creditUsagePercent":10}}"#)
    /// Not an HTTP answer: the transport throws `URLError(.timedOut)`.
    static let timeout = Self(status: -1, body: Data())
}

/// Runs one ledger refresh and returns its summaries.
func refreshLedger(_ ledger: Ledger) async -> (claude: UsageSummary, grok: UsageSummary) {
    await withCheckedContinuation { c in
        ledger.refresh(windowStart: nil, progress: { _ in }, completion: { claude, grok, _ in c.resume(returning: (claude, grok)) })
    }
}

/// Returns the given answers in order, then repeats the last.
final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> Bool { lock.withLock { values.count > 1 ? values.removeFirst() : values[0] } }
}
