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
    enum PullDecision: Equatable {
        case same
        case update(conflict: Bool)
    }

    /// Same direction rule as `CalendarSyncCore.decide`: EventKit exposes no
    /// per-item "modified at", so a differing remote copy wins when the local
    /// row is clean (never synced, or last synced after its last local edit).
    /// If the local row has unsynced edits AND remote drifted too, that is a
    /// conflict — remote wins and the caller surfaces a warning.
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

/// Owns the `EKEventStore` connection to Apple Reminders. Pushes MedNotes
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
    }

    @Published private(set) var state: AccessState
    @Published private(set) var lastError: String?
    @Published var hasPendingExternalChanges = false

    nonisolated static let medNotesListTitle = "MedNotes"

    private let store = EKEventStore()
    private var changeTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        state = Self.initialState()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether macOS has already granted this app full Reminders access. A
    /// class-level query that never prompts, so automatic sync passes can
    /// consult it without raising the permission dialog.
    nonisolated static var hasFullAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// The pill should be truthful from launch: access granted in an earlier
    /// run is still granted. Sample-data runs stay "not connected" whatever
    /// TCC says, so the pill never advertises a bridge that
    /// `refusePreviewSeedWrites` blocks.
    private static func initialState() -> AccessState {
        guard !PreviewSeed.isActive else { return .notRequested }
        switch EKEventStore.authorizationStatus(for: .reminder) {
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

    func requestAccess() async -> Bool {
        // A seeded run must never even raise the TCC prompt: granting it would
        // arm `push` for every fabricated todo.
        if (try? Self.refusePreviewSeedWrites()) == nil {
            lastError = "Apple Reminders is disabled while running on sample data."
            return false
        }
        do {
            state = try await store.requestFullAccessToReminders() ? .granted : .denied
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

    // MARK: - List management

    /// The lists the wizard can offer, with the disclosure a choice needs.
    func destinationCandidates(recordCount: Int, transmittedFields: [String])
        -> [SyncDestinationCandidate] {
        let lists = store.calendars(for: .reminder).filter { $0.allowsContentModifications }
        return lists.map { list in
            SyncDestinationCandidate(
                calendarIdentifier: list.calendarIdentifier,
                calendarTitle: list.title,
                sourceIdentifier: list.source?.sourceIdentifier ?? "",
                sourceTitle: list.source?.title ?? "",
                sourceType: Self.sourceTypeName(list.source?.sourceType),
                isAppCreated: list.title == Self.medNotesListTitle,
                recordCount: recordCount,
                transmittedFields: transmittedFields,
                requiresCloudAcknowledgment: Self.isCloudSource(list.source?.sourceType))
        }
        .sorted { $0.calendarTitle.localizedStandardCompare($1.calendarTitle) == .orderedAscending }
    }

    /// Sources that can actually hold a reminder list. Exchange and most
    /// CalDAV servers other than iCloud cannot, and those are filtered out
    /// rather than offered and then failing.
    func sourceCandidates() -> [(identifier: String, title: String, type: String, isCloud: Bool)] {
        store.sources
            .filter { $0.sourceType != .subscribed && $0.sourceType != .exchange && $0.sourceType != .birthdays }
            .map { source in
                (source.sourceIdentifier, source.title, Self.sourceTypeName(source.sourceType),
                 Self.isCloudSource(source.sourceType))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Creates the `MedNotes` list in the explicitly chosen source.
    func createMedNotesList(inSource sourceIdentifier: String) throws -> SyncDestinationCandidate {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceIdentifier }) else {
            throw RemindersSyncError.noListSource
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = Self.medNotesListTitle
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw RemindersSyncError.listCreateFailed(error.localizedDescription)
        }
        return SyncDestinationCandidate(
            calendarIdentifier: list.calendarIdentifier,
            calendarTitle: list.title,
            sourceIdentifier: source.sourceIdentifier,
            sourceTitle: source.title,
            sourceType: Self.sourceTypeName(source.sourceType),
            isAppCreated: true,
            recordCount: 0,
            transmittedFields: [],
            requiresCloudAcknowledgment: Self.isCloudSource(source.sourceType))
    }

    /// Resolves a confirmed destination to the live list, or nil when it is
    /// gone. Never a title match.
    func list(for destination: SyncDestination) -> EKCalendar? {
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

    func push(_ todo: TodoItem, to destination: SyncDestination) async throws -> TodoItem {
        try Self.refusePreviewSeedWrites()
        guard state == .granted else { throw RemindersSyncError.accessDenied }
        guard SyncDestinationCore.mayWrite(destination) else {
            throw RemindersSyncError.destinationNotConfirmed
        }
        guard let list = list(for: destination) else {
            throw RemindersSyncError.destinationMissing
        }
        let reminder: EKReminder
        if let identifier = todo.reminderIdentifier,
           let found = store.calendarItem(withIdentifier: identifier) as? EKReminder,
           found.calendar?.calendarIdentifier == destination.calendarIdentifier {
            reminder = found
        } else {
            reminder = EKReminder(eventStore: store)
        }
        apply(todo.reminderFields(), to: reminder, completedAt: todo.completedAt)
        reminder.calendar = list
        reminder.url = SyncDestinationCore.markerURL(for: destination)
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw RemindersSyncError.saveFailed(error.localizedDescription)
        }
        var synced = todo
        synced.reminderIdentifier = reminder.calendarItemIdentifier
        synced.reminderListIdentifier = list.calendarIdentifier
        synced.syncStatus = .synced
        synced.lastSyncDate = Date()
        return synced
    }

    func deleteRemote(_ todo: TodoItem, from destination: SyncDestination) async throws {
        guard state == .granted,
              let identifier = todo.reminderIdentifier,
              let item = store.calendarItem(withIdentifier: identifier) as? EKReminder,
              item.calendar?.calendarIdentifier == destination.calendarIdentifier,
              SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: item.url),
                destination: destination,
                inDestination: true) else {
            return
        }
        do {
            try store.remove(item, commit: true)
        } catch {
            throw RemindersSyncError.saveFailed(error.localizedDescription)
        }
    }

    private func apply(_ fields: ReminderFields, to reminder: EKReminder, completedAt: Date?) {
        reminder.title = SyncDestinationCore.titleForRemote(fields.title)
        reminder.notes = fields.notes.isEmpty ? nil : fields.notes
        if let day = fields.dueDay {
            // Same day: leave the reminder's own components alone, including
            // any time the user set in the Reminders app. New day: date-only,
            // which is all MedNotes means by a due date, so a timed alarm
            // left over from the old day goes too.
            if DueDay(components: reminder.dueDateComponents) != day {
                reminder.dueDateComponents = day.components
                reminder.alarms?.forEach(reminder.removeAlarm)
            }
        } else if reminder.dueDateComponents != nil {
            reminder.dueDateComponents = nil
            reminder.alarms?.forEach(reminder.removeAlarm)
        }
        if ReminderSyncCore.priority(fromReminder: reminder.priority) != fields.priority {
            reminder.priority = ReminderSyncCore.reminderPriority(fields.priority)
        }
        if reminder.isCompleted != fields.isCompleted {
            // completionDate drives isCompleted in EventKit: a date completes
            // the reminder, nil reopens it.
            reminder.completionDate = fields.isCompleted ? (completedAt ?? Date()) : nil
        }
    }

    // MARK: - Destination-bound pull

    /// One reconcile pass against the confirmed list. A local row whose
    /// remote reminder is gone or untagged is reported as a conflict, never a
    /// silent deletion; only MedNotes-marked objects are imported.
    func pull(localTodos: [TodoItem], from destination: SyncDestination) async throws -> PullResult {
        guard state == .granted else { throw RemindersSyncError.accessDenied }
        guard let list = list(for: destination) else {
            throw RemindersSyncError.destinationMissing
        }
        var result = PullResult()

        let byReminderID = Dictionary(localTodos.compactMap { todo -> (String, TodoItem)? in
            guard let id = todo.reminderIdentifier else { return nil }
            return (id, todo)
        }, uniquingKeysWith: { first, _ in first })

        for (identifier, local) in byReminderID {
            guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder,
                  reminder.calendar?.calendarIdentifier == destination.calendarIdentifier,
                  SyncDestinationCore.ownsRemoteObject(
                    marker: SyncDestinationCore.marker(from: reminder.url),
                    destination: destination,
                    inDestination: true) else {
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

        for reminder in await fetchReminders(matching: store.predicateForReminders(in: [list])) {
            let identifier = reminder.calendarItemIdentifier
            guard byReminderID[identifier] == nil else { continue }
            guard SyncDestinationCore.ownsRemoteObject(
                marker: SyncDestinationCore.marker(from: reminder.url),
                destination: destination,
                inDestination: true) else { continue }
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
                reminderListIdentifier: reminder.calendar?.calendarIdentifier,
                syncStatus: .synced,
                lastSyncDate: now))
        }
        return result
    }

    /// `fetchReminders` is completion-based and returns a cancellation token,
    /// so Swift generates no async twin for it.
    private func fetchReminders(matching predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
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

extension EKReminder {
    func reminderFields() -> ReminderFields {
        ReminderFields(
            title: SyncDestinationCore.titleFromRemote(title),
            notes: notes ?? "",
            dueDay: DueDay(components: dueDateComponents),
            isCompleted: isCompleted,
            priority: ReminderSyncCore.priority(fromReminder: priority))
    }
}

extension TodoItem {
    func reminderFields() -> ReminderFields {
        ReminderSyncCore.fields(of: self)
    }
}
