import Foundation
import Testing
@testable import Headroom

/// R6: prices come from a reviewed LiteLLM snapshot built into the app. Nothing is downloaded at launch or because
/// data is old; the one explicit download fetches only the pinned revision, verifies its SHA-256 before parsing, and
/// never replaces working prices with anything unverified. Upstream files here are synthetic, with pins computed from
/// their own bytes; the real snapshot is checked only as built in.
@MainActor
struct PricingTests {
    nonisolated private static let revisionA = String(repeating: "a", count: 40)
    nonisolated private static let revisionB = String(repeating: "b", count: 40)

    /// A small upstream-shaped file: one Claude entry, one non-Claude entry, one Claude entry without prices.
    nonisolated private static func upstream(input: Double = 2e-6, output: Double = 4e-6) -> Data {
        Data(#"{"claude-synth-1":{"input_cost_per_token":\#(input),"output_cost_per_token":\#(output),"cache_read_input_token_cost":2e-7},"gpt-x":{"input_cost_per_token":1},"claude-no-price":{"max_tokens":10}}"#.utf8)
    }

    nonisolated private static func pin(for data: Data, revision: String = revisionB) -> PricingPin {
        PricingPin(revision: revision, sourceSHA256: Pricing.sha256(data))
    }

    /// A built-in table for `claude-synth-1` at 1e-6 / 2e-6, with a correct checksum unless `checksum` is given.
    nonisolated private static func bundle(_ json: String = #"{"claude-synth-1":{"input":1e-06,"output":2e-06,"cacheWrite":1.25e-06,"cacheWrite1h":2e-06,"cacheRead":1e-07}}"#,
                               revision: String = revisionA, checksum: String? = nil) -> PricingBundle {
        PricingBundle(revision: revision, sourceSHA256: String(repeating: "0", count: 64), retrieved: "2026-01-01T00:00:00Z",
                      tableSHA256: checksum ?? Pricing.sha256(Data(json.utf8)), tableJSON: json)
    }

    nonisolated private static let oneOfEach = Agg(input: 100, output: 50, cacheWrite5m: 10, cacheWrite1h: 4, cacheRead: 1000)

    private struct Rig {
        let box: Sandbox
        let transport: HTTPTransport
        let pricing: Pricing
        init(transport: HTTPTransport = FakeTransport(), pin: PricingPin, bundle: PricingBundle = PricingTests.bundle()) throws {
            box = try Sandbox()
            self.transport = transport
            pricing = Pricing(directory: box.appSupport, transport: transport, pin: pin, bundle: bundle,
                              now: { Date(timeIntervalSince1970: 1_800_000_000) })
        }
        var installed: URL { box.appSupport.appendingPathComponent("pricing-source.json") }
        func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: box.appSupport.path).sorted() }
    }

    // MARK: Built-in snapshot

    @Test func realSnapshotIsPinnedAndVerifies() throws {
        let pin = PricingSnapshot.pin
        #expect(pin.revision.count == 40 && pin.revision.allSatisfy { $0.isHexDigit })
        #expect(pin.sourceSHA256.count == 64 && pin.sourceSHA256.allSatisfy { $0.isHexDigit })
        #expect(pin.url.absoluteString == "https://raw.githubusercontent.com/BerriAI/litellm/\(pin.revision)/model_prices_and_context_window.json")
        #expect(!pin.url.absoluteString.contains("/main/"))
        #expect(Pricing.sha256(Data(PricingSnapshot.bundled.tableJSON.utf8)) == PricingSnapshot.bundled.tableSHA256)
        #expect(PricingSnapshot.license.contains("MIT") && PricingSnapshot.license.contains("Berri AI"))

        let transport = FakeTransport()
        let box = try Sandbox()
        let pricing = Pricing(directory: box.appSupport, transport: transport)
        let info = pricing.load()

        #expect(info == PricingInfo(source: .bundled, revision: pin.revision, retrieved: PricingSnapshot.retrieved))
        let written = try FileManager.default.contentsOfDirectory(atPath: box.appSupport.path)
        #expect(transport.requests.isEmpty && written.isEmpty)
        // Model id with a date suffix resolves to the base entry; every price dimension is used.
        let opus = try #require(pricing.cost(model: "claude-opus-4-8-20261001", Self.oneOfEach))
        let expected = 100 * 5e-6 + 50 * 2.5e-5 + 10 * 6.25e-6 + 4 * 1e-5 + 1000 * 5e-7
        #expect(abs(opus - expected) < 1e-15)
        #expect(pricing.cost(model: "claude-haiku-4-5-20251001", Self.oneOfEach) != nil)
    }

    @Test(arguments: [
        ("damaged text", #"{"claude-synth-1":{"input":9e-06,"output":2e-06,"cacheWrite":1.25e-06,"cacheWrite1h":2e-06,"cacheRead":1e-07}}"#, true),
        ("empty table", "{}", false),
        ("not a table", "[]", false),
        ("negative price", #"{"claude-synth-1":{"input":-1e-06,"output":2e-06,"cacheWrite":0,"cacheWrite1h":0,"cacheRead":0}}"#, false),
        ("absurd price", #"{"claude-synth-1":{"input":5,"output":2e-06,"cacheWrite":0,"cacheWrite1h":0,"cacheRead":0}}"#, false),
        ("missing field", #"{"claude-synth-1":{"input":1e-06}}"#, false),
    ])
    func unusableBundleMeansNoPrices(_ name: String, _ json: String, _ wrongChecksum: Bool) throws {
        let checksum = wrongChecksum ? Self.bundle().tableSHA256 : nil
        let rig = try Rig(pin: Self.pin(for: Self.upstream()), bundle: Self.bundle(json, checksum: checksum))

        #expect(rig.pricing.load() == .unavailable, "\(name)")
        #expect(rig.pricing.cost(model: "claude-synth-1", Self.oneOfEach) == nil)
    }

    // MARK: No silent network access; legacy cache

    /// A legacy `pricing.json` from the old unpinned download, however old or odd, is neither used nor touched, and
    /// its age triggers nothing.
    @Test func legacyCacheIgnoredAndLeftInPlace() throws {
        let transport = FakeTransport([Hosts.pricing: [.json("{}")]])
        let rig = try Rig(transport: transport, pin: Self.pin(for: Self.upstream()))
        let legacy = try rig.box.write("../appsupport/pricing.json",
                                       #"{"claude-synth-1":{"input":0.5,"output":0.5,"cacheWrite":0.5,"cacheWrite1h":0.5,"cacheRead":0.5}}"#)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -30 * 86400)], ofItemAtPath: legacy.path)
        let before = try Data(contentsOf: legacy)

        let info = rig.pricing.load()

        #expect(info.source == .bundled && transport.requests.isEmpty)
        #expect(abs(try #require(rig.pricing.cost(model: "claude-synth-1", Agg(input: 100))) - 1e-4) < 1e-15)
        let after = try Data(contentsOf: legacy)
        let files = try rig.files()
        #expect(after == before && files == ["pricing.json"])
    }

    // MARK: Explicit download
    //
    // `FakeTransport` answers at once, so awaiting `update()` directly can't hang. Tests on `DeferredTransport` wait
    // only through bounded helpers (`awaitRequests`, `join`).

    @Test func downloadFetchesOnlyThePinnedRevision() async throws {
        let data = Self.upstream()
        let pin = Self.pin(for: data)
        let transport = FakeTransport([Hosts.pricing: [.init(status: 200, body: data)]])
        let rig = try Rig(transport: transport, pin: pin)
        rig.pricing.load()
        let before = rig.pricing.generation

        let result = await rig.pricing.update()

        let info = try result.get()
        #expect(info.source == .downloaded && info.revision == Self.revisionB && info.retrieved == "2027-01-15T08:00:00Z")
        #expect(transport.requests.map(\.url) == [pin.url])
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET" && request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData && request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(rig.pricing.info == info && rig.pricing.generation > before)
        // Extracted with the snapshot rules: missing cache-write prices default to 1.25x / 2x input.
        let cost = try #require(rig.pricing.cost(model: "claude-synth-1", Self.oneOfEach))
        #expect(abs(cost - (100 * 2e-6 + 50 * 4e-6 + 10 * 2.5e-6 + 4 * 4e-6 + 1000 * 2e-7)) < 1e-15)
        #expect(rig.pricing.cost(model: "gpt-x", Agg(input: 1)) == nil)

        // Relaunch: the verified download of the pinned revision is used, offline.
        let relaunch = Pricing(directory: rig.box.appSupport, transport: FakeTransport(), pin: pin, bundle: Self.bundle())
        #expect(relaunch.load() == info)
    }

    /// Every failure leaves the prices in use, and anything on disk, exactly as they were.
    @Test(arguments: [
        (FakeTransport.Response.init(status: 200, body: Data("tampered".utf8) + PricingTests.upstream()), PricingUpdateError.checksumMismatch),
        (.init(status: 200, body: PricingTests.upstream(input: 3e-6)), .checksumMismatch),
        (.json("{}", status: 404), .http(404)),
        (.json("{}", status: 500), .http(500)),
        (.timeout, .network),
    ])
    func failedDownloadKeepsWorkingPrices(_ response: FakeTransport.Response, _ expected: PricingUpdateError) async throws {
        let transport = FakeTransport([Hosts.pricing: [response]])
        let rig = try Rig(transport: transport, pin: Self.pin(for: Self.upstream()))
        let working = rig.pricing.load()
        let generation = rig.pricing.generation

        let result = await rig.pricing.update()

        #expect(result == .failure(expected))
        #expect(rig.pricing.info == working && rig.pricing.generation == generation)
        #expect(abs(try #require(rig.pricing.cost(model: "claude-synth-1", Agg(input: 100))) - 1e-4) < 1e-15)
        #expect(try rig.files().isEmpty)
    }

    /// A file that is exactly the pinned one but holds no valid Claude prices is rejected after the checksum passes.
    @Test(arguments: ["{}", "[]", "not json", #"{"gpt-x":{"input_cost_per_token":1,"output_cost_per_token":1}}"#,
                      #"{"claude-x":{"input_cost_per_token":-1,"output_cost_per_token":1e-6}}"#,
                      #"{"claude-x":{"input_cost_per_token":false,"output_cost_per_token":1e-6}}"#,
                      #"{"claude-x":{"input_cost_per_token":"1e-6","output_cost_per_token":1e-6}}"#,
                      #"{"claude-x":{"input_cost_per_token":0.5,"output_cost_per_token":1e-6}}"#,
                      // Input and output fine; only a cache price is out of range.
                      #"{"claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":1e-6,"cache_read_input_token_cost":-1}}"#,
                      #"{"claude-x":{"input_cost_per_token":1e-6,"output_cost_per_token":1e-6,"cache_creation_input_token_cost_above_1hr":0.01}}"#])
    func pinnedButInvalidIsRejected(_ body: String) async throws {
        let data = Data(body.utf8)
        let rig = try Rig(transport: FakeTransport([Hosts.pricing: [.init(status: 200, body: data)]]), pin: Self.pin(for: data))
        let working = rig.pricing.load()

        #expect(await rig.pricing.update() == .failure(.invalidData))
        let files = try rig.files()
        #expect(rig.pricing.info == working && files.isEmpty)
    }

    /// Prices already from the pinned revision: downloading the same file again would change nothing, so no request.
    @Test func noDownloadWhenAlreadyPinned() async throws {
        let transport = FakeTransport([Hosts.pricing: [.init(status: 200, body: Self.upstream())]])
        let rig = try Rig(transport: transport, pin: Self.pin(for: Self.upstream(), revision: Self.revisionA))
        rig.pricing.load()

        #expect(await rig.pricing.update() == .failure(.alreadyCurrent))
        #expect(transport.requests.isEmpty)
    }

    @Test func concurrentDownloadsDontOverlap() async throws {
        let data = Self.upstream()
        let transport = DeferredTransport()
        defer { transport.close() }
        let rig = try Rig(transport: transport, pin: Self.pin(for: data))
        rig.pricing.load()

        let first = Task { await rig.pricing.update() }
        guard await transport.awaitRequests(1, from: first) else { Issue.record("download never started"); return }
        // Bounded: if the second call sent its own request instead, `join` closes the transport after 1 s.
        let second = Task { await rig.pricing.update() }
        #expect(await transport.join(second, timeout: 1), "the second download sent its own request")
        #expect(await second.value == .failure(.inProgress))
        #expect(transport.respond(.init(status: 200, body: data)))
        let result = await first.value

        let info = try result.get()
        #expect(info.source == .downloaded && transport.started == 1)
        #expect(try rig.files() == ["pricing-source.json"])
        #expect(Pricing(directory: rig.box.appSupport, transport: FakeTransport(), pin: Self.pin(for: data),
                        bundle: Self.bundle()).load().source == .downloaded)
    }

    /// Saving fails (the target is a directory): nothing changes. A damaged or foreign saved snapshot is ignored.
    @Test func lastKnownGoodSurvivesWriteFailureAndDamage() async throws {
        let data = Self.upstream()
        let rig = try Rig(transport: FakeTransport([Hosts.pricing: [.init(status: 200, body: data)]]), pin: Self.pin(for: data))
        try FileManager.default.createDirectory(at: rig.installed.appendingPathComponent("blocker"), withIntermediateDirectories: true)
        let working = rig.pricing.load()

        #expect(await rig.pricing.update() == .failure(.writeFailed))
        #expect(rig.pricing.info == working)

        try FileManager.default.removeItem(at: rig.installed)
        // #28 review: a saved file is trusted only if its bytes still hash to the compiled pin. Altered prices that
        // stay in range, or metadata claiming the pin, don't make it trusted.
        let pinned = Self.pin(for: data)
        let altered = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #""input_cost_per_token":2e-06"#, with: #""input_cost_per_token":0.0005"#).utf8)
        #expect(altered != data && Pricing.table(fromSource: altered) != nil) // still a valid, in-range table
        let claimsPin = #"{"format":1,"revision":"\#(Self.revisionB)","sourceSHA256":"\#(pinned.sourceSHA256)","retrieved":"x","table":{"claude-synth-1":{"input":0.0005,"output":0.0005,"cacheWrite":0,"cacheWrite1h":0,"cacheRead":0}}}"#
        for damaged in [Data("{\"claude-synth-1\":".utf8), altered, Data(claimsPin.utf8), Data()] {
            try damaged.write(to: rig.installed)
            #expect(rig.pricing.load().source == .bundled, "\(String(decoding: damaged, as: UTF8.self))")
            #expect(abs(try #require(rig.pricing.cost(model: "claude-synth-1", Agg(input: 100))) - 1e-4) < 1e-15)
        }
        // The leftover envelope file from earlier builds of this PR is ignored too.
        try Data(claimsPin.utf8).write(to: rig.box.appSupport.appendingPathComponent("pricing-snapshot.json"))
        try FileManager.default.removeItem(at: rig.installed)
        #expect(rig.pricing.load().source == .bundled)
        // Control: the exact pinned bytes are accepted.
        try data.write(to: rig.installed)
        #expect(rig.pricing.load().source == .downloaded)
        #expect(abs(try #require(rig.pricing.cost(model: "claude-synth-1", Agg(input: 100))) - 2e-4) < 1e-15)
    }

    // MARK: Effect on usage

    /// New prices change cost estimates already shown, without new transcript data or a re-read.
    @Test func downloadedPricesUpdateEstimates() async throws {
        let data = Self.upstream()
        let rig = try Rig(transport: FakeTransport([Hosts.pricing: [.init(status: 200, body: data)]]), pin: Self.pin(for: data))
        try rig.box.write(".claude/projects/-Users-synthetic-proj/s1.jsonl",
                          Sandbox.transcriptLine(model: "claude-synth-1", id: "1", canary: "x") + "\n")
        rig.pricing.load()
        let ledger = Ledger(home: rig.box.home, appSupport: rig.box.appSupport, pricing: rig.pricing)

        let before = await refreshLedger(ledger).claude
        #expect(abs(before.today.cost - (100 * 1e-6 + 50 * 2e-6)) < 1e-15)
        _ = try await rig.pricing.update().get()
        let after = await refreshLedger(ledger).claude

        #expect(after.today.tokens == 150)
        #expect(abs(after.today.cost - (100 * 2e-6 + 50 * 4e-6)) < 1e-15)
    }

    /// The app's download action: with the built-in snapshot verified it sends nothing, and it never touches provider
    /// consent, credentials or quota state.
    @Test func appDownloadActionIsIndependentOfProviders() async throws {
        let box = try Sandbox()
        let transport = FakeTransport()
        let creds = FakeCredentialStore(FakeCredentialStore.synthetic())
        let services = ProviderServices(store: Store(), env: box.environment(transport: transport, credentials: creds))
        services.start()

        await services.updatePricing()

        #expect(services.store.pricingError == .alreadyCurrent && services.store.pricing.source == .bundled)
        #expect(!services.store.pricingUpdating && transport.requests.isEmpty && creds.reads == 0)
        #expect(!services.store.claudeLimitsEnabled && !services.store.grokEnabled)
        #expect(!box.preferences.bool(forKey: Prefs.claudeLimits) && !box.preferences.bool(forKey: Prefs.grokCredits))
    }

    // MARK: Copy

    @Test func copyCallsCostsEstimatesAndDisclosesTheDownload() {
        let bundled = PricingText.summary(PricingInfo(source: .bundled, revision: Self.revisionA, retrieved: "2026-10-15T02:39:52Z"))
        #expect(bundled.contains("estimates") && bundled.contains("not your Anthropic bill") && bundled.contains("aaaaaaa"))
        #expect(bundled.contains("2026-10-15") && bundled.contains("built in") && bundled.contains("$0"))
        #expect(PricingText.summary(.unavailable).contains("can't be estimated"))

        let disclosure = PricingText.downloadDisclosure
        for phrase in ["GitHub", "raw.githubusercontent.com", "transcripts", "SHA-256", "not trusted automatically",
                       String(PricingSnapshot.pin.revision.prefix(7))] {
            #expect(disclosure.contains(phrase), "\(phrase)")
        }
        #expect(PricingText.failure(.checksumMismatch).contains("unchanged"))
    }
}
