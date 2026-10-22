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
    static func markerURL(for destination: SyncDestination) -> URL {
        URL(string: "x-mednotes://object/\(destination.id.uuidString)")!
    }

    /// Reads the marker back from an EventKit object's URL.
    static func marker(from url: URL?) -> String? {
        guard let url, url.scheme == "x-mednotes" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.last
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
