import Foundation

/// Numbers the loads of a detail view so a load that was superseded can tell.
///
/// A detail view starts a load whenever the selection or the store changes,
/// and the earlier one is cancelled. A cancelled load still runs to its end,
/// and if it then cleared the spinner it would uncover the previous record's
/// editor under the new selection, with typing going into the wrong record.
/// Only the newest load may clear it.
struct LoadGeneration: Equatable {
    private var latest = 0

    /// Starts a load and returns its number.
    mutating func begin() -> Int {
        latest &+= 1
        return latest
    }

    /// Whether no load has started since `generation` did.
    func isCurrent(_ generation: Int) -> Bool {
        generation == latest
    }
}
