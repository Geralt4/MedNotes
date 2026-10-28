import EventKit
import Combine

/// Pure field bundle + merge rules for Apple Calendar sync so the
/// last-writer-wins logic is unit-testable without EventKit instances.
struct EventFields: Hashable, Sendable {
    var title: String
    var notes: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
}

enum CalendarSyncCore {
    enum PullDecision: Equatable {
        case same
        case update(conflict: Bool)
    }

    enum PushDecision: Equatable {
        /// Write the row's fields to the Apple object.
        case push
        /// The Apple object already holds them: nothing to write.
        case unchanged
        /// The Apple object was edited after the last sync and differs from
        /// the row. Writing would erase that edit, so the pull takes it.
        case remoteNewer
    }

    /// Run before a push, so a row with unsynced edits cannot silently
    /// overwrite an edit made in Calendar since. `remoteModified` is the
    /// object's `lastModifiedDate`; without it, or for a row never synced,
    /// there is no evidence the Apple copy changed and the row is pushed.
    static func pushDecision(local: CalendarEvent, remote: EventFields, remoteModified: Date?) -> PushDecision {
        guard remote != fields(of: local) else { return .unchanged }
        guard local.syncStatus != .localOnly,
              SyncDestinationCore.remoteChangedSinceSync(lastSync: local.lastSyncDate, remoteModified: remoteModified)
        else { return .push }
        return .remoteNewer
    }

    /// The direction rule is content-based: a differing remote copy wins when
    /// the local row is clean (never synced, or last synced after its last
    /// local edit). If the local row has unsynced edits AND remote drifted
    /// too, that is a conflict — remote wins and the caller surfaces a
    /// warning. A push checks the Apple object's `lastModifiedDate` first
    /// (`pushDecision`), so a row with unsynced edits reaches this rule
    /// instead of overwriting the remote edit.
    static func decide(local: CalendarEvent, remote: EventFields) -> PullDecision {
        guard remote != CalendarSyncCore.fields(of: local) else { return .same }
        let dirty = local.updatedAt > (local.lastSyncDate ?? .distantPast)
        return .update(conflict: dirty && local.syncStatus != .localOnly)
    }

    static func fields(of event: CalendarEvent) -> EventFields {
        EventFields(
            title: event.title,
            notes: event.description,
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay)
    }

    /// Applies remote fields onto a local model. The event type and patient
    /// link are MedNotes-only concepts; remote edits never clear them.
    static func merging(remote: EventFields, into event: inout CalendarEvent) {
        event.title = remote.title
        event.description = remote.notes
        event.startDate = remote.startDate
        event.isAllDay = remote.isAllDay
        var end = remote.endDate
        if remote.isAllDay && end < remote.startDate { end = remote.startDate }
        event.endDate = end
        event.ensureEndNotBeforeStart()
        // Keep updatedAt ≤ lastSyncDate so the row reads as clean afterwards.
        event.updatedAt = max(event.updatedAt, min(Date(), event.lastSyncDate ?? event.updatedAt))
    }
}

/// Owns the `EKEventStore` connection to Apple Calendar. Pushes MedNotes
/// events into a dedicated "MedNotes" calendar and pulls external edits back.
///
/// Permission failures degrade gracefully: the app remains fully usable as a
/// local calendar while `state == .denied`.
@MainActor
final class AppleCalendarService: ObservableObject, SyncBridgeService {
    typealias AccessState = SyncBridgeAccess

    struct PullResult: Sendable {
        var updates: [CalendarEvent] = []
        var creations: [CalendarEvent] = []
        /// Local rows whose remote object is gone or no longer MedNotes-owned.
        /// A conflict to resolve, never a silent deletion.
        var remoteMissing: [UUID] = []
        /// Local rows whose own unsynced edit lost the conflict to a newer
        /// remote version. Surfaced so the session can warn the user.
        var conflictingIDs: Set<UUID> = []
        /// Local rows whose own `ekEventIdentifier` finds nothing, or was never
        /// stored, though an Apple object made from them is in the destination
        /// (its marker names the row). Row id → the object's identifier. Not
        /// new events, and not missing ones: the row is pointed at its object.
        var rebinds: [UUID: String] = [:]
    }

