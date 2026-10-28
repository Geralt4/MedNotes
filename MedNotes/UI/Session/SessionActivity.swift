import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The audit trail as the Activity view reads it.
extension AppSession {
    // MARK: - Activity

    func recentActivity(limit: Int = 500) async -> [AuditLogEntry] {
        guard let store else { return [] }
        return (try? await store.audit.recentLogs(limit: limit)) ?? []
    }
}
