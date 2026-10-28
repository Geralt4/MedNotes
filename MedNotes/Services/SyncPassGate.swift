import Foundation

/// Lets one sync pass run at a time per bridge.
///
/// Passes start from the Sync Now button, from EventKit's change
/// notifications (including the ones a pass's own writes cause) and, for a
/// quiet push, from a save. Two running together each push from a snapshot
/// the other is changing. A request that arrives while a pass runs is not
/// lost: it makes the running pass go round once more when it ends.
struct SyncPassGate: Equatable {
    private(set) var isRunning = false
    private var rerunRequested = false
    private var rerunWantsManual = false

    /// Whether the caller may start a pass now. When one is running this
    /// returns false and records that another is wanted, as a manual one if
    /// any request for it was manual (a manual pass may open the wizard).
    mutating func enter(automatic: Bool) -> Bool {
        if isRunning {
            rerunRequested = true
            if !automatic { rerunWantsManual = true }
            return false
        }
        isRunning = true
        return true
    }

    /// Called when a pass ends. Nil when the gate is idle again; otherwise
    /// whether the one further pass requested meanwhile is automatic.
    mutating func finish() -> Bool? {
        guard rerunRequested else {
            isRunning = false
            return nil
        }
        let automatic = !rerunWantsManual
        rerunRequested = false
        rerunWantsManual = false
        return automatic
    }
}