    enum PushOutcome: Sendable {
        /// The row, as it now stands after the push.
        case pushed(CalendarEvent)
        /// The Apple event was edited after the last sync; nothing was
        /// written, and the pull that follows takes the Apple version.
        case remoteNewer
    }

    @Published private(set) var state: AccessState
    @Published private(set) var lastError: String?
    @Published var hasPendingExternalChanges = false

    nonisolated static let medNotesCalendarTitle = "MedNotes"

    init() {
        state = Self.initialState()
    }

    /// Whether macOS has already granted this app full Calendar access. A
    /// class-level query that never prompts, so automatic sync passes can
    /// consult it without raising the permission dialog.
    nonisolated static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// The pill should be truthful from launch: access granted in an earlier
    /// run is still granted. Sample-data runs stay "not connected" whatever
    /// TCC says, so the pill never advertises a bridge that
    /// `refusePreviewSeedWrites` blocks.
    private static func initialState() -> AccessState {
        guard !PreviewSeed.isActive else { return .notRequested }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        default: return .notRequested
        }
    }

    /// Re-reads access after the user may have changed it in System Settings.
    /// Never prompts.
    func refreshAccessState() {
        let current = Self.initialState()
        guard current != state else { return }
        state = current
        if current == .granted { lastError = nil }
    }

    /// How far back/forward external changes are pulled on each sync pass.
    static let pullWindow: TimeInterval = 366 * 24 * 3600

    private let store = EKEventStore()
    private var changeTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func requestAccess() async -> Bool {
        // A seeded run must never even raise the TCC prompt: granting it would
        // arm `push` for ~20 fabricated medical events.
        if (try? Self.refusePreviewSeedWrites()) == nil {
            lastError = "Apple Calendar is disabled while running on sample data."
            return false
        }
        do {
            if #available(macOS 14.0, *) {
                state = try await store.requestFullAccessToEvents() ? .granted : .denied
            } else {
                let granted: Bool = await withCheckedContinuation { continuation in
                    store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
                }
                state = granted ? .granted : .denied
            }
            if state == .granted { lastError = nil }
            return state == .granted
        } catch {
            state = .denied
            lastError = error.localizedDescription
            return false
        }
    }

    func startObservingChanges() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleExternalChangeHandling()
            }
        }
    }

    /// Debounced: EventKit can burst several notifications per edit.
    private func scheduleExternalChangeHandling() {
        changeTask?.cancel()
        changeTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            hasPendingExternalChanges = true
        }
    }

    func consumePendingExternalChanges() {
        if hasPendingExternalChanges { hasPendingExternalChanges = false }
    }

    // MARK: - Calendar management

    /// The calendars the destination wizard can offer, with the disclosure a
    /// choice needs. EventKit cannot prove whether a destination is shared, so
    /// a cloud source is marked for acknowledgment rather than claimed safe.
    func destinationCandidates(recordCount: Int, transmittedFields: [String])
        -> [SyncDestinationCandidate] {
        let candidates = store.calendars(for: .event).filter { $0.allowsContentModifications }
        return candidates.map { calendar in
            SyncDestinationCandidate(
                calendarIdentifier: calendar.calendarIdentifier,
                calendarTitle: calendar.title,
                sourceIdentifier: calendar.source?.sourceIdentifier ?? "",
                sourceTitle: calendar.source?.title ?? "",
                sourceType: Self.sourceTypeName(calendar.source?.sourceType),
                isAppCreated: calendar.title == Self.medNotesCalendarTitle,
                recordCount: recordCount,
                transmittedFields: transmittedFields,
                requiresCloudAcknowledgment: Self.isCloudSource(calendar.source?.sourceType))
        }
        .sorted { $0.calendarTitle.localizedStandardCompare($1.calendarTitle) == .orderedAscending }
    }

    /// The sources the wizard offers when the user wants a new calendar, one
    /// per account, explicitly chosen rather than defaulted silently.
    func sourceCandidates() -> [(identifier: String, title: String, type: String, isCloud: Bool)] {
        store.sources
            .filter { $0.sourceType != .subscribed && $0.sourceType != .birthdays }
            .map { source in
                (source.sourceIdentifier, source.title, Self.sourceTypeName(source.sourceType),
                 Self.isCloudSource(source.sourceType))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Creates `MedNotes` in the explicitly chosen source and returns its
    /// candidate. The user picked the source; nothing is guessed.
    func createMedNotesCalendar(inSource sourceIdentifier: String) throws -> SyncDestinationCandidate {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceIdentifier }) else {
            throw CalendarSyncError.noCalendarSource
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.medNotesCalendarTitle
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw CalendarSyncError.calendarCreateFailed(error.localizedDescription)
        }
        return SyncDestinationCandidate(
            calendarIdentifier: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            sourceIdentifier: source.sourceIdentifier,
            sourceTitle: source.title,
            sourceType: Self.sourceTypeName(source.sourceType),
            isAppCreated: true,
            recordCount: 0,
            transmittedFields: [],
            requiresCloudAcknowledgment: Self.isCloudSource(source.sourceType))
    }

    /// Resolves a confirmed destination to the live `EKCalendar`, or nil when
    /// it no longer exists. Never falls back to a title match.
    func calendar(for destination: SyncDestination) -> EKCalendar? {
        store.calendar(withIdentifier: destination.calendarIdentifier)
    }

    private static func sourceTypeName(_ type: EKSourceType?) -> String {
        switch type {
        case .local: return "local"
        case .exchange: return "exchange"
        case .calDAV: return "calDAV"
        case .mobileMe: return "mobileMe"
        case .subscribed: return "subscribed"
        case .birthdays: return "birthdays"
        default: return "other"
        }
    }

    private static func isCloudSource(_ type: EKSourceType?) -> Bool {
        switch type {
        case .calDAV, .exchange, .mobileMe: return true
        default: return false
        }
    }

    // MARK: - Destination-bound push

    /// Creates or updates the remote counterpart of a MedNotes event inside
    /// the confirmed destination. Refuses to write without consent.
    func push(_ event: CalendarEvent, to destination: SyncDestination) async throws -> PushOutcome {
        try Self.refusePreviewSeedWrites()
        guard state == .granted else { throw CalendarSyncError.accessDenied }
        guard SyncDestinationCore.mayWrite(destination) else {
            throw CalendarSyncError.destinationNotConfirmed
        }
        guard let targetCalendar = calendar(for: destination) else {
            throw CalendarSyncError.destinationMissing
        }
        var ek: EKEvent
        var isExisting = true
        if let identifier = event.ekEventIdentifier,
           let found = store.calendarItem(withIdentifier: identifier) as? EKEvent,
           found.calendar?.calendarIdentifier == destination.calendarIdentifier {
            ek = found
        } else if let made = objectMade(from: event.id, in: targetCalendar, destination: destination) {
            // The row lost the identifier of an object it already made (a full
            // sync changes them, or a save was skipped): reuse it, never make
            // a second one.
            ek = made
        } else {
            ek = EKEvent(eventStore: store)
            ek.title = SyncDestinationCore.titleForRemote(event.title)
            isExisting = false
        }
        if isExisting {
            let decision = CalendarSyncCore.pushDecision(
                local: event, remote: ek.fields(), remoteModified: ek.lastModifiedDate)
            if decision == .remoteNewer { return .remoteNewer }
            if decision == .unchanged, SyncDestinationCore.recordID(from: ek.url) == event.id {
                return .pushed(syncedCopy(of: event, from: ek))
            }
        }
        apply(event.fields(), to: ek)
        ek.calendar = targetCalendar
        // The marker is what makes the object provably MedNotes-owned without
        // reading its title, and names the row it was made from.
        ek.url = SyncDestinationCore.markerURL(for: destination, record: event.id)
        do {
            try store.save(ek, span: .thisEvent, commit: true)
        } catch {
            throw CalendarSyncError.saveFailed(error.localizedDescription)
        }
        return .pushed(syncedCopy(of: event, from: ek))
    }

    private func syncedCopy(of event: CalendarEvent, from ek: EKEvent) -> CalendarEvent {
        var synced = event
        synced.ekEventIdentifier = ek.calendarItemIdentifier
        synced.syncStatus = .synced
        synced.lastSyncDate = Date()
        synced.ensureEndNotBeforeStart()
        return synced
    }

    /// An event in the destination that MedNotes made from row `id`, if any.
    private func objectMade(from id: UUID, in calendar: EKCalendar, destination: SyncDestination) -> EKEvent? {
        let start = Date().addingTimeInterval(-Self.pullWindow)
        let end = Date().addingTimeInterval(Self.pullWindow)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).first { ek in
            SyncDestinationCore.recordID(from: ek.url) == id
                && SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: ek.url),
                    destination: destination, inDestination: true)
        }
    }

    func deleteRemote(_ event: CalendarEvent, from destination: SyncDestination) async throws {
        guard state == .granted,
              let identifier = event.ekEventIdentifier,
              let item = store.calendarItem(withIdentifier: identifier) as? EKEvent,
              item.calendar?.calendarIdentifier == destination.calendarIdentifier,
              SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: item.url),
                destination: destination,
                inDestination: true) else {
            return
        }
        do {
            try store.remove(item, span: .thisEvent, commit: true)
        } catch {
            throw CalendarSyncError.saveFailed(error.localizedDescription)
        }
    }

    private func apply(_ fields: EventFields, to ek: EKEvent) {
        ek.title = SyncDestinationCore.titleForRemote(fields.title)
        ek.notes = fields.notes
        ek.startDate = fields.startDate
        ek.endDate = fields.isAllDay
            ? max(fields.endDate, fields.startDate)
            : fields.endDate
        if ek.endDate < ek.startDate { ek.endDate = ek.startDate.addingTimeInterval(1800) }
        ek.isAllDay = fields.isAllDay
    }

    // MARK: - Destination-bound pull

    /// One reconcile pass against the confirmed destination. Only objects in
    /// that calendar and carrying the MedNotes marker are read; a local row
    /// whose remote object disappeared is reported as a conflict, never a
    /// silent delete.
    func pull(localEvents: [CalendarEvent], from destination: SyncDestination) async throws -> PullResult {
        guard state == .granted else { throw CalendarSyncError.accessDenied }
        guard let targetCalendar = calendar(for: destination) else {
            throw CalendarSyncError.destinationMissing
        }
        var result = PullResult()

        let byEKID = Dictionary(localEvents.compactMap { event -> (String, CalendarEvent)? in
            guard let id = event.ekEventIdentifier else { return nil }
            return (id, event)
        }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(localEvents.map(\.id))

        // The destination's objects, read once: re-binding a lost identifier
        // and importing both need them.
        let start = Date().addingTimeInterval(-Self.pullWindow)
        let end = Date().addingTimeInterval(Self.pullWindow)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [targetCalendar])
        let windowEvents = store.events(matching: predicate)
        var madeFrom: [UUID: EKEvent] = [:]
        for ek in windowEvents {
            guard let record = SyncDestinationCore.recordID(from: ek.url), madeFrom[record] == nil,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: ek.url),
                    destination: destination, inDestination: true) else { continue }
            madeFrom[record] = ek
        }
        // A row that never stored its object's identifier (its save was
        // skipped because the row had been edited again) has the object but
        // does not know it.
        for local in localEvents where local.ekEventIdentifier == nil {
            if let made = madeFrom[local.id] { result.rebinds[local.id] = made.calendarItemIdentifier }
        }

        for (identifier, local) in byEKID {
            let item = store.calendarItem(withIdentifier: identifier) as? EKEvent
            guard let ek = item,
                  ek.calendar?.calendarIdentifier == destination.calendarIdentifier,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: ek.url),
                    destination: destination,
                    inDestination: true) else {
                // Its identifier finds nothing, but the object it made is
                // there under another one: point the row at it.
                if let made = madeFrom[local.id] {
                    result.rebinds[local.id] = made.calendarItemIdentifier
                    continue
                }
                // Missing, moved or untagged remotely: a conflict the user
                // resolves, never a deletion.
                result.remoteMissing.append(local.id)
                continue
            }
            let remote = ek.fields()
            switch CalendarSyncCore.decide(local: local, remote: remote) {
            case .same:
                continue
            case .update(let conflict):
                var merged = local
                CalendarSyncCore.merging(remote: remote, into: &merged)
                merged.syncStatus = .synced
                merged.lastSyncDate = Date()
                if conflict { result.conflictingIDs.insert(local.id) }
                result.updates.append(merged)
            }
        }

        var imported = Set<String>()
        for ek in windowEvents {
            let identifier = ek.calendarItemIdentifier
            guard byEKID[identifier] == nil else { continue }
            // Made from a row we have: not a new event, whatever identifier
            // EventKit gives it now.
            if let record = SyncDestinationCore.recordID(from: ek.url), localIDs.contains(record) { continue }
            // Only MedNotes-created objects may be imported.
            guard SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: ek.url),
                destination: destination,
                inDestination: true) else { continue }
            // One import per remote item: a recurring event yields one entry per occurrence, all sharing the identifier.
            guard imported.insert(identifier).inserted else { continue }
            result.creations.append(CalendarEvent(
                title: SyncDestinationCore.titleFromRemote(ek.title),
                description: ek.notes ?? "",
                startDate: ek.startDate,
                endDate: ek.endDate ?? (ek.isAllDay ? ek.startDate : ek.startDate.addingTimeInterval(1800)),
                isAllDay: ek.isAllDay,
                patientId: nil,
                eventType: .appointment,
                createdAt: ek.creationDate ?? Date(),
                updatedAt: Date(),
                ekEventIdentifier: identifier,
                syncStatus: .synced,
                lastSyncDate: Date()))
        }
        return result
    }

    /// Structural containment for `--preview-seed` runs, at the EventKit
    /// boundary rather than at the call sites.
    ///
    /// `AppSession` already declines to observe calendar changes and returns
    /// early from `syncCalendarNow()` in preview mode, but those are two
    /// behavioural guards in two places, and every seeded event has
    /// `ekEventIdentifier == nil`, so `needsPush` is true for all of them. If
    /// both of those regress, this turns the worst case into a thrown error in
    /// a debug build instead of twenty fabricated events in the user's real
    /// Apple Calendar.
    private static func refusePreviewSeedWrites() throws {
        #if DEBUG
        if PreviewSeed.isActive { throw CalendarSyncError.previewSeedActive }
        #endif
    }

    enum CalendarSyncError: LocalizedError {
        case accessDenied
        case previewSeedActive
        case noCalendarSource
        case calendarCreateFailed(String)
        case saveFailed(String)
        case destinationNotConfirmed
        case destinationMissing

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return String(localized: "Apple Calendar access was not granted.")
            case .previewSeedActive:
                return "Apple Calendar sync is disabled while running on sample data."
            case .noCalendarSource:
                return String(localized: "No calendar account is available to create the MedNotes calendar.")
            case .calendarCreateFailed(let detail):
                return String(localized: "Could not create the MedNotes calendar: \(detail)")
            case .saveFailed(let detail):
                return String(localized: "Calendar write failed: \(detail)")
            case .destinationNotConfirmed:
                return String(localized: "Choose and confirm a calendar destination before syncing.")
            case .destinationMissing:
                return String(localized: "The chosen calendar no longer exists. Reconnect in Settings \u{203a} Sync.")
            }
        }
    }
}

extension EKEvent {
    func fields() -> EventFields {
        EventFields(
            title: SyncDestinationCore.titleFromRemote(title),
            notes: notes ?? "",
            startDate: startDate,
            endDate: endDate ?? (isAllDay ? startDate : startDate.addingTimeInterval(1800)),
            isAllDay: isAllDay)
    }
}

extension CalendarEvent {
    func fields() -> EventFields {
        CalendarSyncCore.fields(of: self)
    }
}
