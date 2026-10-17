import Foundation

/// The app's identity on macOS (#11): its name, bundle id, Application Support folder and diagnostic log. The source
/// of truth is `Resources/identity.env`; `Info.plist`, `Package.swift`, `build.sh`, `scripts/install-app.sh` and
/// `scripts/runtime-verify.sh` follow it, and `IdentityTests` fails if any of them drifts.
enum AppIdentity {
    static let name = "SpanDeck"
    static let bundleID = "io.github.lolodawit.SpanDeck"
    static let supportFolder = "SpanDeck"
    static let hoverLog = "SpanDeck-hover.log"

    /// The app's own folder under the user's Application Support folder.
    static func applicationSupport(in base: URL) -> URL { base.appendingPathComponent(supportFolder, isDirectory: true) }

    /// The hover diagnostic log, written only with the hidden `debugHover` preference (audit 0007, P2).
    static func hoverLogURL(home: URL) -> URL { home.appendingPathComponent("Library/Logs").appendingPathComponent(hoverLog) }
}
