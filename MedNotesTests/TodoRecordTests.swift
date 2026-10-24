import XCTest
@testable import MedNotes

/// The due line on a todo's record: urgent only while it is still open.
final class TodoRecordTests: XCTestCase {
    private lazy var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Athens")!
        return c
    }()
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 15))!

    private func todo(dueInDays days: Int?, completed: Bool = false) -> TodoItem {
        var todo = TodoItem.newRecord()
        todo.dueDate = days.flatMap { calendar.date(byAdding: .day, value: $0, to: now) }
        todo.isCompleted = completed
        return todo
    }

    private func line(_ todo: TodoItem) -> (text: String, tone: TodoRecordView.DueTone)? {
        TodoRecordView.dueLine(for: todo, now: now, calendar: calendar)
    }

    private func formatted(_ date: Date?) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = calendar.timeZone
        return date!.formatted(style)
    }

    func testNoDueDateHasNoLine() {
        XCTAssertNil(line(todo(dueInDays: nil)))
    }

    func testOverdue() {
        let item = todo(dueInDays: -5)
        XCTAssertEqual(line(item)?.tone, .overdue)
        XCTAssertEqual(line(item)?.text, String(localized: "Overdue · \(formatted(item.dueDate))"))
    }

    func testToday() {
        XCTAssertEqual(line(todo(dueInDays: 0))?.text, String(localized: "Due today"))
        XCTAssertEqual(line(todo(dueInDays: 0))?.tone, .today)
    }

    func testTomorrowAndLater() {
        XCTAssertEqual(line(todo(dueInDays: 1))?.text, String(localized: "Due tomorrow"))
        let later = todo(dueInDays: 4)
        XCTAssertEqual(line(later)?.text, String(localized: "Due \(formatted(later.dueDate))"))
        XCTAssertEqual(line(later)?.tone, .plain)
    }

    func testCompletedTodoIsNeverOverdue() {
        let done = todo(dueInDays: -5, completed: true)
        XCTAssertEqual(line(done)?.tone, .plain)
        XCTAssertEqual(line(done)?.text, String(localized: "Due \(formatted(done.dueDate))"))
    }
}
