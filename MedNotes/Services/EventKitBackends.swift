import EventKit
import Foundation

// The only place MedNotes talks to EventKit.
//
// The two Apple services (`AppleCalendarService`, `AppleRemindersService`)
// decide what to push, pull, re-bind and delete. They do it against plain
// values and one of the two protocols below, so the decisions can run in a
// test against an in-memory fake. The two `EventKit…Backend` classes at the
// end of this file are the real thing: every EventKit call the services used
// to make lives there, moved without changing what is asked of EventKit.

// MARK: - Values

/// A calendar or a reminders list, as the services see it.
struct RemoteCalendar {
    var identifier: String
    var title: String
    var sourceIdentifier: String
    var sourceTitle: String
    /// "local", "calDAV", … (`EventKitSourceKind.typeName`).
    var sourceType: String
    var isCloud: Bool
    var allowsContentModifications: Bool
    /// What the backend needs to find the calendar again. Opaque to the services.
    var handle: AnyObject?
}

/// An account that can hold calendars or lists.
struct RemoteSource {
    var identifier: String
    var title: String
    var type: String
    var isCloud: Bool
}

/// An event as it stood when the backend returned it.
struct RemoteEvent {
    var identifier: String
    var calendarID: String?
    var url: URL?
    var title: String?
    var notes: String?
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var lastModified: Date?
    var creationDate: Date?
    /// The backend's own object, so a save or a removal acts on exactly the
    /// object that was read. Opaque to the services.
    var handle: AnyObject?

    func fields() -> EventFields {
        EventFields(
            title: SyncDestinationCore.titleFromRemote(title),
            notes: notes ?? "",
            startDate: startDate,
            endDate: endDate ?? (isAllDay ? startDate : startDate.addingTimeInterval(1800)),
            isAllDay: isAllDay)
    }
}

/// A reminder as it stood when the backend returned it.
struct RemoteReminder {
    var identifier: String
    var calendarID: String?
    var url: URL?
    var title: String?
    var notes: String?
    var dueDateComponents: DateComponents?
    var isCompleted: Bool
    var completionDate: Date?
    var priority: Int
    var lastModified: Date?
    var creationDate: Date?
    var handle: AnyObject?

    func reminderFields() -> ReminderFields {
        ReminderFields(
            title: SyncDestinationCore.titleFromRemote(title),
            notes: notes ?? "",
            dueDay: DueDay(components: dueDateComponents),
            isCompleted: isCompleted,
            priority: ReminderSyncCore.priority(fromReminder: priority))
    }
}

/// Why a backend call failed, when the failure is not EventKit's own error.
enum EventKitBackendError: LocalizedError {
    case noSource
    /// EventKit's own error text, carried unchanged.
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noSource: return nil
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Protocols

/// What `AppleCalendarService` needs from Apple Calendar.
@MainActor
protocol CalendarBackend: AnyObject {
    /// Where access stands with macOS. Never prompts.
    var authorization: SyncBridgeAccess { get }
    func requestAccess() async throws -> Bool
    /// Calls `handler` whenever the calendar database changes outside the app.
    func startObservingChanges(_ handler: @escaping @MainActor () -> Void)

    var calendars: [RemoteCalendar] { get }
    var sources: [RemoteSource] { get }
    func calendar(withIdentifier identifier: String) -> RemoteCalendar?
    func createCalendar(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar

    func event(withIdentifier identifier: String) -> RemoteEvent?
    /// The events of `calendar` that fall in `window`. EventKit stops at four years.
    func events(in window: DateInterval, calendar: RemoteCalendar) -> [RemoteEvent]
    /// Writes `fields` into `existing`, or into a new event, marks it with
    /// `marker`, saves it and returns it as it now stands.
    func save(_ fields: EventFields, replacing existing: RemoteEvent?,
              in calendar: RemoteCalendar, marker: URL) throws -> RemoteEvent
    func remove(_ event: RemoteEvent) throws
}

/// What `AppleRemindersService` needs from Apple Reminders.
@MainActor
protocol RemindersBackend: AnyObject {
    var authorization: SyncBridgeAccess { get }
    func requestAccess() async throws -> Bool
    func startObservingChanges(_ handler: @escaping @MainActor () -> Void)

