import Foundation
@testable import MedNotes

// In-memory stand-ins for Apple Calendar and Apple Reminders, behind the same
// protocols the real EventKit backends implement. They never touch EventKit,
// so a test can run the sync code with access "granted" and no test can reach
// the tester's real calendars.
//
// What they copy from EventKit, because the code under test depends on it:
// identifiers belong to the store and can change (`reidentify`); a date query
// silently stops at four years; a reminder fetch is asynchronous and returns
// the reminders as they were when it started; `lastModified` is stamped by the
// store when something is saved or edited.

/// Shared bookkeeping for the two fakes.
@MainActor
class FakeEventKitBase {
    /// Where the fake stands with macOS. A test session starts at
    /// `.notRequested`, as the real host does.
    var authorization: SyncBridgeAccess = .notRequested
    /// What `requestAccess` answers.
    var requestAccessAnswer = false
    /// The clock that stamps `lastModified` and `creationDate`.
    var now: () -> Date = { Date() }
    var sources = [RemoteSource(identifier: "source-1", title: "iCloud", type: "calDAV", isCloud: true)]
    private(set) var storedCalendars: [RemoteCalendar] = []
    var failNextSave = false
    var failNextRemove = false
    private(set) var changeHandler: (@MainActor () -> Void)?
    private var counter = 0

    func nextIdentifier(_ kind: String) -> String {
        counter += 1
        return "fake-\(kind)-\(counter)"
    }

    func requestAccess() async throws -> Bool {
        authorization = requestAccessAnswer ? .granted : .denied
        return requestAccessAnswer
    }

    func startObservingChanges(_ handler: @escaping @MainActor () -> Void) {
        changeHandler = handler
    }

    /// What EventKit does when something changes outside the app.
    func signalChange() { changeHandler?() }

    /// A calendar (or list) the user could pick as a destination.
    @discardableResult
    func addCalendar(identifier: String = "calendar-1", title: String = "MedNotes",
                     source: RemoteSource? = nil, allowsContentModifications: Bool = true) -> RemoteCalendar {
        let source = source ?? sources[0]
        let calendar = RemoteCalendar(
            identifier: identifier, title: title, sourceIdentifier: source.identifier,
            sourceTitle: source.title, sourceType: source.type, isCloud: source.isCloud,
            allowsContentModifications: allowsContentModifications, handle: nil)
        storedCalendars.append(calendar)
        return calendar
    }

    func findCalendar(_ identifier: String) -> RemoteCalendar? {
        storedCalendars.first { $0.identifier == identifier }
    }

    func makeCalendar(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar {
        guard let source = sources.first(where: { $0.identifier == sourceIdentifier }) else {
            throw EventKitBackendError.noSource
        }
        return addCalendar(identifier: nextIdentifier("calendar"), title: title, source: source)
    }

    func removeCalendar(_ identifier: String) {
        storedCalendars.removeAll { $0.identifier == identifier }
    }

    func checkSave() throws {
        if failNextSave {
            failNextSave = false
            throw EventKitBackendError.failed("the fake store refused the save")
        }
    }

    func checkRemove() throws {
        if failNextRemove {
            failNextRemove = false
            throw EventKitBackendError.failed("the fake store refused the removal")
        }
    }
}

@MainActor
final class FakeCalendarBackend: FakeEventKitBase, CalendarBackend {
    /// Longest span a date query reads; EventKit silently stops there.
    static let longestQuery: TimeInterval = 4 * 365 * 24 * 3600

    private var events: [String: RemoteEvent] = [:]
    /// Every window `events(in:calendar:)` was asked for, as asked.
    private(set) var queries: [DateInterval] = []
    /// What was saved and removed, in order.
    private(set) var saved: [RemoteEvent] = []
    private(set) var removedIdentifiers: [String] = []

    var calendars: [RemoteCalendar] { storedCalendars }

    func calendar(withIdentifier identifier: String) -> RemoteCalendar? { findCalendar(identifier) }

