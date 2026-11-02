import EventKit
import Combine

/// A calendar day with no time-of-day: the unit MedNotes compares due dates
/// in (the editor's picker is date-only; `isOverdue` and `isDueToday` look at
/// days). Plain integers, so equality never depends on which stray fields a
/// `DateComponents` happens to carry.
struct DueDay: Hashable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// nil when the components do not name a whole day, which is how a
    /// reminder without a due date reads.
    init?(components: DateComponents?) {
        guard let components,
              let year = components.year, let month = components.month, let day = components.day
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var components: DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    /// Start of the day in `calendar`: the instant MedNotes stores for a due
    /// date it learned from Reminders.
    func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: components)
    }
}

/// Pure field bundle + merge rules for Apple Reminders sync so the
/// last-writer-wins logic is unit-testable without EventKit instances.
///
/// The due date travels as a day alone: the time-of-day a local `Date()`
/// happened to carry never counts as drift, and a time the user set on the
/// reminder in the Reminders app survives pushes that keep the same day.
struct ReminderFields: Hashable, Sendable {
    var title: String
    var notes: String
    var dueDay: DueDay?
    var isCompleted: Bool
    var priority: TodoPriority
}

enum ReminderSyncCore {
    /// Whether the todo has anything to send. A new todo nobody has typed into is
    /// a placeholder the editor discards when it closes; see
    /// `CalendarSyncCore.shouldPush`.
    static func shouldPush(_ todo: TodoItem) -> Bool {
        if todo.reminderIdentifier == nil { return !todo.isUntouchedNewRecord }
        guard todo.syncStatus != .localOnly else { return true }
        guard let synced = todo.lastSyncDate else { return true }
        return todo.updatedAt > synced
    }

    enum PullDecision: Equatable {
        case same
        case update(conflict: Bool)
    }

    enum PushDecision: Equatable {
        /// Write the todo's fields to the reminder.
        case push
        /// The reminder already holds them: nothing to write.
        case unchanged
        /// The reminder was edited after the last sync and differs from the
        /// todo. Writing would erase that edit, so the pull takes it.
        case remoteNewer
    }

    /// As `CalendarSyncCore.pushDecision`. The comparison is the same field
    /// comparison the pull uses, so the due day (not the time of day a local
    /// `Date()` carries) decides whether the two differ.
    static func pushDecision(local: TodoItem, remote: ReminderFields, remoteModified: Date?,
                             calendar: Calendar = .current) -> PushDecision {
        guard remote != fields(of: local, calendar: calendar) else { return .unchanged }
        guard local.syncStatus != .localOnly,
              SyncDestinationCore.remoteChangedSinceSync(lastSync: local.lastSyncDate, remoteModified: remoteModified)
        else { return .push }
        return .remoteNewer
    }

    /// Same direction rule as `CalendarSyncCore.decide`: a differing remote
    /// copy wins when the local row is clean (never synced, or last synced
    /// after its last local edit). If the local row has unsynced edits AND
    /// remote drifted too, that is a conflict — remote wins and the caller
    /// surfaces a warning. A push checks the reminder's `lastModifiedDate`
    /// first (`pushDecision`), so such a row reaches this rule instead of
    /// overwriting the remote edit.
    static func decide(local: TodoItem, remote: ReminderFields, calendar: Calendar = .current) -> PullDecision {
        guard remote != fields(of: local, calendar: calendar) else { return .same }
        let dirty = local.updatedAt > (local.lastSyncDate ?? .distantPast)
        return .update(conflict: dirty && local.syncStatus != .localOnly)
    }

    static func fields(of todo: TodoItem, calendar: Calendar = .current) -> ReminderFields {
        ReminderFields(
            title: todo.title,
            notes: todo.notes ?? "",
            dueDay: todo.dueDate.map { DueDay(date: $0, calendar: calendar) },
            isCompleted: todo.isCompleted,
            priority: todo.priority)
    }

