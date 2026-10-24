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

    func testPatientRecordShowsOnlyFilledFields() {
        var patient = Patient.newRecord()
        patient.profile.firstName = "Σοφία"
        patient.profile.lastName = "Βασιλείου"
        patient.profile.amka = "24109300442"
        let hosting = offscreen.host(PatientRecordHost(patient: patient))
        // Read-only values are SwiftUI text, not AppKit fields, so only the
        // absence of empty inputs is checked here; which values appear is
        // covered by `PatientRecordFieldsTests`.
        let placeholders = OffscreenHost.placeholders(under: hosting)
        for absent in ["11 digits", "Street and number", "Father's name"] {
            XCTAssertFalse(placeholders.contains(absent), "record view shows an empty “\(absent)” box")
        }
        XCTAssertTrue(placeholders.contains("Add a condition"), "medical lists should stay editable")
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "patient record rendered blank")
    }

    func testEventRecordShowsNoInputs() {
        let event = CalendarEvent(title: "Post-op review", description: "Check wound.",
                                  eventType: .surgery)
        let hosting = offscreen.host(EventRecordView(event: event, patientName: "Μαρία Αντωνοπούλου",
                                                     onOpenPatient: {}), height: 600)
        let found = OffscreenHost.placeholders(under: hosting)
        XCTAssertFalse(found.contains("Title"), "the event record shows an input; found \(found.sorted())")
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "event record rendered blank")
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

private struct PatientRecordHost: View {
    @State var patient: Patient
    var body: some View { PatientRecordView(patient: $patient, onEdit: {}) }
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