    var lists: [RemoteCalendar] { get }
    var sources: [RemoteSource] { get }
    func list(withIdentifier identifier: String) -> RemoteCalendar?
    func createList(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar

    func reminder(withIdentifier identifier: String) -> RemoteReminder?
    /// Every reminder in `list`. It suspends, as EventKit's fetch does.
    func reminders(in list: RemoteCalendar) async -> [RemoteReminder]
    func save(_ fields: ReminderFields, completedAt: Date?, replacing existing: RemoteReminder?,
              in list: RemoteCalendar, marker: URL) throws -> RemoteReminder
    func remove(_ reminder: RemoteReminder) throws
}

// MARK: - EventKit

private enum EventKitSourceKind {
    static func typeName(_ type: EKSourceType?) -> String {
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

    static func isCloud(_ type: EKSourceType?) -> Bool {
        switch type {
        case .calDAV, .exchange, .mobileMe: return true
        default: return false
        }
    }

    static func access(for entity: EKEntityType) -> SyncBridgeAccess {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: return .granted
        case .denied, .restricted: return .denied
        default: return .notRequested
        }
    }

    static func calendar(_ calendar: EKCalendar) -> RemoteCalendar {
        RemoteCalendar(
            identifier: calendar.calendarIdentifier,
            title: calendar.title,
            sourceIdentifier: calendar.source?.sourceIdentifier ?? "",
            sourceTitle: calendar.source?.title ?? "",
            sourceType: typeName(calendar.source?.sourceType),
            isCloud: isCloud(calendar.source?.sourceType),
            allowsContentModifications: calendar.allowsContentModifications,
            handle: calendar)
    }

    static func sources(_ store: EKEventStore) -> [RemoteSource] {
        store.sources.map {
            RemoteSource(identifier: $0.sourceIdentifier, title: $0.title,
                         type: typeName($0.sourceType), isCloud: isCloud($0.sourceType))
        }
    }

    static func observe(_ store: EKEventStore, _ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
    }
}

/// Apple Calendar through `EKEventStore`.
@MainActor
final class EventKitCalendarBackend: CalendarBackend {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var authorization: SyncBridgeAccess { EventKitSourceKind.access(for: .event) }

    func requestAccess() async throws -> Bool {
        if #available(macOS 14.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
    }

    func startObservingChanges(_ handler: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = EventKitSourceKind.observe(store, handler)
    }

    var calendars: [RemoteCalendar] {
        store.calendars(for: .event).map(EventKitSourceKind.calendar)
    }

    var sources: [RemoteSource] { EventKitSourceKind.sources(store) }

    func calendar(withIdentifier identifier: String) -> RemoteCalendar? {
        store.calendar(withIdentifier: identifier).map(EventKitSourceKind.calendar)
    }

    func createCalendar(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceIdentifier }) else {
            throw EventKitBackendError.noSource
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        do {
            try store.saveCalendar(calendar, commit: true)
        } catch {
            throw EventKitBackendError.failed(error.localizedDescription)
        }
        return EventKitSourceKind.calendar(calendar)
    }

    func event(withIdentifier identifier: String) -> RemoteEvent? {
        (store.calendarItem(withIdentifier: identifier) as? EKEvent).map(Self.remote)
    }

    func events(in window: DateInterval, calendar: RemoteCalendar) -> [RemoteEvent] {
        guard let ekCalendar = calendar.handle as? EKCalendar else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [ekCalendar])
        return store.events(matching: predicate).map(Self.remote)
    }

    func save(_ fields: EventFields, replacing existing: RemoteEvent?,
              in calendar: RemoteCalendar, marker: URL) throws -> RemoteEvent {
        guard let ekCalendar = calendar.handle as? EKCalendar else {
            throw EventKitBackendError.failed("calendar")
        }
        let ek = (existing?.handle as? EKEvent) ?? EKEvent(eventStore: store)
        Self.apply(fields, to: ek)
        ek.calendar = ekCalendar
        // The marker is what makes the object provably MedNotes-owned without
        // reading its title, and names the row it was made from.
        ek.url = marker
        try store.save(ek, span: .thisEvent, commit: true)
        return Self.remote(ek)
    }

    func remove(_ event: RemoteEvent) throws {
        guard let ek = event.handle as? EKEvent else { throw EventKitBackendError.failed("event") }
        try store.remove(ek, span: .thisEvent, commit: true)
    }

