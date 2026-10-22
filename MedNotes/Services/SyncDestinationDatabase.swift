import Foundation

/// SQL access for explicit sync destinations and the MedNotes↔EventKit object
/// map. Lives here, not in `Database.swift`, so the CLI's system-only
/// typecheck never sees EventKit-adjacent types.
extension Database {
    // MARK: - Destinations

    func syncDestination(bridge: SyncBridgeType) throws -> SyncDestination? {
        let s = try conn.prepare("""
            SELECT id, bridge_type, calendar_identifier, calendar_title,
                   source_identifier, source_title, source_type, app_created,
                   consent_at, confirmed_at, needs_reconnection
            FROM sync_destinations WHERE bridge_type = ?
            """)
        s.bind(1, bridge.rawValue)
        guard try s.step() else { return nil }
        return Self.decodeSyncDestination(s)
    }

    func allSyncDestinations() throws -> [SyncDestination] {
        let s = try conn.prepare("""
            SELECT id, bridge_type, calendar_identifier, calendar_title,
                   source_identifier, source_title, source_type, app_created,
                   consent_at, confirmed_at, needs_reconnection
            FROM sync_destinations
            """)
        var out: [SyncDestination] = []
        while try s.step() {
            if let destination = Self.decodeSyncDestination(s) { out.append(destination) }
        }
        return out
    }

    func upsertSyncDestination(_ destination: SyncDestination) throws {
        let s = try conn.prepare("""
            INSERT INTO sync_destinations (
                id, bridge_type, calendar_identifier, calendar_title,
                source_identifier, source_title, source_type, app_created,
                consent_at, confirmed_at, needs_reconnection, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(bridge_type) DO UPDATE SET
                calendar_identifier=excluded.calendar_identifier,
                calendar_title=excluded.calendar_title,
                source_identifier=excluded.source_identifier,
                source_title=excluded.source_title,
                source_type=excluded.source_type,
                app_created=excluded.app_created,
                consent_at=excluded.consent_at,
                confirmed_at=excluded.confirmed_at,
                needs_reconnection=excluded.needs_reconnection,
                updated_at=excluded.updated_at
            """)
        let now = LenientDate.encodeSQL(Date())
        s.bind(1, destination.id.uuidString)
        s.bind(2, destination.bridgeType.rawValue)
        s.bind(3, destination.calendarIdentifier)
        s.bind(4, destination.calendarTitle)
        s.bind(5, destination.sourceIdentifier)
        s.bind(6, destination.sourceTitle)
        s.bind(7, destination.sourceType)
        s.bind(8, destination.appCreated)
        s.bind(9, destination.consentAt.map(LenientDate.encodeSQL))
        s.bind(10, destination.confirmedAt.map(LenientDate.encodeSQL))
        s.bind(11, destination.needsReconnection)
        s.bind(12, now)
        s.bind(13, now)
        _ = try s.step()
    }

    func markSyncDestinationNeedsReconnection(bridge: SyncBridgeType) throws {
        let s = try conn.prepare("""
            UPDATE sync_destinations
            SET needs_reconnection = 1, confirmed_at = NULL, updated_at = ?
            WHERE bridge_type = ?
            """)
        s.bind(1, LenientDate.encodeSQL(Date()))
        s.bind(2, bridge.rawValue)
        _ = try s.step()
    }

    // MARK: - Object map

    func mapSyncObject(domain: String, localID: String, remoteIdentifier: String,
                       destinationID: UUID, marker: String) throws {
        let s = try conn.prepare("""
            INSERT INTO sync_object_map (id, domain, local_id, remote_identifier, destination_id, marker, updated_at)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(domain, local_id) DO UPDATE SET
                remote_identifier=excluded.remote_identifier,
                destination_id=excluded.destination_id,
                marker=excluded.marker,
                updated_at=excluded.updated_at
            """)
        s.bind(1, UUID().uuidString)
        s.bind(2, domain)
        s.bind(3, localID)
        s.bind(4, remoteIdentifier)
        s.bind(5, destinationID.uuidString)
        s.bind(6, marker)
        s.bind(7, LenientDate.encodeSQL(Date()))
        _ = try s.step()
    }

    func syncMapping(domain: String, remoteIdentifier: String) throws -> SyncDestinationStore.ObjectMapping? {
        let s = try conn.prepare("""
            SELECT local_id, remote_identifier, marker FROM sync_object_map
            WHERE domain = ? AND remote_identifier = ?
            """)
        s.bind(1, domain)
        s.bind(2, remoteIdentifier)
        guard try s.step() else { return nil }
        return SyncDestinationStore.ObjectMapping(
            localID: s.columnText(0) ?? "",
            remoteIdentifier: s.columnText(1) ?? "",
            marker: s.columnText(2) ?? "")
    }

    func syncMapping(domain: String, localID: String) throws -> SyncDestinationStore.ObjectMapping? {
        let s = try conn.prepare("""
            SELECT local_id, remote_identifier, marker FROM sync_object_map
            WHERE domain = ? AND local_id = ?
            """)
        s.bind(1, domain)
        s.bind(2, localID)
        guard try s.step() else { return nil }
        return SyncDestinationStore.ObjectMapping(
            localID: s.columnText(0) ?? "",
            remoteIdentifier: s.columnText(1) ?? "",
            marker: s.columnText(2) ?? "")
    }

    func allSyncMappings(domain: String) throws -> [SyncDestinationStore.ObjectMapping] {
        let s = try conn.prepare("""
            SELECT local_id, remote_identifier, marker FROM sync_object_map WHERE domain = ?
            """)
        s.bind(1, domain)
        var out: [SyncDestinationStore.ObjectMapping] = []
        while try s.step() {
            out.append(SyncDestinationStore.ObjectMapping(
                localID: s.columnText(0) ?? "",
                remoteIdentifier: s.columnText(1) ?? "",
                marker: s.columnText(2) ?? ""))
        }
        return out
    }

    func unmapSyncObject(domain: String, localID: String) throws {
        let s = try conn.prepare("DELETE FROM sync_object_map WHERE domain = ? AND local_id = ?")
        s.bind(1, domain)
        s.bind(2, localID)
        _ = try s.step()
    }

    private static func decodeSyncDestination(_ s: Statement) -> SyncDestination? {
        guard let idString = s.columnText(0), let id = UUID(uuidString: idString),
              let bridge = s.columnText(1).flatMap(SyncBridgeType.init(rawValue:)) else {
            return nil
        }
        func date(_ index: Int32) -> Date? {
            s.columnText(index).flatMap { try? LenientDate.decode($0) }
        }
        return SyncDestination(
            id: id,
            bridgeType: bridge,
            calendarIdentifier: s.columnText(2) ?? "",
            calendarTitle: s.columnText(3) ?? "",
            sourceIdentifier: s.columnText(4) ?? "",
            sourceTitle: s.columnText(5) ?? "",
            sourceType: s.columnText(6) ?? "other",
            appCreated: s.columnBool(7) ?? false,
            consentAt: date(8),
            confirmedAt: date(9),
            needsReconnection: s.columnBool(10) ?? true)
    }
}
