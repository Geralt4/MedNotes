import Combine

/// Where a bridge stands with macOS. Both Apple services report this one
/// state, so the pill in each module and Settings › Sync read the same thing.
enum SyncBridgeAccess: Equatable, Sendable {
    case notRequested
    case denied
    case granted
}

/// What a pill or the Sync tab needs from a bridge, so one view can observe
/// either service.
@MainActor
protocol SyncBridgeService: ObservableObject {
    var state: SyncBridgeAccess { get }
    var lastError: String? { get }
}
