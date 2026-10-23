import Foundation

/// Which Apple bridge a destination belongs to.
enum SyncBridgeType: String, Codable, CaseIterable, Sendable {
    case calendar
    case reminders
}

/// The exact EventKit destination the user consented to, and the state of that
/// connection. Identifiers are authoritative: a destination is never resolved
/// by title, and a missing or changed identifier moves the connection to
/// `needsReconnection` instead of silently choosing another one.
struct SyncDestination: Codable, Equatable, Sendable, Identifiable {
    enum ConnectionState: String, Codable, Sendable {
        case needsReconnection
        case confirmed
    }

    var id: UUID
    var bridgeType: SyncBridgeType
    /// `EKCalendar.calendarIdentifier`.
    var calendarIdentifier: String
    var calendarTitle: String
    /// `EKSource.sourceIdentifier`.
    var sourceIdentifier: String
    var sourceTitle: String
    /// `EKSource.sourceType` as a stable string ("local", "calDAV", …).
    var sourceType: String
    /// True when MedNotes created the calendar/list rather than adopting one.
    var appCreated: Bool
    var consentAt: Date?
    var confirmedAt: Date?
    var needsReconnection: Bool

    var state: ConnectionState {
        needsReconnection ? .needsReconnection : .confirmed
    }

    init(id: UUID = UUID(), bridgeType: SyncBridgeType,
         calendarIdentifier: String, calendarTitle: String,
         sourceIdentifier: String, sourceTitle: String, sourceType: String,
         appCreated: Bool, consentAt: Date? = nil, confirmedAt: Date? = nil,
         needsReconnection: Bool = true) {
        self.id = id
        self.bridgeType = bridgeType
        self.calendarIdentifier = calendarIdentifier
        self.calendarTitle = calendarTitle
        self.sourceIdentifier = sourceIdentifier
        self.sourceTitle = sourceTitle
        self.sourceType = sourceType
        self.appCreated = appCreated
        self.consentAt = consentAt
        self.confirmedAt = confirmedAt
        self.needsReconnection = needsReconnection
    }

    /// Only a confirmed destination with recorded consent may receive writes.
    var mayReceiveWrites: Bool {
        state == .confirmed && consentAt != nil
    }
}

/// What the wizard needs to render a candidate. The caller builds these from
/// EventKit; nothing here reaches EventKit directly, which keeps the store
/// testable without calendar permissions.
struct SyncDestinationCandidate: Equatable, Sendable, Identifiable {
    var id: String { calendarIdentifier }
    var calendarIdentifier: String
    var calendarTitle: String
    var sourceIdentifier: String
    var sourceTitle: String
    var sourceType: String
    var isAppCreated: Bool
    /// How many records would leave the app if this destination were chosen.
    var recordCount: Int
    /// Human-readable field names that travel through the bridge.
    var transmittedFields: [String]
    /// EventKit cannot prove whether a destination is shared, so the wizard
    /// requires this acknowledgment whenever the source looks like a cloud
    /// account.
    var requiresCloudAcknowledgment: Bool
}

/// The encrypted store behind `sync_destinations` and the MedNotes↔EventKit
/// object map. Lives inside the SQLCipher database, so it is only reachable
/// while the store is unlocked.
///
/// The SQL lives in `Database` extension methods because that actor owns the
/// connection; this type is the typed façade the UI and the bridges use.
struct SyncDestinationStore: Sendable {
    private let db: Database

    init(db: Database) {
        self.db = db
    }

    func destination(for bridge: SyncBridgeType) async throws -> SyncDestination? {
        try await db.syncDestination(bridge: bridge)
    }

    func allDestinations() async throws -> [SyncDestination] {
        try await db.allSyncDestinations()
    }

    /// Saves a confirmed destination. `consentAt` is stamped inside the
    /// database layer so no caller can confirm without a recorded consent.
    /// Reconfirmation keeps the row's existing id: the object map and the
    /// markers already written to EventKit point at it.
    func confirm(bridge: SyncBridgeType, candidate: SyncDestinationCandidate) async throws -> SyncDestination {
        let now = Date()
        let existing = try await db.syncDestination(bridge: bridge)
        let destination = SyncDestination(
            id: existing?.id ?? UUID(),
            bridgeType: bridge,
            calendarIdentifier: candidate.calendarIdentifier,
            calendarTitle: candidate.calendarTitle,
            sourceIdentifier: candidate.sourceIdentifier,
            sourceTitle: candidate.sourceTitle,
            sourceType: candidate.sourceType,
            appCreated: candidate.isAppCreated,
            consentAt: now,
            confirmedAt: now,
            needsReconnection: false)
        try await db.upsertSyncDestination(destination)
        return destination
    }

    func upsert(_ destination: SyncDestination) async throws {
        try await db.upsertSyncDestination(destination)
    }

    /// Marks the connection as needing reconnection. Called when the
    /// identifier disappears, the source changes, or a backup is restored.
    func markNeedsReconnection(bridge: SyncBridgeType) async throws {
        try await db.markSyncDestinationNeedsReconnection(bridge: bridge)
    }

    /// Marks every destination stale. Used after a restore, before any sync
    /// may run again.
    func suspendAll() async throws {
        try await db.suspendSyncDestinations()
    }

    // MARK: - Object map

    struct ObjectMapping: Equatable, Sendable {
        var localID: String
        var remoteIdentifier: String
        var marker: String
    }

    /// Records the opaque marker MedNotes stamped on an EventKit object. The
    /// marker is what makes app-created objects distinguishable without
    /// relying on titles.
    func map(domain: String, localID: String, remoteIdentifier: String,
             destinationID: UUID, marker: String) async throws {
        try await db.mapSyncObject(
            domain: domain, localID: localID, remoteIdentifier: remoteIdentifier,
            destinationID: destinationID, marker: marker)
    }

    func mapping(domain: String, remoteIdentifier: String) async throws -> ObjectMapping? {
        try await db.syncMapping(domain: domain, remoteIdentifier: remoteIdentifier)
    }

    func mapping(domain: String, localID: String) async throws -> ObjectMapping? {
        try await db.syncMapping(domain: domain, localID: localID)
    }

    func allMappings(domain: String) async throws -> [ObjectMapping] {
        try await db.allSyncMappings(domain: domain)
    }

    func unmap(domain: String, localID: String) async throws {
        try await db.unmapSyncObject(domain: domain, localID: localID)
    }
}

/// A stable opaque marker attached to every MedNotes-created EventKit object.
/// The marker is random per destination and stored locally, so an object's
/// ownership is provable without reading its title.
enum SyncMarker {
    static func generate() -> String {
        "MN-" + (0..<16).map { _ in
            String("0123456789abcdef".randomElement() ?? "0")
        }.joined()
    }

    static func isMarker(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("MN-"), value.count == 19 else { return false }
        return value.dropFirst(3).allSatisfy { $0.isHexDigit }
    }
}
