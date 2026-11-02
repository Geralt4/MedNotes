import XCTest
@testable import MedNotes

/// The Apple side of sync, run against the in-memory backends in
/// `FakeEventKit.swift`: the services' own decisions (what is re-linked, what
/// is deleted, which window is asked about), and what a session does around
/// them. The real EventKit backends are not covered here; only a real account
/// exercises those.
@MainActor
final class AppleSyncFakeTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.AppleSyncFake"
    private var roots: [DataRoot] = []

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private let day: TimeInterval = 24 * 3600

    // MARK: - Service-level fixtures

    private struct CalendarFixture {
        let backend: FakeCalendarBackend
        let calendar: RemoteCalendar
        let destination: SyncDestination
        let service: AppleCalendarService

        func marker(for row: CalendarEvent) -> URL {
            SyncDestinationCore.markerURL(for: destination, record: row.id)
        }
    }

    private func makeCalendar() -> CalendarFixture {
        let backend = FakeCalendarBackend()
        backend.authorization = .granted
        let calendar = backend.addCalendar()
        let destination = SyncDestination(
            bridgeType: .calendar, calendarIdentifier: calendar.identifier, calendarTitle: calendar.title,
            sourceIdentifier: "source-1", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
        return CalendarFixture(backend: backend, calendar: calendar, destination: destination,
                               service: AppleCalendarService(backend: backend))
    }

    private struct RemindersFixture {
        let backend: FakeRemindersBackend
        let list: RemoteCalendar
        let destination: SyncDestination
        let service: AppleRemindersService
    }

    private func makeReminders() -> RemindersFixture {
        let backend = FakeRemindersBackend()
        backend.authorization = .granted
        let list = backend.addCalendar()
        let destination = SyncDestination(
            bridgeType: .reminders, calendarIdentifier: list.identifier, calendarTitle: list.title,
            sourceIdentifier: "source-1", sourceTitle: "iCloud", sourceType: "calDAV",
            appCreated: true, consentAt: Date(), confirmedAt: Date(), needsReconnection: false)
        return RemindersFixture(backend: backend, list: list, destination: destination,
                                service: AppleRemindersService(backend: backend))
    }

    // MARK: - Calendar events more than a year away

    /// A row two years out whose Apple object got another identifier: the pull
    /// points the row at it. Not "missing", and not imported as a new event.
    func testAFarEventWhoseIdentifierChangedIsReboundOnPull() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(730 * day)
        var row = CalendarEvent(title: "Far", startDate: start, endDate: start.addingTimeInterval(3600))
        row.syncStatus = .synced
        row.lastSyncDate = Date()
        let object = f.backend.insert(title: "Far", start: start, end: start.addingTimeInterval(3600),
                                      calendar: f.calendar, url: f.marker(for: row))
        row.ekEventIdentifier = "an-identifier-that-no-longer-exists"

        let result = try await f.service.pull(localEvents: [row], from: f.destination)

        XCTAssertEqual(result.rebinds[row.id], object.identifier)
        XCTAssertTrue(result.remoteMissing.isEmpty, "reported missing: \(result.remoteMissing)")
        XCTAssertTrue(result.creations.isEmpty, "a far object must only re-bind, never be imported")
    }

    /// What the far windows find is used to re-bind a row, and nothing else:
    /// another MedNotes object out there that no row owns is not imported.
    func testObjectsFoundOnlyInAFarWindowAreNeverImported() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(730 * day)
        let row = CalendarEvent(title: "Far", startDate: start, endDate: start.addingTimeInterval(3600),
                                ekEventIdentifier: "gone")
        let object = f.backend.insert(title: "Far", start: start, calendar: f.calendar, url: f.marker(for: row))
        let strangerRecord = UUID()
        f.backend.insert(title: "Made on another Mac", start: start, calendar: f.calendar,
                         url: SyncDestinationCore.markerURL(for: f.destination, record: strangerRecord))

        let result = try await f.service.pull(localEvents: [row], from: f.destination)

        XCTAssertEqual(result.rebinds, [row.id: object.identifier])
        XCTAssertTrue(result.creations.isEmpty, "imported: \(result.creations.map(\.title))")
    }

    /// A row that lost its identifier is pushed onto the object it already
    /// made, two years out as anywhere: never a second one.
    func testPushingAFarEventThatLostItsIdentifierReusesItsObject() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(730 * day)
        let row = CalendarEvent(title: "Far (edited)", startDate: start, endDate: start.addingTimeInterval(3600))
        let object = f.backend.insert(title: "Far", start: start, end: start.addingTimeInterval(3600),
                                      calendar: f.calendar, url: f.marker(for: row))

        let outcome = try await f.service.push(row, to: f.destination)

        guard case .pushed(let synced) = outcome else { return XCTFail("not pushed: \(outcome)") }
        XCTAssertEqual(synced.ekEventIdentifier, object.identifier)
        XCTAssertEqual(f.backend.allEvents.count, 1, "a second object was made")
        XCTAssertEqual(f.backend.saved.last?.identifier, object.identifier)
        XCTAssertEqual(f.backend.event(withIdentifier: object.identifier)?.title, "Far (edited)")
    }

    /// Deleting such a row removes the Apple copy, found by its marker.
    func testDeletingAFarEventThatLostItsIdentifierRemovesItsObject() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(730 * day)
        var row = CalendarEvent(title: "Far", startDate: start, endDate: start.addingTimeInterval(3600))
        let object = f.backend.insert(title: "Far", start: start, calendar: f.calendar, url: f.marker(for: row))
        row.ekEventIdentifier = "gone"

        try await f.service.deleteRemote(row, from: f.destination)

        XCTAssertEqual(f.backend.removedIdentifiers, [object.identifier])
        XCTAssertFalse(f.backend.contains(object.identifier))
    }

    /// Only an object carrying this destination's marker is ever removed.
    func testDeletingARowNeverRemovesAnUnmarkedEvent() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(730 * day)
        let row = CalendarEvent(title: "Far", startDate: start, endDate: start.addingTimeInterval(3600),
                                ekEventIdentifier: "gone")
        let foreign = f.backend.insert(title: "Far", start: start, calendar: f.calendar, url: nil)

        try await f.service.deleteRemote(row, from: f.destination)

        XCTAssertTrue(f.backend.contains(foreign.identifier))
        XCTAssertTrue(f.backend.removedIdentifiers.isEmpty)
    }

    /// An event of five years is asked about in pieces EventKit does not cut
    /// short, and its object is found.
    func testALongEventIsLookedUpInPiecesEventKitAnswersInFull() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(400 * day)
        let end = start.addingTimeInterval(5 * 365 * day)
        var row = CalendarEvent(title: "Sabbatical", startDate: start, endDate: end)
        let object = f.backend.insert(title: "Sabbatical", start: start, end: end,
                                      calendar: f.calendar, url: f.marker(for: row))
        row.ekEventIdentifier = "gone"

        let result = try await f.service.pull(localEvents: [row], from: f.destination)

        XCTAssertEqual(result.rebinds[row.id], object.identifier)
        XCTAssertTrue(f.backend.queries.allSatisfy { $0.duration <= FakeCalendarBackend.longestQuery },
                      "a window longer than EventKit reads was asked for: \(f.backend.queries.map(\.duration))")
        XCTAssertGreaterThan(f.backend.queries.count, 2, "the long span was asked for in pieces")
    }

    /// A date far in the future must not cost a query per few years to the end
    /// of time.
    func testAnEndDateInTheYear9999IsLookedUpInAtMostTheWindowCap() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(1000 * day)
        let end = Date(timeIntervalSince1970: 253_370_764_800)   // 9999-12-31
        let row = CalendarEvent(title: "Forever", startDate: start, endDate: end, ekEventIdentifier: "gone")

        _ = try await f.service.pull(localEvents: [row], from: f.destination)

        // The year around now, and at most 24 windows beyond it (written out
        // here, not read from the constants the code under test uses).
        XCTAssertLessThanOrEqual(f.backend.queries.count, 25)
        // And nothing past about 25 years beyond the year around today.
        let horizon = Date().addingTimeInterval(27 * 366 * day)
        XCTAssertTrue(f.backend.queries.allSatisfy { $0.end <= horizon }, "a window went past the horizon")
    }

    /// A row inside the year every pass reads adds no query of its own.
    func testAnEventInsideTheYearAroundTodayAddsNoFarQuery() async throws {
        let f = makeCalendar()
        let start = Date().addingTimeInterval(30 * day)
        var row = CalendarEvent(title: "Soon", startDate: start, endDate: start.addingTimeInterval(3600))
        let object = f.backend.insert(title: "Soon", start: start, end: start.addingTimeInterval(3600),
                                      calendar: f.calendar, url: f.marker(for: row))
        row.ekEventIdentifier = "gone"

        let result = try await f.service.pull(localEvents: [row], from: f.destination)

        XCTAssertEqual(result.rebinds[row.id], object.identifier)
        XCTAssertEqual(f.backend.queries.count, 1, "only the window every pass reads")
    }

    // MARK: - The conflict rule, end to end

    private func calendarEditedInAppleAfterTheLastSync(by seconds: TimeInterval) async throws
        -> (outcome: AppleCalendarService.PushOutcome, fixture: CalendarFixture, identifier: String) {
        let f = makeCalendar()
        let row = CalendarEvent(title: "Visit")
        guard case .pushed(let synced) = try await f.service.push(row, to: f.destination),
              let identifier = synced.ekEventIdentifier, let syncedAt = synced.lastSyncDate else {
            throw XCTSkip("the first push failed")
        }
        f.backend.edit(identifier, at: syncedAt.addingTimeInterval(seconds)) { $0.title = "Apple edit" }
        var local = synced
        local.title = "Local edit"
        local.updatedAt = syncedAt.addingTimeInterval(1)
        let outcome = try await f.service.push(local, to: f.destination)
        return (outcome, f, identifier)
    }

    func testACalendarEditInsideTheToleranceDoesNotCountAsNewer() async throws {
        let (outcome, f, identifier) = try await calendarEditedInAppleAfterTheLastSync(by: 30)
        guard case .pushed = outcome else { return XCTFail("expected the local edit to be pushed: \(outcome)") }
        XCTAssertEqual(f.backend.event(withIdentifier: identifier)?.title, "Local edit")
    }

    func testACalendarEditClearlyAfterTheLastSyncIsKept() async throws {
        let (outcome, f, identifier) = try await calendarEditedInAppleAfterTheLastSync(by: 90)
        guard case .remoteNewer = outcome else { return XCTFail("expected remoteNewer: \(outcome)") }
        XCTAssertEqual(f.backend.event(withIdentifier: identifier)?.title, "Apple edit", "the Apple edit was overwritten")
    }

    private func reminderEditedInAppleAfterTheLastSync(by seconds: TimeInterval) async throws
        -> (outcome: AppleRemindersService.PushOutcome, fixture: RemindersFixture, identifier: String) {
        let f = makeReminders()
        let todo = TodoItem(title: "Chase labs")
        guard case .pushed(let synced) = try await f.service.push(todo, to: f.destination),
              let identifier = synced.reminderIdentifier, let syncedAt = synced.lastSyncDate else {
            throw XCTSkip("the first push failed")
        }
        f.backend.edit(identifier, at: syncedAt.addingTimeInterval(seconds)) { $0.title = "Apple edit" }
        var local = synced
        local.title = "Local edit"
        local.updatedAt = syncedAt.addingTimeInterval(1)
        let outcome = try await f.service.push(local, to: f.destination)
        return (outcome, f, identifier)
    }

    func testAReminderEditInsideTheToleranceDoesNotCountAsNewer() async throws {
        let (outcome, f, identifier) = try await reminderEditedInAppleAfterTheLastSync(by: 30)
        guard case .pushed = outcome else { return XCTFail("expected the local edit to be pushed: \(outcome)") }
        XCTAssertEqual(f.backend.reminder(withIdentifier: identifier)?.title, "Local edit")
    }

    func testAReminderEditClearlyAfterTheLastSyncIsKept() async throws {
        let (outcome, f, identifier) = try await reminderEditedInAppleAfterTheLastSync(by: 90)
        guard case .remoteNewer = outcome else { return XCTFail("expected remoteNewer: \(outcome)") }
        XCTAssertEqual(f.backend.reminder(withIdentifier: identifier)?.title, "Apple edit", "the Apple edit was overwritten")
    }

    // MARK: - Deleting a linked row from a session

    private func makeSession(calendar: FakeCalendarBackend, reminders: FakeRemindersBackend) async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName),
            calendar: calendar, reminders: reminders)
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    private func confirm(_ session: AppSession, bridge: SyncBridgeType, in calendar: RemoteCalendar) async throws -> SyncDestination {
        let store = try XCTUnwrap(session.store)
        return try await store.destinations.confirm(bridge: bridge, candidate: SyncDestinationCandidate(
            calendarIdentifier: calendar.identifier, calendarTitle: calendar.title,
            sourceIdentifier: calendar.sourceIdentifier, sourceTitle: calendar.sourceTitle,
            sourceType: calendar.sourceType, isAppCreated: true, recordCount: 0,
            transmittedFields: [], requiresCloudAcknowledgment: false))
    }

    private struct CalendarSession {
        let session: AppSession
        let backend: FakeCalendarBackend
        let event: CalendarEvent
        let object: RemoteEvent
    }

    /// A session with Calendar access, a confirmed destination and one linked
    /// event whose Apple object is in the fake.
    private func sessionWithALinkedEvent(linked: Bool = true) async throws -> CalendarSession {
        let backend = FakeCalendarBackend()
        backend.authorization = .granted
        let calendar = backend.addCalendar()
        let session = try await makeSession(calendar: backend, reminders: FakeRemindersBackend())
        session.selectedModule = .calendar
        let destination = try await confirm(session, bridge: .calendar, in: calendar)
        var event = CalendarEvent(title: "Clinic")
        let object = backend.insert(title: "Clinic", start: event.startDate, end: event.endDate, calendar: calendar,
                                    url: SyncDestinationCore.markerURL(for: destination, record: event.id))
        if linked {
            event.ekEventIdentifier = object.identifier
            event.syncStatus = .synced
            event.lastSyncDate = Date()
        }
        try await XCTUnwrap(session.store).events.save(event)
        return CalendarSession(session: session, backend: backend, event: event, object: object)
    }

    func testDeletingALinkedEventRemovesTheAppleCopyAndThenTheRow() async throws {
        let s = try await sessionWithALinkedEvent()

        await s.session.deleteEvent(id: s.event.id)

        XCTAssertEqual(s.backend.removedIdentifiers, [s.object.identifier])
        let gone = try await XCTUnwrap(s.session.store).events.load(id: s.event.id)
        XCTAssertNil(gone)
        XCTAssertNil(s.session.errorMessage)
    }

    /// The Apple copy was found by the marker because the identifier changed.
    func testDeletingALinkedEventWhoseIdentifierChangedRemovesTheCopyByItsMarker() async throws {
        let s = try await sessionWithALinkedEvent()
        s.backend.reidentify(s.object.identifier)

        await s.session.deleteEvent(id: s.event.id)

        XCTAssertEqual(s.backend.removedIdentifiers.count, 1)
        XCTAssertTrue(s.backend.allEvents.isEmpty)
        let gone = try await XCTUnwrap(s.session.store).events.load(id: s.event.id)
        XCTAssertNil(gone)
    }

    /// The Apple copy is already gone: the row is still deleted.
    func testDeletingALinkedEventWhoseAppleCopyIsGoneStillDeletesTheRow() async throws {
        let s = try await sessionWithALinkedEvent()
        try s.backend.remove(s.object)

        await s.session.deleteEvent(id: s.event.id)

        let gone = try await XCTUnwrap(s.session.store).events.load(id: s.event.id)
        XCTAssertNil(gone)
        XCTAssertNil(s.session.errorMessage)
    }

    /// A lock that lands after the destination was read must stop the delete
    /// before the Apple copy goes. This is the check in front of `deleteRemote`
    /// on its own: with it removed, the fake records a removal.
    func testALockBeforeTheAppleRemovalLeavesTheAppleEventAndTheRow() async throws {
        let s = try await sessionWithALinkedEvent()
        s.session.eventRemovalDidLookUpDestination = { [unowned session = s.session] in
            session.eventRemovalDidLookUpDestination = {}
            await session.lockNow(reason: "idle")
        }

        await s.session.deleteEvent(id: s.event.id)

        XCTAssertTrue(s.backend.contains(s.object.identifier), "the Apple copy was removed under a lock")
        XCTAssertTrue(s.backend.removedIdentifiers.isEmpty)
        XCTAssertNil(s.session.errorMessage)
        await s.session.unlock()
        let kept = try await XCTUnwrap(s.session.store, "unlock failed: \(s.session.initError ?? "")")
            .events.load(id: s.event.id)
        XCTAssertEqual(kept?.ekEventIdentifier, s.object.identifier)
    }

    /// A removal Apple refuses keeps the row and says so.
    func testAnAppleRemovalThatFailsKeepsTheEventAndReportsIt() async throws {
        let s = try await sessionWithALinkedEvent()
        s.backend.failNextRemove = true

        await s.session.deleteEvent(id: s.event.id)

        XCTAssertNotNil(s.session.errorMessage)
        let kept = try await XCTUnwrap(s.session.store).events.load(id: s.event.id)
        XCTAssertNotNil(kept)
        XCTAssertTrue(s.backend.contains(s.object.identifier))
    }

    private struct RemindersSession {
        let session: AppSession
        let backend: FakeRemindersBackend
        let todo: TodoItem
        let object: RemoteReminder
    }

    private func sessionWithALinkedTodo() async throws -> RemindersSession {
        let backend = FakeRemindersBackend()
        backend.authorization = .granted
        let list = backend.addCalendar()
        let session = try await makeSession(calendar: FakeCalendarBackend(), reminders: backend)
        session.selectedModule = .todos
        let destination = try await confirm(session, bridge: .reminders, in: list)
        var todo = TodoItem(title: "Chase labs")
        let object = backend.insert(title: "Chase labs", list: list,
                                    url: SyncDestinationCore.markerURL(for: destination, record: todo.id))
        todo.reminderIdentifier = object.identifier
        todo.syncStatus = .synced
        todo.lastSyncDate = Date()
        try await XCTUnwrap(session.store).todos.save(todo)
        return RemindersSession(session: session, backend: backend, todo: todo, object: object)
    }

    func testDeletingALinkedTodoRemovesTheAppleReminderAndThenTheRow() async throws {
        let s = try await sessionWithALinkedTodo()

        await s.session.deleteTodo(id: s.todo.id)

        XCTAssertEqual(s.backend.removedIdentifiers, [s.object.identifier])
        let gone = try await XCTUnwrap(s.session.store).todos.load(id: s.todo.id)
        XCTAssertNil(gone)
        XCTAssertNil(s.session.errorMessage)
    }

    /// The identifier changed, so the reminder is found by its marker: the
    /// path that fetches the whole list first.
    func testDeletingALinkedTodoWhoseIdentifierChangedRemovesTheReminderByItsMarker() async throws {
        let s = try await sessionWithALinkedTodo()
        s.backend.reidentify(s.object.identifier)

        await s.session.deleteTodo(id: s.todo.id)

        XCTAssertEqual(s.backend.removedIdentifiers.count, 1)
        XCTAssertTrue(s.backend.allReminders.isEmpty)
        XCTAssertEqual(s.backend.fetchCount, 1)
        let gone = try await XCTUnwrap(s.session.store).todos.load(id: s.todo.id)
        XCTAssertNil(gone)
        XCTAssertNil(s.session.errorMessage)
    }

    func testDeletingALinkedTodoWhoseAppleReminderIsGoneStillDeletesTheRow() async throws {
        let s = try await sessionWithALinkedTodo()
        try s.backend.remove(s.object)

        await s.session.deleteTodo(id: s.todo.id)

        let gone = try await XCTUnwrap(s.session.store).todos.load(id: s.todo.id)
        XCTAssertNil(gone)
        XCTAssertNil(s.session.errorMessage)
    }

    func testALockBeforeTheAppleRemovalLeavesTheReminderAndTheTodo() async throws {
        let s = try await sessionWithALinkedTodo()
        s.session.todoRemovalDidLookUpDestination = { [unowned session = s.session] in
            session.todoRemovalDidLookUpDestination = {}
            await session.lockNow(reason: "idle")
        }

        await s.session.deleteTodo(id: s.todo.id)

        XCTAssertTrue(s.backend.contains(s.object.identifier), "the reminder was removed under a lock")
        XCTAssertTrue(s.backend.removedIdentifiers.isEmpty)
        XCTAssertNil(s.session.errorMessage)
        await s.session.unlock()
        let kept = try await XCTUnwrap(s.session.store, "unlock failed: \(s.session.initError ?? "")")
            .todos.load(id: s.todo.id)
        XCTAssertEqual(kept?.reminderIdentifier, s.object.identifier)
    }
}
