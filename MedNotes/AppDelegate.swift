import AppKit

/// Holds quitting until the open editors' drafts are saved.
///
/// Notes have no autosave: a draft is saved by Save, by switching records, or by
/// the editor's own save as it goes away, and that last one is a task that a
/// quit does not wait for. `applicationShouldTerminate` is the one place that
/// can, so it asks the session to lock, which saves the drafts and closes the
/// store, and replies once that is done.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the main window as it appears. Weak: the app owns the session.
    weak var session: AppSession?

    /// How long a quit waits. A write that hangs must never keep the Mac from
    /// logging out or shutting down.
    static let quitTimeout: Duration = .seconds(10)

    /// Numbers the quit attempts, so a task left over from one that something
    /// else vetoed cannot answer a later one.
    private var attempt = 0
    private var hasReplied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        // A quit that something else vetoed (a logout another app refused)
        // never got its reply; this attempt starts clean.
        attempt += 1
        hasReplied = false
        let mine = attempt
        Task { @MainActor [weak self] in
            await session.closeForQuit()
            self?.replyToTermination(attempt: mine)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.quitTimeout)
            self?.replyToTermination(attempt: mine)
        }
        return .terminateLater
    }

    /// Answers the pending quit once, whichever of the two tasks gets here first.
    private func replyToTermination(attempt mine: Int) {
        guard mine == attempt, !hasReplied else { return }
        hasReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
