import Foundation
import Testing
@testable import Headroom

/// #11: SpanDeck has its own macOS identity, separate from upstream Headroom's: bundle id (and with it the preferences
/// domain and login-item record), app and executable name, Application Support folder and diagnostic log. One source
/// (`Resources/identity.env`) and no drift; no source or install script names Headroom's state. The Swift module and
/// target stay `Headroom` internally.
struct IdentityTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func env() throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try text("Resources/identity.env").split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    @Test func identityIsSpanDeck() throws {
        let e = try Self.env()
        #expect(e == ["APP_NAME": "SpanDeck", "BUNDLE_ID": "io.github.lolodawit.SpanDeck", "APP_SUPPORT_DIR": "SpanDeck",
                      "HOVER_LOG": "SpanDeck-hover.log"])
    }

    /// Swift, Info.plist and the SwiftPM product all say what identity.env says.
    @Test func sourcesAgree() throws {
        let e = try Self.env()
        #expect(AppIdentity.name == e["APP_NAME"] && AppIdentity.bundleID == e["BUNDLE_ID"]
                && AppIdentity.supportFolder == e["APP_SUPPORT_DIR"] && AppIdentity.hoverLog == e["HOVER_LOG"])
        let plist = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == e["BUNDLE_ID"])
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
            #expect(plist[key] as? String == e["APP_NAME"], "\(key)")
        }
        // The executable product carries the app's name (so the debug binary and its processes do too); the module
        // stays Headroom.
        let package = try Self.text("Package.swift")
        #expect(package.contains(#".executable(name: "\#(e["APP_NAME"] ?? "")", targets: ["Headroom"])"#))
    }

    @Test func storageIsSpanDecksOwn() {
        let base = URL(fileURLWithPath: "/tmp/x/Library/Application Support", isDirectory: true)
        #expect(AppIdentity.applicationSupport(in: base).path == "/tmp/x/Library/Application Support/SpanDeck")
        #expect(AppIdentity.hoverLogURL(home: URL(fileURLWithPath: "/tmp/x")).path == "/tmp/x/Library/Logs/SpanDeck-hover.log")
    }

    /// Headroom's bundle id, folder, log and app are named nowhere in the app's sources, so SpanDeck can't read,
    /// write or delete them. The module name, the `Sources/Headroom` folder and the upstream credit stay.
    @Test func sourcesNeverNameHeadroomState() throws {
        let dir = Self.root.appendingPathComponent("Sources/Headroom")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let s = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for legacy in ["dev.headroom", "Headroom-hover", "Application Support/Headroom", "Headroom.app", #""Headroom""#] {
                #expect(!s.contains(legacy), "\(name): \(legacy)")
            }
        }
    }

    /// Building and installing never quit, remove or replace Headroom: names come from identity.env, and the install
    /// script refuses a target that isn't SpanDeck's (exercised by scripts/test-install.sh).
    @Test func scriptsNeverTouchHeadroom() throws {
        for path in ["build.sh", "scripts/install-app.sh"] {
            let s = try Self.text(path)
            #expect(s.contains("identity.env"), "\(path) reads identity.env")
            for legacy in ["Headroom.app", "pkill -x Headroom", "dev.headroom", "Headroom-$VERSION", "\"Headroom "] {
                #expect(!s.contains(legacy), "\(path): \(legacy)")
            }
        }
        #expect(!(try Self.text("build.sh")).contains("pkill"), "only install-app.sh quits a running app")
        let release = try Self.text(".github/workflows/release.yml")
        #expect(!release.contains("Headroom-") && !release.contains("\"Headroom "), "release names")
        let rv = try Self.text("scripts/runtime-verify.sh")
        #expect(rv.contains("identity.env"))
    }

    /// Checks run before anything destructive (review of e39f9c5): build.sh validates the identity (Info.plist and
    /// every AppIdentity constant) before compiling or packaging, and install-app.sh refuses an overlapping source and
    /// target before quitting or removing anything. scripts/test-identity-check.sh and scripts/test-install.sh exercise
    /// the failure paths.
    @Test func checksComeBeforeDestructiveSteps() throws {
        let build = try Self.text("build.sh")
        let check = try #require(build.range(of: "scripts/check-identity.sh"))
        let compile = try #require(build.range(of: "swift build"))
        #expect(check.lowerBound < compile.lowerBound)
        let install = try Self.text("scripts/install-app.sh")
        let overlap = try #require(install.range(of: "overlap"))
        let kill = try #require(install.range(of: "pkill"))
        let remove = try #require(install.range(of: "rm -rf"))
        #expect(overlap.lowerBound < kill.lowerBound && kill.lowerBound < remove.lowerBound)
    }
}
