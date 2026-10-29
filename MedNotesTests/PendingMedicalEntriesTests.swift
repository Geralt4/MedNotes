import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// Text typed into a medical list's "Add…" row and not added used to be dropped
/// by Done, Save, switching patient and a lock. It is now added to the draft
/// wherever the editor is left, with the status or severity shown beside the row.
final class PendingMedicalEntriesTests: XCTestCase {
    func testEveryNamedRowIsAddedWithTheValueShownBesideIt() {
        var entries = PendingMedicalEntries()
        entries.conditionName = "  Asthma "
        entries.conditionStatus = .resolved
        entries.allergyName = "Penicillin"
        entries.allergySeverity = .severe
        entries.medicationName = "Metformin"
        entries.medicationDosage = " 850 mg "
        entries.medicationFrequency = "twice daily"
        var medical = MedicalInfo()

        XCTAssertEqual(entries.commitAll(into: &medical), 3)

        XCTAssertEqual(medical.conditions.map(\.name), ["Asthma"])
        XCTAssertEqual(medical.conditions.first?.status, .resolved)
        XCTAssertEqual(medical.allergies.map(\.allergen), ["Penicillin"])
        XCTAssertEqual(medical.allergies.first?.severity, .severe)
        XCTAssertEqual(medical.medications.map(\.name), ["Metformin"])
        XCTAssertEqual(medical.medications.first?.dosage, "850 mg")
        XCTAssertEqual(medical.medications.first?.frequency, "twice daily")
        XCTAssertTrue(entries.isEmpty, "what was added is cleared, so it is not added twice")
        XCTAssertEqual(entries.allergySeverity, .moderate)
        XCTAssertEqual(entries.commitAll(into: &medical), 0)
        XCTAssertEqual(medical.allergies.count, 1)
    }

    func testRowsWithoutANameAddNothing() {
        var entries = PendingMedicalEntries()
        entries.allergyName = "   \n"
        entries.medicationDosage = "850 mg"
        entries.medicationFrequency = "daily"
        var medical = MedicalInfo()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(entries.commitAll(into: &medical), 0)
        XCTAssertTrue(medical.allergies.isEmpty)
        XCTAssertTrue(medical.medications.isEmpty, "a dosage with no medication name is not an entry")
    }

    func testAddingOneRowLeavesTheOthersPending() {
        var entries = PendingMedicalEntries()
        entries.allergyName = "Latex"
        entries.conditionName = "Asthma"
        var medical = MedicalInfo()
        entries.addAllergy(to: &medical)
        XCTAssertEqual(medical.allergies.map(\.allergen), ["Latex"])
        XCTAssertEqual(entries.conditionName, "Asthma")
        XCTAssertFalse(entries.isEmpty)
    }
}

/// The same, through the detail view a user actually leaves: type into the row,
/// then lock, or move to another patient.
@MainActor
final class PendingMedicalEntriesEditorTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.PendingMedicalEntries"
    private var roots: [DataRoot] = []
    private let offscreen = OffscreenHost()

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        offscreen.tearDown()
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    func testAnAllergyTypedAndNotAddedIsKeptWhenTheSessionLocks() async throws {
        let (session, root) = try await makeSession()
        let patient = try await makePatient(in: session, name: "Maria", amka: "11111111111")
        session.selectPatient(patient.id)
        let window = try offscreen.hostForTyping(
            PatientDetailView().environmentObject(session), width: 900, height: 1200)
        let row = try await addRow("Add an allergy", in: window)
        XCTAssertTrue(window.makeFirstResponder(row))
        try type("Penicillin", in: row)

        await session.lockNow(reason: "idle")

        let file = try Database.testDatabase(path: root.databaseURL.path, root: root)
        let stored = try await file.loadPatient(id: patient.id)
        await file.close()
        XCTAssertEqual(stored?.medical.allergies.map(\.allergen), ["Penicillin"])
        XCTAssertEqual(stored?.medical.allergies.first?.severity, .moderate,
                       "recorded with the severity that was showing beside the row")
    }

    func testAnAllergyTypedAndNotAddedIsKeptWhenMovingToAnotherPatient() async throws {
        let (session, _) = try await makeSession()
        let first = try await makePatient(in: session, name: "Maria", amka: "11111111111")
        let second = try await makePatient(in: session, name: "Nikos", amka: "22222222222")
        session.selectPatient(first.id)
        let window = try offscreen.hostForTyping(
            PatientDetailView().environmentObject(session), width: 900, height: 1200)
        let row = try await addRow("Add an allergy", in: window)
        XCTAssertTrue(window.makeFirstResponder(row))
        try type("Latex", in: row)

        session.selectPatient(second.id)

        var stored: Patient?
        for _ in 0..<200 where stored?.medical.allergies.isEmpty != false {
            try await Task.sleep(nanoseconds: 50_000_000)
            stored = try await session.store?.patients.load(id: first.id)
        }
        XCTAssertEqual(stored?.medical.allergies.map(\.allergen), ["Latex"])
        let other = try await session.store?.patients.load(id: second.id)
        XCTAssertTrue(other?.medical.allergies.isEmpty == true,
                      "it belongs to the patient it was typed for")
    }

    // MARK: - Helpers

    private func makeSession() async throws -> (AppSession, DataRoot) {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        session.selectedModule = .patients
        return (session, root)
    }

    private func makePatient(in session: AppSession, name: String, amka: String) async throws -> Patient {
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(loaded)
        patient.profile.firstName = name
        patient.profile.lastName = "Test"
        patient.profile.amka = amka
        let saved = await session.save(patient)
        XCTAssertTrue(saved)
        return patient
    }

    private func type(_ text: String, in field: NSTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func addRow(_ prompt: String, in window: NSWindow,
                        timeout: TimeInterval = 15) async throws -> NSTextField {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            if let field = Self.textFields(in: window.contentView).first(where: { $0.placeholderString == prompt }) {
                return field
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let shown = Self.textFields(in: window.contentView).map { $0.placeholderString ?? $0.stringValue }
        return try XCTUnwrap(nil as NSTextField?, "never showed “\(prompt)”; fields show \(shown)")
    }

    private static func textFields(in view: NSView?) -> [NSTextField] {
        guard let view else { return [] }
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap { textFields(in: $0) }
    }
}