    func createCalendar(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar {
        try makeCalendar(title: title, inSource: sourceIdentifier)
    }

    func event(withIdentifier identifier: String) -> RemoteEvent? { events[identifier] }

    func events(in window: DateInterval, calendar: RemoteCalendar) -> [RemoteEvent] {
        queries.append(window)
        let end = min(window.end, window.start.addingTimeInterval(Self.longestQuery))
        return events.values
            .filter { $0.calendarID == calendar.identifier }
            .filter { event in
                let eventStart = event.start
                let eventEnd = max(event.endDate ?? eventStart, eventStart)
                if eventEnd == eventStart {
                    return eventStart >= window.start && eventStart < end
                }
                return eventStart < end && eventEnd > window.start
            }
            .sorted { $0.identifier < $1.identifier }
    }

    func save(_ fields: EventFields, replacing existing: RemoteEvent?,
              in calendar: RemoteCalendar, marker: URL) throws -> RemoteEvent {
        try checkSave()
        var event: RemoteEvent
        if let existing {
            guard let current = events[existing.identifier] else {
                throw EventKitBackendError.failed("the event no longer exists")
            }
            event = current
        } else {
            event = RemoteEvent(
                identifier: nextIdentifier("event"), calendarID: nil, url: nil, title: nil, notes: nil,
                startDate: fields.startDate, endDate: nil, isAllDay: false,
                lastModified: nil, creationDate: now(), handle: nil)
        }
        // The same field rules the real backend applies.
        event.title = SyncDestinationCore.titleForRemote(fields.title)
        event.notes = fields.notes
        event.startDate = fields.startDate
        event.endDate = fields.isAllDay ? max(fields.endDate, fields.startDate) : fields.endDate
        if let end = event.endDate, end < event.start { event.endDate = event.start.addingTimeInterval(1800) }
        event.isAllDay = fields.isAllDay
        event.calendarID = calendar.identifier
        event.url = marker
        event.lastModified = now()
        events[event.identifier] = event
        saved.append(event)
        return event
    }

    func remove(_ event: RemoteEvent) throws {
        try checkRemove()
        guard events.removeValue(forKey: event.identifier) != nil else {
            throw EventKitBackendError.failed("the event no longer exists")
        }
        removedIdentifiers.append(event.identifier)
    }

    // MARK: - What a test does to the store

    /// An event as another device or the Calendar app would have made it.
    @discardableResult
    func insert(title: String = "Clinic", start: Date, end: Date? = nil, isAllDay: Bool = false,
                calendar: RemoteCalendar, url: URL?) -> RemoteEvent {
        let event = RemoteEvent(
            identifier: nextIdentifier("event"), calendarID: calendar.identifier, url: url,
            title: title, notes: nil, startDate: start, endDate: end ?? start.addingTimeInterval(1800),
            isAllDay: isAllDay, lastModified: now(), creationDate: now(), handle: nil)
        events[event.identifier] = event
        return event
    }

    /// A full sync: the event keeps everything but its identifier, and the old
    /// identifier finds nothing.
    @discardableResult
    func reidentify(_ identifier: String) -> String {
        guard var event = events.removeValue(forKey: identifier) else { return identifier }
        event.identifier = nextIdentifier("event")
        events[event.identifier] = event
        return event.identifier
    }

    func move(_ identifier: String, to calendar: RemoteCalendar) {
        events[identifier]?.calendarID = calendar.identifier
    }

    /// An edit made in the Calendar app at `time` (default: now).
    func edit(_ identifier: String, at time: Date? = nil, _ change: (inout RemoteEvent) -> Void) {
        guard var event = events[identifier] else { return }
        change(&event)
        event.lastModified = time ?? now()
        events[identifier] = event
    }

    func contains(_ identifier: String) -> Bool { events[identifier] != nil }
    var allEvents: [RemoteEvent] { events.values.sorted { $0.identifier < $1.identifier } }
}

@MainActor
final class FakeRemindersBackend: FakeEventKitBase, RemindersBackend {
    private var reminders: [String: RemoteReminder] = [:]
    /// Runs inside every fetch, after its result was taken and before it
    /// returns: a test locks the session here, or edits the store.
    var fetchWillReturn: @MainActor () async -> Void = {}
    private(set) var fetchCount = 0
    private(set) var saved: [RemoteReminder] = []
    private(set) var removedIdentifiers: [String] = []

