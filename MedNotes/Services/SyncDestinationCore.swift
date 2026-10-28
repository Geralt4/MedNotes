import Foundation

/// Pure decisions for destination-based Apple sync: who may write, which
/// remote objects MedNotes owns, and what happens when a destination
/// disappears. No EventKit types, so every rule is unit-testable.
enum SyncDestinationCore {
    /// A bridge may write only to a confirmed destination whose consent
    /// predates the write and which has not been suspended by a restore.
    static func mayWrite(_ destination: SyncDestination?) -> Bool {
        guard let destination else { return false }
        return destination.mayReceiveWrites
    }

    /// A remote object is MedNotes-owned when it sits in the confirmed
    /// destination AND carries the marker MedNotes stamped on it. Title is
    /// never consulted.
    static func ownsRemoteObject(
        marker: String?, destination: SyncDestination, inDestination: Bool
    ) -> Bool {
        guard inDestination, destination.state == .confirmed else { return false }
        return marker == destination.id.uuidString || SyncMarker.isMarker(marker)
    }

    /// The destination's identifier must still exist and match the stored one
    /// exactly. A rename or a deleted container is `needsReconnection`, never a
    /// fallback to a title scan.
    static func destinationIsCurrent(
        _ destination: SyncDestination,
        existingCalendarIdentifiers: Set<String>,
        existingSourceIdentifiers: Set<String>
    ) -> Bool {
        existingCalendarIdentifiers.contains(destination.calendarIdentifier)
            && existingSourceIdentifiers.contains(destination.sourceIdentifier)
    }

    /// What the upgrade does with legacy remote mappings: a unique remote
    /// mapping for a bridge may be preselected, but the user must confirm
    /// before the first write. Multiple or none always opens the chooser.
    static func preselectLegacyCandidate(
        mappings: [SyncDestinationStore.ObjectMapping],
        candidates: [SyncDestinationCandidate]
    ) -> SyncDestinationCandidate? {
        let remoteIDs = Set(mappings.map(\.remoteIdentifier))
        let matches = candidates.filter { remoteIDs.contains($0.calendarIdentifier) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// An opaque marker for an EventKit object. Stored in the object's `url`
    /// field, which both `EKEvent` and `EKReminder` expose and which never
    /// reaches the user's notes text.
    ///
    /// `record` is the MedNotes row the object was made from. EventKit can
    /// change an object's own identifier (a full sync does), and the row then
    /// holds one that finds nothing; the record id lets the next pass find
    /// the object again instead of importing it as a new row. Markers made
    /// before this had the destination alone, and still read as owned.
    static func markerURL(for destination: SyncDestination, record: UUID? = nil) -> URL {
        var text = "x-mednotes://object/\(destination.id.uuidString)"
        if let record { text += "/\(record.uuidString)" }
        return URL(string: text)!
    }

    /// The destination part of the marker on an EventKit object's URL.
    static func marker(from url: URL?) -> String? {
        guard let url, url.scheme == "x-mednotes" else { return nil }
        return url.pathComponents.filter { $0 != "/" }.first
    }

    /// The MedNotes row an object was made from, when its marker says.
    static func recordID(from url: URL?) -> UUID? {
        guard let url, url.scheme == "x-mednotes" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { return nil }
        return UUID(uuidString: parts[1])
    }

    /// How far after the last sync an Apple object's modified time may be and
    /// still count as our own push. Calendar servers stamp a change when it
    /// reaches them, which is after the moment the push was saved here; reading
    /// that stamp as someone else's edit would put the old Apple copy over the
    /// user's newer edit.
    static let remoteChangeTolerance: TimeInterval = 60

    /// Whether an Apple object was changed by someone else after the row last
    /// synced with it.
    static func remoteChangedSinceSync(lastSync: Date?, remoteModified: Date?) -> Bool {
        guard let lastSync, let remoteModified else { return false }
        return remoteModified > lastSync.addingTimeInterval(remoteChangeTolerance)
    }

    /// What Apple Calendar and Reminders show for a record with no title: they
    /// want one, so the placeholder is written in its place.
    static func titleForRemote(_ title: String) -> String {
        title.isEmpty ? String(localized: "(untitled)") : title
    }

    /// The title read back from an Apple object. The placeholder this app
    /// wrote (in the current language, or in English) means "no title", not a
    /// title of that text; taken literally it would be written into the
    /// record on the next pass.
    static func titleFromRemote(_ remote: String?) -> String {
        guard let remote else { return "" }
        let placeholders: Set<String> = [String(localized: "(untitled)"), "(untitled)"]
        return placeholders.contains(remote) ? "" : remote
    }
}

/// What the session reports after a sync pass, including the cases the plan
/// calls out: a missing remote object is a conflict, not a silent delete.
struct SyncPassReport: Sendable, Equatable {
    var pushed = 0
    var updated = 0
    var pulled = 0
    var created = 0
    var conflicts = 0
    var remoteMissing: [UUID] = []
    var skippedForConsent = 0

    var summary: String {
        var parts: [String] = []
        if pushed > 0 { parts.append(String(localized: "pushed \(pushed)")) }
        if updated > 0 { parts.append(String(localized: "updated \(updated)")) }
        if created > 0 { parts.append(String(localized: "created \(created)")) }
        if pulled > 0 { parts.append(String(localized: "pulled \(pulled)")) }
        if conflicts > 0 { parts.append(String(localized: "\(conflicts) conflicts")) }
        if !remoteMissing.isEmpty { parts.append(String(localized: "\(remoteMissing.count) missing remotely")) }
        if skippedForConsent > 0 { parts.append(String(localized: "\(skippedForConsent) awaiting consent")) }
        return parts.isEmpty ? String(localized: "Nothing to sync") : parts.joined(separator: ", ")
    }
}
