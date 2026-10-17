import Foundation
import Testing
@testable import Headroom

/// Audit 0007, P2 (#68): the hover debug log exists in debug builds only. `swift test` builds debug, so release builds
/// are checked here through the source (every part of the log path sits inside `#if DEBUG`) and, on built binaries,
/// by `scripts/check-hover-log-release.sh`, which `build.sh` runs on the packaged app.
/// Needles are assembled from fragments so this file contains none of `SeamBoundaryTests`' needles literally.
struct HoverDebugLogSourceTests {
    private static func needle(_ parts: String...) -> String { parts.joined() }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Headroom")

    /// A source file without its comment lines, which compile to nothing.
    private static func source(_ name: String) throws -> String {
        try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// Each line with whether it is compiled only when `DEBUG` is set. `#elseif` branches count as not debug-only.
    private static func debugOnlyLines(_ text: String) -> [(line: String, debugOnly: Bool)] {
        enum Branch { case debug, notDebug, other }
        var stack: [Branch] = []
        var out: [(String, Bool)] = []
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#if ") {
                stack.append(t == "#if DEBUG" ? .debug : .other)
            } else if t.hasPrefix("#elseif"), !stack.isEmpty {
                stack[stack.count - 1] = .other
            } else if t == "#else", let top = stack.last {
                stack[stack.count - 1] = top == .debug ? .notDebug : .other
            } else if t == "#endif" {
                stack.removeLast()
            } else {
                out.append((line, stack.contains(.debug)))
            }
        }
        return out
    }

    /// What reads the preference, finds the log path or touches files. Each must appear, and only inside `#if DEBUG`.
    static let logPath = [
        needle("debug", "Hover"), needle("hover", "LogURL"), needle("home", "Dir"), needle("User", "Defaults"),
        needle("open", "("), "HoverDebugLog",
    ]

    @Test(arguments: logPath)
    func logPathIsDebugOnly(_ token: String) throws {
        let lines = Self.debugOnlyLines(try Self.source("Hover.swift")).filter { $0.line.contains(token) }
        #expect(!lines.isEmpty, "\(token) not found in Hover.swift")
        #expect(lines.filter { !$0.debugOnly }.map(\.line) == [])
    }

    /// No other way to write a file is left in Hover.swift outside `#if DEBUG`.
    @Test(arguments: ["FileHandle", "write(to:", "createFile", "Darwin.write", ".write("])
    func noFileWritesOutsideDebug(_ token: String) throws {
        let lines = Self.debugOnlyLines(try Self.source("Hover.swift")).filter { $0.line.contains(token) }
        #expect(lines.filter { !$0.debugOnly }.map(\.line) == [])
    }

    /// In release builds `log(_:)` is an empty stub, so its message is never even built.
    @Test func releaseLogIsEmpty() throws {
        let release = Self.debugOnlyLines(try Self.source("Hover.swift")).filter { !$0.debugOnly }.map(\.line)
        let stubs = release.filter { $0.contains("func log(") }
        #expect(stubs.count == 1)
        #expect(stubs.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasSuffix("{}") })
    }

    /// Only Hover.swift has the log path. Identity.swift keeps `hoverLog` and `hoverLogURL` as identity constants for
    /// #11's checks (`check-identity.sh`, `IdentityTests`); they name the file and write nothing.
    @Test func logPathOnlyInHover() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.sources.path).filter { $0.hasSuffix(".swift") }
        for token in [Self.needle("debug", "Hover"), "HoverDebugLog"] {
            #expect(try names.filter { try Self.source($0).contains(token) } == ["Hover.swift"])
        }
        #expect(try Set(names.filter { try Self.source($0).contains(Self.needle("hover", "LogURL")) })
                == ["Hover.swift", "Identity.swift"])
    }

    /// The diagnostics are UI geometry and the hovered segment. Every value a `log(...)` call interpolates is one of
    /// these, so no transcript, credential, model or process data reaches the file.
    @Test func logMessagesOnlyHoldGeometry() throws {
        let allowed: Set<String> = ["mouse", "frame.contains(mouse)", "String(describing: current)", "kind",
                                    "panel.frame", "panel.isVisible"]
        let text = try Self.source("Hover.swift")
        let calls = text.components(separatedBy: "log(\"").dropFirst().map { $0.prefix { $0 != "\n" } }
        #expect(calls.count == 4)
        var seen: Set<String> = []
        for call in calls {
            for part in call.components(separatedBy: "\\(").dropFirst() {
                var depth = 0, value = ""
                for c in part {
                    if c == "(" { depth += 1 } else if c == ")" { if depth == 0 { break }; depth -= 1 }
                    value.append(c)
                }
                seen.insert(value)
            }
        }
        #expect(seen.isSubset(of: allowed), "unexpected values: \(seen.subtracting(allowed).sorted())")
    }
}

