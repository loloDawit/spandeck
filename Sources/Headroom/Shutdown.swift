import Foundation

/// Quitting without holding the main thread (#86). `applicationShouldTerminate` answers `.terminateLater` and calls
/// `begin`. That asks the ledger to stop at its next checkpoint and save on its own queue (`Ledger.requestStop`), while
/// AppKit keeps the event loop running. The coordinator replies exactly once: with the ledger's result, or `.timedOut`
/// after `timeout`, whichever comes first. A result that arrives after the reply changes nothing.
///
/// After a timeout the process may exit while the ledger is still scanning or saving. That is safe: the cache is only
/// replaced by rename(2) after a new one is written and fsync'd, so the previous cache stays valid, and leftover
/// temporary files are removed at the next launch. What was counted since the last save is read again from the
/// transcripts. (fsync(2) doesn't flush the drive's own cache: after a power loss right after a save, the cache can be
/// damaged; it is then discarded at launch and rebuilt from the transcripts, never misread.)
@MainActor
final class ShutdownCoordinator {
    enum Outcome: Equatable, Sendable { case saved, nothingToSave, failed, timedOut }

    /// Owner decision on #86 (2026-10-18).
    nonisolated static let defaultTimeout: TimeInterval = 5

    /// The reply given, once given.
    private(set) var outcome: Outcome?
    private var replies: [(Outcome) -> Void] = []
    private var begun = false
    private let timeout: TimeInterval
    private let stop: (@escaping @Sendable (LedgerStopResult) -> Void) -> Void
    private let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    /// `stop` starts the ledger's stop and calls its argument when done, on any thread. `after` runs a closure on the
    /// main actor after a delay; tests replace it.
    init(timeout: TimeInterval = ShutdownCoordinator.defaultTimeout,
         stop: @escaping (@escaping @Sendable (LedgerStopResult) -> Void) -> Void,
         after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = ShutdownCoordinator.mainAfter) {
        self.timeout = timeout
        self.stop = stop
        self.after = after
    }

    nonisolated static func mainAfter(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(body) }
    }

    /// Starts quitting. Returns at once; `reply` is called later, once, on the main actor. A request while a quit is
    /// under way starts nothing new (false) and gets the same outcome; a request after the outcome gets it at once.
    @discardableResult
    func begin(reply: @escaping (Outcome) -> Void) -> Bool {
        if let outcome {
            reply(outcome)
            return false
        }
        replies.append(reply)
        guard !begun else { return false }
        begun = true
        after(timeout) { [weak self] in self?.finish(.timedOut) }
        stop { [weak self] result in
            let outcome: Outcome
            switch result {
            case .saved: outcome = .saved
            case .nothingToSave: outcome = .nothingToSave
            case .failed: outcome = .failed
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(outcome) } }
        }
        return true
    }

    /// The first call replies to every request so far; later ones (a late ledger result, the timer after a result) do
    /// nothing.
    private func finish(_ o: Outcome) {
        guard outcome == nil else { return }
        outcome = o
        let waiting = replies
        replies = []
        waiting.forEach { $0(o) }
    }
}