    private static func remote(_ ek: EKEvent) -> RemoteEvent {
        RemoteEvent(
            identifier: ek.calendarItemIdentifier,
            calendarID: ek.calendar?.calendarIdentifier,
            url: ek.url,
            title: ek.title,
            notes: ek.notes,
            startDate: ek.startDate,
            endDate: ek.endDate,
            isAllDay: ek.isAllDay,
            lastModified: ek.lastModifiedDate,
            creationDate: ek.creationDate,
            handle: ek)
    }

    private static func apply(_ fields: EventFields, to ek: EKEvent) {
        ek.title = SyncDestinationCore.titleForRemote(fields.title)
        ek.notes = fields.notes
        ek.startDate = fields.startDate
        ek.endDate = fields.isAllDay
            ? max(fields.endDate, fields.startDate)
            : fields.endDate
        if ek.endDate < ek.startDate { ek.endDate = ek.startDate.addingTimeInterval(1800) }
        ek.isAllDay = fields.isAllDay
    }
}

/// Apple Reminders through `EKEventStore`.
@MainActor
final class EventKitRemindersBackend: RemindersBackend {
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var authorization: SyncBridgeAccess { EventKitSourceKind.access(for: .reminder) }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    func startObservingChanges(_ handler: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = EventKitSourceKind.observe(store, handler)
    }

    var lists: [RemoteCalendar] {
        store.calendars(for: .reminder).map(EventKitSourceKind.calendar)
    }

    var sources: [RemoteSource] { EventKitSourceKind.sources(store) }

    func list(withIdentifier identifier: String) -> RemoteCalendar? {
        store.calendar(withIdentifier: identifier).map(EventKitSourceKind.calendar)
    }

    func createList(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceIdentifier }) else {
            throw EventKitBackendError.noSource
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        list.source = source
        do {
            try store.saveCalendar(list, commit: true)
        } catch {
            throw EventKitBackendError.failed(error.localizedDescription)
        }
        return EventKitSourceKind.calendar(list)
    }

    func reminder(withIdentifier identifier: String) -> RemoteReminder? {
        (store.calendarItem(withIdentifier: identifier) as? EKReminder).map(Self.remote)
    }

    /// `fetchReminders` is completion-based and returns a cancellation token,
    /// so Swift generates no async twin for it.
    func reminders(in list: RemoteCalendar) async -> [RemoteReminder] {
        guard let ekList = list.handle as? EKCalendar else { return [] }
        let predicate = store.predicateForReminders(in: [ekList])
        let found: [EKReminder] = await withCheckedContinuation { continuation in
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }
        return found.map(Self.remote)
    }

    func save(_ fields: ReminderFields, completedAt: Date?, replacing existing: RemoteReminder?,
              in list: RemoteCalendar, marker: URL) throws -> RemoteReminder {
        guard let ekList = list.handle as? EKCalendar else {
            throw EventKitBackendError.failed("list")
        }
        let reminder = (existing?.handle as? EKReminder) ?? EKReminder(eventStore: store)
        Self.apply(fields, to: reminder, completedAt: completedAt)
        reminder.calendar = ekList
        // The marker makes the reminder provably MedNotes-owned and names the
        // todo it was made from.
        reminder.url = marker
        try store.save(reminder, commit: true)
        return Self.remote(reminder)
    }

    func remove(_ reminder: RemoteReminder) throws {
        guard let ek = reminder.handle as? EKReminder else { throw EventKitBackendError.failed("reminder") }
        try store.remove(ek, commit: true)
    }

    private static func remote(_ ek: EKReminder) -> RemoteReminder {
        RemoteReminder(
            identifier: ek.calendarItemIdentifier,
            calendarID: ek.calendar?.calendarIdentifier,
            url: ek.url,
            title: ek.title,
            notes: ek.notes,
            dueDateComponents: ek.dueDateComponents,
            isCompleted: ek.isCompleted,
            completionDate: ek.completionDate,
            priority: ek.priority,
            lastModified: ek.lastModifiedDate,
            creationDate: ek.creationDate,
            handle: ek)
    }

    private static func apply(_ fields: ReminderFields, to reminder: EKReminder, completedAt: Date?) {
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
}
