import Foundation

/// Whether this process was launched to run against the throwaway preview data
/// root instead of the user's real store.
///
/// Release builds hardcode `false`. The flag is a development affordance for
/// reviewing the UI against realistic content, and a shipped binary must have
/// no path at all — argument, defaults key or otherwise — that points it at
/// sample data, in an app whose real store will hold patient records.
enum PreviewSeed {
    /// Keeps whatever the previous seeded run left behind, so "quit, relaunch,
    /// my edit survived" stays reviewable.
    static let flag = "--preview-seed"
    /// Discards the previous run's edits and re-seeds from scratch.
    static let freshFlag = "--preview-seed=fresh"

    #if DEBUG
    static let isActive: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(flag) || arguments.contains(freshFlag)
    }()

    static let wantsFreshData: Bool = {
        ProcessInfo.processInfo.arguments.contains(freshFlag)
    }()
    #else
    static let isActive = false
    static let wantsFreshData = false
    #endif
}
