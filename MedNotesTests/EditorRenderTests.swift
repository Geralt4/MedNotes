import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// Hosts each editor form off screen through `OffscreenHost`, the way
/// `scripts/render_editors.swift` does, and checks structure rather than
/// pixels: every labelled input exists as a real text field with the
/// placeholder it should show, and the rendered bitmap has content. This
/// guards the class of bug that started the editor work — fields drawn
/// invisible — without reference images that break on every macOS release.
@MainActor
final class EditorRenderTests: XCTestCase {
    private let offscreen = OffscreenHost()

    override func tearDown() {
        offscreen.tearDown()
    }

    // MARK: - Cases

    func testPatientEditorExposesEveryField() {
        let hosting = offscreen.host(PatientHost(patient: Patient.newRecord()))
        let found = OffscreenHost.placeholders(under: hosting)
        for expected in ["First name", "Last name", "Father's name", "11 digits",
                         "Mobile or landline", "name@example.com", "Street and number",
                         "Postal code", "City", "Region", "Country",
                         "Add a condition", "Add an allergy", "Add a medication"] {
            XCTAssertTrue(found.contains(expected), "no text field with placeholder “\(expected)”; found \(found.sorted())")
        }
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "patient editor rendered blank")
    }

    func testTodoEditorExposesItsFields() {
        let hosting = offscreen.host(TodoHost(todo: TodoItem.newRecord()), height: 700)
        let found = OffscreenHost.placeholders(under: hosting)
        XCTAssertTrue(found.contains("Title"), "found \(found.sorted())")
        XCTAssertTrue(found.contains("Add a tag"), "found \(found.sorted())")
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "todo editor rendered blank")
    }

    func testEventEditorExposesItsFields() {
        let hosting = offscreen.host(EventHost(event: CalendarEvent.newRecord()), height: 700)
        let found = OffscreenHost.placeholders(under: hosting)
        XCTAssertTrue(found.contains("Title"), "found \(found.sorted())")
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "event editor rendered blank")
    }
}

// Hosts own the draft so the forms render without a session.

private struct PatientHost: View {
    @State var patient: Patient
    var body: some View { PatientEditorForm(draft: $patient) }
}

private struct TodoHost: View {
    @State var todo: TodoItem
    var body: some View {
        TodoEditorForm(draft: $todo, patientOptions: [], isKnownPatient: { _ in false },
                       onSetCompleted: { todo.isCompleted = $0 })
    }
}

private struct EventHost: View {
    @State var event: CalendarEvent
    var body: some View {
        EventEditorForm(draft: $event, patientOptions: [], isKnownPatient: { _ in false })
    }
}