    /// Applies remote fields onto a local model. The patient link and the
    /// tags are MedNotes-only concepts; remote edits never clear them. A due
    /// date on the same day keeps its local instant, so a round trip never
    /// rewrites the row's time-of-day.
    static func merging(remote: ReminderFields, into todo: inout TodoItem,
                        completedAt: Date? = nil, calendar: Calendar = .current, now: Date = Date()) {
        todo.title = remote.title
        todo.notes = remote.notes.isEmpty ? nil : remote.notes
        switch (remote.dueDay, todo.dueDate) {
        case (nil, _):
            todo.dueDate = nil
        case (let day?, let existing?) where DueDay(date: existing, calendar: calendar) == day:
            break
        case (let day?, _):
            todo.dueDate = day.date(calendar: calendar)
        }
        if remote.isCompleted != todo.isCompleted {
            todo.isCompleted = remote.isCompleted
            todo.completedAt = remote.isCompleted ? (completedAt ?? now) : nil
        }
        todo.priority = remote.priority
        // Keep updatedAt ≤ lastSyncDate so the row reads as clean afterwards.
        todo.updatedAt = max(todo.updatedAt, min(now, todo.lastSyncDate ?? todo.updatedAt))
    }

    // MARK: Priority

    /// EventKit priorities run 0 (none), 1–4 (high), 5 (medium), 6–9 (low).
    /// "None" reads as MedNotes' default, so a reminder the user never
    /// flagged does not count as drift against a medium todo.
    static func priority(fromReminder value: Int) -> TodoPriority {
        switch value {
        case 1...4: return .high
        case 6...9: return .low
        default: return .medium
        }
    }

    /// Medium goes out as "none": it is MedNotes' default, and a flag on
    /// every synced reminder would make the Reminders list unreadable.
    static func reminderPriority(_ priority: TodoPriority) -> Int {
        switch priority {
        case .high: return 1
        case .medium: return 0
        case .low: return 9
        }
    }
}

/// Owns the connection to Apple Reminders (through a `RemindersBackend`). Pushes MedNotes
/// todos into a dedicated "MedNotes" list and pulls external edits back.
///
/// Permission failures degrade gracefully: the app remains fully usable as a
/// local todo list while `state == .denied`.
@MainActor
final class AppleRemindersService: ObservableObject, SyncBridgeService {
    typealias AccessState = SyncBridgeAccess

    struct PullResult: Sendable {
        var updates: [TodoItem] = []
        var creations: [TodoItem] = []
        /// Local rows whose remote reminder is gone or no longer MedNotes-owned.
        /// A conflict to resolve, never a silent deletion.
        var remoteMissing: [UUID] = []
        /// Local rows whose own unsynced edit lost the conflict to a newer
        /// remote version. Surfaced so the session can warn the user.
        var conflictingIDs: Set<UUID> = []
        /// Local rows whose own `reminderIdentifier` finds nothing, or was
        /// never stored, though a reminder made from them is in the list (its
        /// marker names the row). Row id → the reminder's identifier.
        var rebinds: [UUID: String] = [:]
        /// MedNotes-made reminders whose todo was deleted here, left alone
        /// rather than imported as new todos.
        var ignoredDeleted = 0
    }

    enum PushOutcome: Sendable {
        /// The todo, as it now stands after the push.
        case pushed(TodoItem)
        /// The reminder was edited after the last sync; nothing was written,
        /// and the pull that follows takes the reminder's version.
        case remoteNewer
        /// The reminder this todo made has been moved to another list. Nothing
        /// was written (a second reminder would sit beside it); the pull that
        /// follows reports the todo as missing from the list.
        case movedElsewhere
    }

    @Published private(set) var state: AccessState
    @Published private(set) var lastError: String?
    @Published var hasPendingExternalChanges = false

    nonisolated static let medNotesListTitle = "MedNotes"

    private let backend: RemindersBackend
    private var changeTask: Task<Void, Never>?
    private var isObserving = false

    /// `backend` is Apple Reminders itself unless a test passes a fake.
    init(backend: RemindersBackend? = nil) {
        let backend = backend ?? EventKitRemindersBackend()
        self.backend = backend
        state = Self.initialState(backend)
    }

    /// Whether macOS has already granted this app full Reminders access. A
    /// query that never prompts, so automatic sync passes can consult it
    /// without raising the permission dialog.
    var hasFullAccess: Bool {
        backend.authorization == .granted
    }

    /// The pill should be truthful from launch: access granted in an earlier
    /// run is still granted. Sample-data runs stay "not connected" whatever
    /// TCC says, so the pill never advertises a bridge that
    /// `refusePreviewSeedWrites` blocks.
    private static func initialState(_ backend: RemindersBackend) -> AccessState {
        guard !PreviewSeed.isActive else { return .notRequested }
        return backend.authorization
    }