#if DEBUG
/// Debug builds: the log is off unless `debugHover` is set, and then appends to SpanDeck's own log only.
struct HoverDebugLogTests {
    private let box: Sandbox
    private let logs: URL
    private var path: URL { logs.appendingPathComponent("SpanDeck-hover.log") }

    init() throws {
        box = try Sandbox()
        logs = box.home.appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    private func log(_ enabled: Bool?) -> HoverDebugLog {
        if let enabled { box.preferences.set(enabled, forKey: HoverDebugLog.preference) }
        return HoverDebugLog(preferences: box.preferences, home: box.home)
    }

    private func contents() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: logs.path) }

    @Test func offByDefault() throws {
        let log = log(nil)
        var built = false
        log.write({ built = true; return "mouse" }())
        #expect(!log.isEnabled && !built)
        #expect(try contents().isEmpty)
    }

    @Test func onlyDebugHoverEnablesIt() {
        #expect(HoverDebugLog.preference == "debugHover")
        box.preferences.set(true, forKey: "debugHoverX")
        box.preferences.set(true, forKey: "show.cpu")
        #expect(!log(nil).isEnabled)
        #expect(log(true).isEnabled)
    }

    @Test func unsetWritesNothing() throws {
        log(false).write("show cpu")
        #expect(try contents().isEmpty)
    }

    @Test func setWritesToSpanDecksLogOnly() throws {
        let log = log(true)
        #expect(log.url == AppIdentity.hoverLogURL(home: box.home))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        log.write("show cpu", at: date)
        log.write("panel frame (0.0, 0.0, 240.0, 100.0) visible true", at: date)
        #expect(try contents() == ["SpanDeck-hover.log"])
        #expect(try String(contentsOf: path, encoding: .utf8)
                == "\(date) show cpu\n\(date) panel frame (0.0, 0.0, 240.0, 100.0) visible true\n")
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test func appendsWithoutTruncating() throws {
        try Data("earlier run\n".utf8).write(to: path)
        log(true).write("show gpu", at: Date(timeIntervalSince1970: 0))
        #expect(try String(contentsOf: path, encoding: .utf8) == "earlier run\n\(Date(timeIntervalSince1970: 0)) show gpu\n")
    }

    /// Headroom's log is never opened, and a link in place of SpanDeck's log isn't followed.
    @Test func otherFilesUntouched() throws {
        let legacy = logs.appendingPathComponent("Headroom-hover.log")
        try Data("legacy hover log\n".utf8).write(to: legacy)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: legacy)
        log(true).write("show memory")
        #expect(try String(contentsOf: legacy, encoding: .utf8) == "legacy hover log\n")
        #expect(try Set(contents()) == ["Headroom-hover.log", "SpanDeck-hover.log"])
    }

    /// A missing Logs folder isn't created; the write is dropped.
    @Test func missingFolderIsNotCreated() throws {
        try FileManager.default.removeItem(at: logs)
        log(true).write("show battery")
        #expect(!FileManager.default.fileExists(atPath: logs.path))
    }
}
#endif
