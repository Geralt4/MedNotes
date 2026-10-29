import XCTest
@testable import MedNotes

/// A new event or todo nobody has typed into is a placeholder: its editor
/// discards it when it closes. Pushing it put a "New Event" into the user's
/// Calendar (or a "New Todo" into Reminders) for that discard to remove, and a
/// lock before the discard left it in both places.
final class SyncPlaceholderTests: XCTestCase {
    func testAnUntouchedNewEventIsNotPushedButAnEditedOneIs() {
        var event = CalendarEvent.newRecord()
        XCTAssertFalse(CalendarSyncCore.shouldPush(event), "a placeholder is discarded when its editor closes")
        event.title = "Clinic"
        XCTAssertTrue(CalendarSyncCore.shouldPush(event))
    }

    func testAPlaceholderThatWasAlreadyPushedFollowsTheNormalRules() {
        var event = CalendarEvent.newRecord()
        event.ekEventIdentifier = "ek-1"
        event.syncStatus = .synced
        event.lastSyncDate = event.updatedAt
        XCTAssertFalse(CalendarSyncCore.shouldPush(event), "synced and unchanged")
        event.updatedAt = event.updatedAt.addingTimeInterval(10)
        XCTAssertTrue(CalendarSyncCore.shouldPush(event), "edited since the last sync")
    }

    func testAnUntouchedNewTodoIsNotPushedButAnEditedOneIs() {
        var todo = TodoItem.newRecord()
        XCTAssertFalse(ReminderSyncCore.shouldPush(todo))
        todo.title = "Call the lab"
        XCTAssertTrue(ReminderSyncCore.shouldPush(todo))
    }

    func testARowThatWasNeverSyncedButIsNotAPlaceholderIsPushed() {
        let event = CalendarEvent(title: "Clinic")
        XCTAssertTrue(CalendarSyncCore.shouldPush(event))
        XCTAssertTrue(ReminderSyncCore.shouldPush(TodoItem(title: "Call")))
    }

}