    /// Re-reads access after the user may have changed it in System Settings.
    /// Never prompts.
    func refreshAccessState() {
        let current = Self.initialState(backend)
        guard current != state else { return }
        state = current
        if current == .granted { lastError = nil }
    }

    func requestAccess() async -> Bool {
        // A seeded run must never even raise the TCC prompt: granting it would
        // arm `push` for every fabricated todo.
        if (try? Self.refusePreviewSeedWrites()) == nil {
            lastError = "Apple Reminders is disabled while running on sample data."
            return false
        }
        do {
            state = try await backend.requestAccess() ? .granted : .denied
            if state == .granted { lastError = nil }
            return state == .granted
        } catch {
            state = .denied
            lastError = error.localizedDescription
            return false
        }
    }

    func startObservingChanges() {
        guard !isObserving else { return }
        isObserving = true
        backend.startObservingChanges { [weak self] in
            self?.scheduleExternalChangeHandling()
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

    // MARK: - List management

    /// The lists the wizard can offer, with the disclosure a choice needs.
    func destinationCandidates(recordCount: Int, transmittedFields: [String])
        -> [SyncDestinationCandidate] {
        let lists = backend.lists.filter { $0.allowsContentModifications }
        return lists.map { list in
            SyncDestinationCandidate(
                calendarIdentifier: list.identifier,
                calendarTitle: list.title,
                sourceIdentifier: list.sourceIdentifier,
                sourceTitle: list.sourceTitle,
                sourceType: list.sourceType,
                isAppCreated: list.title == Self.medNotesListTitle,
                recordCount: recordCount,
                transmittedFields: transmittedFields,
                requiresCloudAcknowledgment: list.isCloud)
        }
        .sorted { $0.calendarTitle.localizedStandardCompare($1.calendarTitle) == .orderedAscending }
    }

    /// Sources that can actually hold a reminder list. Exchange and most
    /// CalDAV servers other than iCloud cannot, and those are filtered out
    /// rather than offered and then failing.
    func sourceCandidates() -> [(identifier: String, title: String, type: String, isCloud: Bool)] {
        backend.sources
            .filter { $0.type != "subscribed" && $0.type != "exchange" && $0.type != "birthdays" }
            .map { source in
                (source.identifier, source.title, source.type, source.isCloud)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Creates the `MedNotes` list in the explicitly chosen source.
    func createMedNotesList(inSource sourceIdentifier: String) throws -> SyncDestinationCandidate {
        let list: RemoteCalendar
        do {
            list = try backend.createList(title: Self.medNotesListTitle, inSource: sourceIdentifier)
        } catch EventKitBackendError.noSource {
            throw RemindersSyncError.noListSource
        } catch {
            throw RemindersSyncError.listCreateFailed(error.localizedDescription)
        }
        return SyncDestinationCandidate(
            calendarIdentifier: list.identifier,
            calendarTitle: list.title,
            sourceIdentifier: list.sourceIdentifier,
            sourceTitle: list.sourceTitle,
            sourceType: list.sourceType,
            isAppCreated: true,
            recordCount: 0,
            transmittedFields: [],
            requiresCloudAcknowledgment: list.isCloud)
    }

    /// Resolves a confirmed destination to the live list, or nil when it is
    /// gone. Never a title match.
    func list(for destination: SyncDestination) -> RemoteCalendar? {
        backend.list(withIdentifier: destination.calendarIdentifier)
    }

    // MARK: - Destination-bound push

    func push(_ todo: TodoItem, to destination: SyncDestination) async throws -> PushOutcome {
        try Self.refusePreviewSeedWrites()
        guard state == .granted else { throw RemindersSyncError.accessDenied }
        guard SyncDestinationCore.mayWrite(destination) else {
            throw RemindersSyncError.destinationNotConfirmed
        }
        guard let list = list(for: destination) else {
            throw RemindersSyncError.destinationMissing
        }
        var reminder: RemoteReminder?
        let identified = todo.reminderIdentifier.flatMap { backend.reminder(withIdentifier: $0) }
        let route = SyncDestinationCore.pushRoute(
            rowID: todo.id, destination: destination,
            found: identified.map {
                ($0.calendarID == destination.calendarIdentifier,
                 SyncDestinationCore.marker(from: $0.url),
                 SyncDestinationCore.recordID(from: $0.url))
            })
        if route == .movedElsewhere { return .movedElsewhere }
        if route == .useFound, let found = identified {
            reminder = found
        } else if let made = await reminderMade(from: todo.id, in: list, destination: destination) {
            // The todo lost the identifier of a reminder it already made: reuse
            // it, never make a second one.
            reminder = made
        }
        if let existing = reminder {
            let decision = ReminderSyncCore.pushDecision(
                local: todo, remote: existing.reminderFields(), remoteModified: existing.lastModified)
            if decision == .remoteNewer { return .remoteNewer }
            if decision == .unchanged, SyncDestinationCore.recordID(from: existing.url) == todo.id {
                return .pushed(syncedCopy(of: todo, from: existing, in: list))
            }
        }
        // The marker makes the reminder provably MedNotes-owned and names the
        // todo it was made from.
        let saved: RemoteReminder
        do {
            saved = try backend.save(
                todo.reminderFields(), completedAt: todo.completedAt, replacing: reminder, in: list,
                marker: SyncDestinationCore.markerURL(for: destination, record: todo.id))
        } catch {
            throw RemindersSyncError.saveFailed(error.localizedDescription)
        }
        return .pushed(syncedCopy(of: todo, from: saved, in: list))
    }

    private func syncedCopy(of todo: TodoItem, from reminder: RemoteReminder, in list: RemoteCalendar) -> TodoItem {
        var synced = todo
        synced.reminderIdentifier = reminder.identifier
        synced.reminderListIdentifier = list.identifier
        synced.syncStatus = .synced
        synced.lastSyncDate = Date()
        return synced
    }

    /// A reminder in the destination that MedNotes made from todo `id`, if any.
    private func reminderMade(from id: UUID, in list: RemoteCalendar, destination: SyncDestination) async -> RemoteReminder? {
        await backend.reminders(in: list).first { reminder in
            SyncDestinationCore.recordID(from: reminder.url) == id
                && SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: reminder.url),
                    destination: destination, inDestination: true)
        }
    }

    /// Removes the Apple reminder made from `todo`, if it can be found: by the
    /// identifier the todo stored, and when that finds nothing by the marker
    /// MedNotes put on it, which names this todo. Only a reminder in the
    /// destination that carries this app's marker is ever removed.
    ///
    /// Looking the reminder up by its marker suspends (EventKit's fetch), so the
    /// session can lock in the middle of it. `stillValid` is asked once the
    /// fetch is back and before anything is removed: when it says no, nothing
    /// is removed, because the row cannot be deleted under a lock and would
    /// keep an identifier that finds nothing.
    func deleteRemote(_ todo: TodoItem, from destination: SyncDestination,
                      stillValid: @MainActor () -> Bool = { true }) async throws {
        guard state == .granted else { return }
        var target: RemoteReminder?
        if let identifier = todo.reminderIdentifier,
           let item = backend.reminder(withIdentifier: identifier),
           item.calendarID == destination.calendarIdentifier,
           SyncDestinationCore.ownsRemoteObject(
            marker: SyncDestinationCore.marker(from: item.url),
            destination: destination,
            inDestination: true) {
            target = item
        } else if let list = list(for: destination) {
            target = await reminderMade(from: todo.id, in: list, destination: destination)
            guard stillValid() else { return }
        }
        guard let item = target else { return }
        do {
            try backend.remove(item)
        } catch {
            throw RemindersSyncError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: - Destination-bound pull

    /// One reconcile pass against the confirmed list. A local row whose
    /// remote reminder is gone or untagged is reported as a conflict, never a
    /// silent deletion; only MedNotes-marked objects are imported.
    func pull(
        localTodos: [TodoItem], from destination: SyncDestination,
        tombstones: Set<UUID> = []
    ) async throws -> PullResult {
        guard state == .granted else { throw RemindersSyncError.accessDenied }
        guard let list = list(for: destination) else {
            throw RemindersSyncError.destinationMissing
        }
        var result = PullResult()

        let byReminderID = Dictionary(localTodos.compactMap { todo -> (String, TodoItem)? in
            guard let id = todo.reminderIdentifier else { return nil }
            return (id, todo)
        }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(localTodos.map(\.id))

        // The list's reminders, read once: re-binding a lost identifier and
        // importing both need them.
        let listReminders = await backend.reminders(in: list)
        var madeFrom: [UUID: RemoteReminder] = [:]
        for reminder in listReminders {
            guard let record = SyncDestinationCore.recordID(from: reminder.url), madeFrom[record] == nil,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: reminder.url),
                    destination: destination, inDestination: true) else { continue }
            madeFrom[record] = reminder
        }
        // A todo that never stored its reminder's identifier has the
        // reminder but does not know it.
        for local in localTodos where local.reminderIdentifier == nil {
            if let made = madeFrom[local.id] { result.rebinds[local.id] = made.identifier }
        }

        for (identifier, local) in byReminderID {
            guard let reminder = backend.reminder(withIdentifier: identifier),
                  reminder.calendarID == destination.calendarIdentifier,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: reminder.url),
                    destination: destination,
                    inDestination: true) else {
                // Its identifier finds nothing, but the reminder it made is
                // there under another one: point the todo at it.
                if let made = madeFrom[local.id] {
                    result.rebinds[local.id] = made.identifier
                    continue
                }
                result.remoteMissing.append(local.id)
                continue
            }
            let remote = reminder.reminderFields()
            switch ReminderSyncCore.decide(local: local, remote: remote) {
            case .same:
                continue
            case .update(let conflict):
                var merged = local
                ReminderSyncCore.merging(remote: remote, into: &merged, completedAt: reminder.completionDate)
                merged.syncStatus = .synced
                merged.lastSyncDate = Date()
                if conflict { result.conflictingIDs.insert(local.id) }
                result.updates.append(merged)
            }
        }

        for reminder in listReminders {
            let identifier = reminder.identifier
            guard byReminderID[identifier] == nil else { continue }
            guard SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: reminder.url),
                destination: destination,
                inDestination: true) else { continue }
            // Made from a todo we have: not a new one, whatever identifier
            // EventKit gives it now. Made from one deleted here: left alone, not
            // brought back as a new todo with no patient.
            switch SyncDestinationCore.importDecision(
                recordID: SyncDestinationCore.recordID(from: reminder.url),
                localIDs: localIDs, tombstones: tombstones) {
            case .belongsToLocalRow: continue
            case .deletedHere:
                result.ignoredDeleted += 1
                continue
            case .importAsNew: break
            }
            let fields = reminder.reminderFields()
            let now = Date()
            result.creations.append(TodoItem(
                title: fields.title,
                isCompleted: fields.isCompleted,
                createdAt: reminder.creationDate ?? now,
                updatedAt: now,
                completedAt: fields.isCompleted ? (reminder.completionDate ?? now) : nil,
                priority: fields.priority,
                dueDate: fields.dueDay?.date(),
                notes: fields.notes.isEmpty ? nil : fields.notes,
                reminderIdentifier: identifier,
                reminderListIdentifier: reminder.calendarID,
                syncStatus: .synced,
                lastSyncDate: now))
        }
        return result
    }

    /// Structural containment for `--preview-seed` runs, at the EventKit
    /// boundary rather than at the call sites — the same third guard the
    /// calendar bridge has, so a regression of the two behavioural guards in
    /// `AppSession` becomes a thrown error in a debug build instead of
    /// fabricated todos in the user's real Reminders.
    private static func refusePreviewSeedWrites() throws {
        #if DEBUG
        if PreviewSeed.isActive { throw RemindersSyncError.previewSeedActive }
        #endif
    }

    enum RemindersSyncError: LocalizedError {
        case accessDenied
        case previewSeedActive
        case noListSource
        case listCreateFailed(String)
        case saveFailed(String)
        case destinationNotConfirmed
        case destinationMissing

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return String(localized: "Apple Reminders access was not granted.")
            case .previewSeedActive:
                return "Apple Reminders sync is disabled while running on sample data."
            case .noListSource:
                return String(localized: "No account is available to create the MedNotes reminders list.")
            case .listCreateFailed(let detail):
                return String(localized: "Could not create the MedNotes reminders list: \(detail)")
            case .saveFailed(let detail):
                return String(localized: "Reminders write failed: \(detail)")
            case .destinationNotConfirmed:
                return String(localized: "Choose and confirm a reminder list destination before syncing.")
            case .destinationMissing:
                return String(localized: "The chosen reminder list no longer exists. Reconnect in Settings \u{203a} Sync.")
            }
        }
    }
}

extension TodoItem {
    func reminderFields() -> ReminderFields {
        ReminderSyncCore.fields(of: self)
    }
}