    var lists: [RemoteCalendar] { storedCalendars }

    func list(withIdentifier identifier: String) -> RemoteCalendar? { findCalendar(identifier) }

    func createList(title: String, inSource sourceIdentifier: String) throws -> RemoteCalendar {
        try makeCalendar(title: title, inSource: sourceIdentifier)
    }

    func reminder(withIdentifier identifier: String) -> RemoteReminder? { reminders[identifier] }

    func reminders(in list: RemoteCalendar) async -> [RemoteReminder] {
        fetchCount += 1
        let snapshot = reminders.values
            .filter { $0.calendarID == list.identifier }
            .sorted { $0.identifier < $1.identifier }
        await fetchWillReturn()
        return snapshot
    }

    func save(_ fields: ReminderFields, completedAt: Date?, replacing existing: RemoteReminder?,
              in list: RemoteCalendar, marker: URL) throws -> RemoteReminder {
        try checkSave()
        var reminder: RemoteReminder
        if let existing {
            guard let current = reminders[existing.identifier] else {
                throw EventKitBackendError.failed("the reminder no longer exists")
            }
            reminder = current
        } else {
            reminder = RemoteReminder(
                identifier: nextIdentifier("reminder"), calendarID: nil, url: nil, title: nil, notes: nil,
                dueDateComponents: nil, isCompleted: false, completionDate: nil, priority: 0,
                lastModified: nil, creationDate: now(), handle: nil)
        }
        reminder.title = SyncDestinationCore.titleForRemote(fields.title)
        reminder.notes = fields.notes.isEmpty ? nil : fields.notes
        reminder.dueDateComponents = fields.dueDay?.components
        reminder.priority = ReminderSyncCore.reminderPriority(fields.priority)
        if reminder.isCompleted != fields.isCompleted {
            reminder.completionDate = fields.isCompleted ? (completedAt ?? now()) : nil
            reminder.isCompleted = fields.isCompleted
        }
        reminder.calendarID = list.identifier
        reminder.url = marker
        reminder.lastModified = now()
        reminders[reminder.identifier] = reminder
        saved.append(reminder)
        return reminder
    }

    func remove(_ reminder: RemoteReminder) throws {
        try checkRemove()
        guard reminders.removeValue(forKey: reminder.identifier) != nil else {
            throw EventKitBackendError.failed("the reminder no longer exists")
        }
        removedIdentifiers.append(reminder.identifier)
    }

    // MARK: - What a test does to the store

    @discardableResult
    func insert(title: String = "Chase labs", list: RemoteCalendar, url: URL?) -> RemoteReminder {
        let reminder = RemoteReminder(
            identifier: nextIdentifier("reminder"), calendarID: list.identifier, url: url, title: title,
            notes: nil, dueDateComponents: nil, isCompleted: false, completionDate: nil, priority: 0,
            lastModified: now(), creationDate: now(), handle: nil)
        reminders[reminder.identifier] = reminder
        return reminder
    }

    @discardableResult
    func reidentify(_ identifier: String) -> String {
        guard var reminder = reminders.removeValue(forKey: identifier) else { return identifier }
        reminder.identifier = nextIdentifier("reminder")
        reminders[reminder.identifier] = reminder
        return reminder.identifier
    }

    func edit(_ identifier: String, at time: Date? = nil, _ change: (inout RemoteReminder) -> Void) {
        guard var reminder = reminders[identifier] else { return }
        change(&reminder)
        reminder.lastModified = time ?? now()
        reminders[identifier] = reminder
    }

    func contains(_ identifier: String) -> Bool { reminders[identifier] != nil }
    var allReminders: [RemoteReminder] { reminders.values.sorted { $0.identifier < $1.identifier } }
}
