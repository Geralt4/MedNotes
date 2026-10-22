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

    /// EventKit exposes no public per-event "modified at", so the direction
    /// rule is content-based: a differing remote copy wins when the local row
    /// is clean (never synced, or last synced after its last local edit). If
    /// the local row has unsynced edits AND remote drifted too, that is a
    /// conflict — the plan mandates remote-wins with a surfaced warning.
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
    }

    @Published private(set) var state: AccessState
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncDate: Date?
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
            .filter { $0.sourceType != .subscribed }
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
    func push(_ event: CalendarEvent, to destination: SyncDestination) async throws -> CalendarEvent {
        try Self.refusePreviewSeedWrites()
        guard state == .granted else { throw CalendarSyncError.accessDenied }
        guard SyncDestinationCore.mayWrite(destination) else {
            throw CalendarSyncError.destinationNotConfirmed
        }
        guard let targetCalendar = calendar(for: destination) else {
            throw CalendarSyncError.destinationMissing
        }
        var ek: EKEvent
        if let identifier = event.ekEventIdentifier,
           let found = store.calendarItem(withIdentifier: identifier) as? EKEvent,
           found.calendar?.calendarIdentifier == destination.calendarIdentifier {
            ek = found
        } else {
            ek = EKEvent(eventStore: store)
            ek.title = event.title.isEmpty ? String(localized: "(untitled)") : event.title
        }
        apply(event.fields(), to: ek)
        ek.calendar = targetCalendar
        // The marker is what makes the object provably MedNotes-owned without
        // reading its title.
        ek.url = SyncDestinationCore.markerURL(for: destination)
        do {
            try store.save(ek, span: .thisEvent, commit: true)
        } catch {
            throw CalendarSyncError.saveFailed(error.localizedDescription)
        }
        var synced = event
        synced.ekEventIdentifier = ek.calendarItemIdentifier
        synced.syncStatus = .synced
        synced.lastSyncDate = Date()
        synced.ensureEndNotBeforeStart()
        return synced
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
        ek.title = fields.title.isEmpty ? String(localized: "(untitled)") : fields.title
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

        for (identifier, local) in byEKID {
            let item = store.calendarItem(withIdentifier: identifier) as? EKEvent
            guard let ek = item,
                  ek.calendar?.calendarIdentifier == destination.calendarIdentifier,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: ek.url),
                    destination: destination,
                    inDestination: true) else {
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

        let start = Date().addingTimeInterval(-Self.pullWindow)
        let end = Date().addingTimeInterval(Self.pullWindow)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [targetCalendar])
        for ek in store.events(matching: predicate) {
            let identifier = ek.calendarItemIdentifier
            guard byEKID[identifier] == nil else { continue }
            // Only MedNotes-created objects may be imported.
            guard SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: ek.url),
                destination: destination,
                inDestination: true) else { continue }
            result.creations.append(CalendarEvent(
                title: ek.title ?? "",
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
            title: title ?? "",
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
