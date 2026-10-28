import Foundation

/// Live tracing for the swipe gesture, off unless asked for.
///
/// The gesture is decided from trackpad events that differ between machines —
/// how much travel one swipe carries, whether a coast follows, how much of a
/// diagonal a "horizontal" swipe really is. None of that can be reproduced
/// from a synthetic event stream, so when the swipe misbehaves on a particular
/// Mac this is how it gets read off that Mac instead of guessed at.
///
/// Enable:   defaults write com.johnteam.MedNotes SwipeDiagnostics -bool YES
///           (then relaunch — the flag is read once, on first use)
/// Disable:  defaults delete com.johnteam.MedNotes SwipeDiagnostics
///
/// The app is sandboxed, so both the switch and the log have to live somewhere
/// it is actually allowed to reach: a defaults key rather than a file in
/// `/tmp`, and the container's own temporary directory rather than the
/// system's. `logPath` is printed to the console on the first line written, so
/// the file can be found without knowing the container layout.
enum SwipeDiagnostics {
    /// Never in the XCTest host: it is this app, in the same container, and
    /// would log the tester's scrolling over its windows into the app's file.
    static let isEnabled = !AppSession.isTestHost
        && UserDefaults.standard.bool(forKey: "SwipeDiagnostics")

    /// Inside the sandbox this resolves to
    /// ~/Library/Containers/<bundle-id>/Data/tmp/mednotes-swipe.log
    static let logPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("mednotes-swipe.log").path

    /// Removes the diagnostics file. Called on lock and on exit; the file
    /// carries only gesture geometry, but it is still plaintext on disk.
    static func purge() {
        // On the writer's queue, so a line queued before the purge cannot recreate the file after it.
        queue.sync { try? FileManager.default.removeItem(atPath: logPath) }
    }

    private static let queue = DispatchQueue(label: "swipe-diagnostics")
    private static var gesture = 0
    private static var announced = false

    /// Every scroll event the controller is handed, capped per gesture so a
    /// long scroll cannot flood the file. This is the ground truth for "did
    /// the app even see the gesture".
    static func event(phase: UInt, momentum: UInt, dx: CGFloat, dy: CGFloat) {
        guard isEnabled else { return }
        seen += 1
        guard seen <= 40 else { return }
        func name(_ p: UInt, momentum: Bool) -> String {
            if p == 0 { return "-" }
            var parts: [String] = []
            if p & 1 != 0 { parts.append(momentum ? "mBegan" : "began") }
            if p & 2 != 0 { parts.append("stationary") }
            if p & 4 != 0 { parts.append(momentum ? "mChanged" : "changed") }
            if p & 8 != 0 { parts.append(momentum ? "mEnded" : "ended") }
            if p & 16 != 0 { parts.append("cancelled") }
            if p & 32 != 0 { parts.append("mayBegin") }
            return parts.joined(separator: "+")
        }
        write(String(format: "      ev %-10@ %-9@ dx%+7.1f dy%+7.1f",
                     name(phase, momentum: false) as NSString,
                     momentum == 0 ? "" : name(momentum, momentum: true) as NSString,
                     dx, dy))
    }

    private static var seen = 0

    static func began() {
        guard isEnabled else { return }
        gesture += 1
        seen = 0
        write("\n[\(gesture)] gesture began")
    }

    static func axisLocked(horizontal: Bool, travelX: CGFloat, travelY: CGFloat, row: Bool) {
        guard isEnabled else { return }
        write(String(format: "[%d] axis %@  (x %+.0f, y %+.0f)  row under pointer: %@%@",
                     gesture,
                     horizontal ? "HORIZONTAL" : "VERTICAL",
                     travelX, travelY,
                     row ? "yes" : "NO",
                     horizontal && !row
                        ? "   <- swipe ignored: pointer is not over a row"
                        : (horizontal ? "" : "   <- swipe treated as a scroll")))
    }

    static func settled(outcome: String, translation: CGFloat,
                        travelX: CGFloat, velocity: CGFloat) {
        guard isEnabled else { return }
        write(String(format: "[%d] released -> %@  (travel %+.0f, reveal %+.0f, velocity %+.0f pt/s)",
                     gesture, outcome, travelX, translation, velocity))
    }

    private static func write(_ line: String) {
        queue.async {
            if !announced {
                announced = true
                NSLog("SwipeDiagnostics logging to %@", logPath)
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }
}
