import XCTest
@testable import MedNotes

final class ModelRoundTripTests: XCTestCase {
    static var testBundle: Bundle { Bundle(for: ModelRoundTripTests.self) }

    func testDecodeRealPatientFixture() throws {
        let url = Self.testBundle.url(forResource: "patient_full", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let patient = try decodeJSONData(Patient.self, from: data)

        XCTAssertEqual(patient.id.uuidString, "958541E5-DEA0-4037-A39E-DF349F179D2F")
        XCTAssertEqual(patient.profile.firstName, "JohnWorkflow")
        XCTAssertEqual(patient.profile.lastName, "TestPatientWorkflow")
        XCTAssertEqual(patient.profile.gender, .male)
        XCTAssertEqual(patient.profile.amka, "12345678901325")
        XCTAssertEqual(patient.profile.address.city, "Test City")
        XCTAssertEqual(patient.profile.address.country, "Greece")
        XCTAssertEqual(patient.tags.count, 1)
        XCTAssertEqual(patient.tags.first?.color, .red)
        XCTAssertEqual(patient.tags.first?.category, .treatmentPriority)
        XCTAssertEqual(patient.medical.conditions.first?.name, "Hypertension")
        XCTAssertEqual(patient.medical.conditions.first?.status, .active)
        XCTAssertEqual(patient.medical.allergies.first?.allergen, "Penicillin")
        XCTAssertEqual(patient.medical.allergies.first?.severity, .moderate)
        XCTAssertEqual(patient.medical.medications.first?.name, "Lisinopril")
        XCTAssertTrue(patient.medical.medications.first?.isActive ?? false)
        XCTAssertFalse(patient.isArchived)
    }

    func testPatientRoundTrip() throws {
        let url = Self.testBundle.url(forResource: "patient_full", withExtension: "json")!
        let original = try Data(contentsOf: url)
        let patient = try decodeJSONData(Patient.self, from: original)
        let reencoded = try encodeJSONData(patient)
        let reparsed = try decodeJSONData(Patient.self, from: reencoded)

        XCTAssertEqual(patient, reparsed)
    }

    func testDecodeNoteFixture() throws {
        let url = Self.testBundle.url(forResource: "note_simple", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let note = try decodeJSONData(Note.self, from: data)

        XCTAssertEqual(note.id.uuidString, "2720DBF2-119E-453B-8451-94F382288673")
        XCTAssertEqual(note.title, "Backup Test Note")
        XCTAssertEqual(note.content, "For backup testing")
        XCTAssertEqual(note.tags, ["backup"])
        XCTAssertTrue(note.mentionedPatients.isEmpty)
        XCTAssertFalse(note.isPinned)
    }

    func testDecodeTodoFixtures() throws {
        let highURL = Self.testBundle.url(forResource: "todo_high", withExtension: "json")!
        let high = try decodeJSONData(TodoItem.self, from: Data(contentsOf: highURL))
        XCTAssertEqual(high.title, "Follow up with John TestPatient")
        XCTAssertEqual(high.priority, .high)
        XCTAssertEqual(high.syncStatus, .localOnly)
        XCTAssertEqual(high.patientName, "John TestPatient")
        XCTAssertEqual(high.tags, ["patient-F6A80377"])

        let wfURL = Self.testBundle.url(forResource: "todo_workflow", withExtension: "json")!
        let wf = try decodeJSONData(TodoItem.self, from: Data(contentsOf: wfURL))
        XCTAssertEqual(wf.priority, .high)
        XCTAssertEqual(wf.syncStatus, .localOnly)
    }

    func testDecodeEventFixture() throws {
        let url = Self.testBundle.url(forResource: "event_appointment", withExtension: "json")!
        let event = try decodeJSONData(CalendarEvent.self, from: Data(contentsOf: url))
        XCTAssertEqual(event.title, "Event 0 - JohnLarge1 TestPatientLarge1")
        XCTAssertEqual(event.eventType, .appointment)
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.patientId?.uuidString, "9550164F-8A4B-47D4-B8AF-C661996D2F09")
    }

    func testNoteDecodesWithoutIsPinned() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "createdAt":"2026-03-04T22:45:41Z","updatedAt":"2026-03-04T22:45:41Z"}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertFalse(note.isPinned)
        XCTAssertTrue(note.tags.isEmpty)
        XCTAssertTrue(note.mentionedPatients.isEmpty)
    }

    func testTodoDecodesWhenPriorityIsWrongType() throws {
        let json = """
        {"id":"A1B2C3D4-E5F6-7890-ABCD-EF1234567890","title":"follow up","priority":1}
        """.data(using: .utf8)!
        let todo = try decodeJSONData(TodoItem.self, from: json)
        XCTAssertEqual(todo.title, "follow up")
        XCTAssertEqual(todo.priority, .medium)
    }

    func testNoteDecodesWhenPinnedIsInteger() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "isPinned":1}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertTrue(note.isPinned)
    }

    func testNoteDecodesWhenPinnedIsString() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "isPinned":"true"}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertTrue(note.isPinned)

        let off = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "isPinned":"0"}
        """.data(using: .utf8)!
        let unpinned = try decodeJSONData(Note.self, from: off)
        XCTAssertFalse(unpinned.isPinned)
    }

    func testNoteDecodesWhenTitleIsWrongType() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":12,"content":"c"}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.content, "c")
    }

    func testPatientDecodesWhenPhotoIsCorrupt() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"1996-03-11",
                    "photo":"%%%not-base64%%%","address":"not-an-object"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.firstName, "Ada")
        XCTAssertNil(patient.profile.photo)
        XCTAssertEqual(patient.profile.address.city, "")
    }

    func testPatientDecodesWhenFirstNameIsWrongType() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":1,"lastName":"Lovelace","dateOfBirth":"1996-03-11"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.firstName, "")
        XCTAssertEqual(patient.profile.lastName, "Lovelace")
    }

    func testNoteKeepsValidTagsWhenOneIsCorrupt() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "tags":["backup", 1, "follow-up"]}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertEqual(note.tags, ["backup", "follow-up"])
    }

    func testPatientKeepsNotesWhenOneEntryIsCorrupt() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"1996-03-11"},
         "notes":["seen in clinic", {"text":"bad"}, "labs pending"],
         "tasks":["call", 3]}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.notes, ["seen in clinic", "labs pending"])
        XCTAssertEqual(patient.tasks, ["call"])
    }

    func testNoteAndTodoDecodeWithoutCreatedAt() throws {
        let noteJSON = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c"}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: noteJSON)
        XCTAssertEqual(note.updatedAt, note.createdAt)

        let corruptNoteJSON = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "createdAt":"not-a-date"}
        """.data(using: .utf8)!
        let corruptNote = try decodeJSONData(Note.self, from: corruptNoteJSON)
        XCTAssertEqual(corruptNote.title, "t")

        let todoJSON = """
        {"id":"A1B2C3D4-E5F6-7890-ABCD-EF1234567890","title":"follow up"}
        """.data(using: .utf8)!
        let todo = try decodeJSONData(TodoItem.self, from: todoJSON)
        XCTAssertEqual(todo.title, "follow up")
        XCTAssertFalse(todo.isCompleted)
        XCTAssertEqual(todo.priority, .medium)
    }

    func testIncompleteTodoDecodeDropsCompletedAt() throws {
        let json = """
        {"id":"A1B2C3D4-E5F6-7890-ABCD-EF1234567890","title":"follow up",
         "isCompleted":false,"completedAt":"2026-03-05T22:24:01Z"}
        """.data(using: .utf8)!
        let todo = try decodeJSONData(TodoItem.self, from: json)
        XCTAssertFalse(todo.isCompleted)
        XCTAssertNil(todo.completedAt)
    }

    func testDateDecoderAcceptsUnixTimestamp() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "createdAt":1700000000,"updatedAt":1700000000,"tags":[],"mentionedPatients":[],"isPinned":false}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertEqual(note.createdAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertEqual(try LenientDate.decode("1700000000").timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        XCTAssertThrowsError(try LenientDate.decode("1996"))
        XCTAssertThrowsError(try LenientDate.decodeTimestamp(1996))
        let yearJSON = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":1996}}
        """.data(using: .utf8)!
        let yearPatient = try decodeJSONData(Patient.self, from: yearJSON)
        XCTAssertEqual(yearPatient.profile.dateOfBirth.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testDateDecoderAcceptsDateOnly() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"1996-03-11"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        let parsed = try LenientDate.decode("1996-03-11")
        XCTAssertEqual(patient.profile.dateOfBirth, parsed)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: parsed)
        XCTAssertEqual(comps.year, 1996)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 11)
    }

    func testDateDecoderRejectsImpossibleDateOnly() throws {
        XCTAssertThrowsError(try LenientDate.decode("2026-02-31"))
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"2026-02-31"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.dateOfBirth.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testLenientEnumNormalization() {
        XCTAssertEqual(Gender.parse("male"), .male)
        XCTAssertEqual(Gender.parse("FEMALE"), .female)
        XCTAssertEqual(Gender.parse("localOnly"), .preferNotToSay)
        XCTAssertEqual(SyncStatus.parse("Local Only"), .localOnly)
        XCTAssertEqual(SyncStatus.parse("localOnly"), .localOnly)
        XCTAssertEqual(SyncStatus.parse("Synced"), .synced)
        XCTAssertEqual(SyncStatus.parse("synced"), .synced)
        XCTAssertEqual(EventType.parse("appointment"), .appointment)
        XCTAssertEqual(EventType.parse("Appointment"), .appointment)
        XCTAssertEqual(TodoPriority.parse("high"), .high)
        XCTAssertEqual(BloodType.parse("A+"), .aPositive)
        XCTAssertEqual(BloodType.parse("O-"), .oNegative)
        XCTAssertEqual(BloodType.parse("A\u{2212}"), .aNegative,
                       "the display string uses a typographic minus sign")
        XCTAssertEqual(BloodType.parse("AB\u{2013}"), .abNegative)
        for type in BloodType.allCases {
            XCTAssertEqual(
                BloodType.parse(DisplayCopy.bloodType(type)), type,
                "a value the UI displays must decode back to the same blood type")
        }
        XCTAssertEqual(BloodType.parse("not-a-blood-type"), .unknown)
        XCTAssertNotEqual(BloodType.parse("not-a-blood-type"), .oNegative)
    }

    /// Decoding must reach the same `parse` the direct call does. These went
    /// through the protocol extension's generic default before `parse` became
    /// a protocol requirement, so "A+" silently decoded to `.unknown`.
    func testCustomParseAppliesWhenDecoding() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(BloodType.self, from: Data("\"A+\"".utf8)), .aPositive)
        XCTAssertEqual(
            try JSONDecoder().decode(BloodType.self, from: Data("\"O-\"".utf8)), .oNegative)
        XCTAssertEqual(
            try JSONDecoder().decode(SyncStatus.self, from: Data("\"localOnly\"".utf8)), .localOnly)
    }

    func testTodoComputedFlags() {
        let cal = Calendar.current
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date())!

        let overdue = TodoItem(title: "a", dueDate: yesterday)
        XCTAssertTrue(overdue.isOverdue)
        XCTAssertFalse(overdue.isDueToday)

        let dueToday = TodoItem(title: "b", dueDate: Date())
        XCTAssertTrue(dueToday.isDueToday)
        XCTAssertFalse(dueToday.isOverdue)

        let future = TodoItem(title: "c", dueDate: tomorrow)
        XCTAssertFalse(future.isOverdue)
        XCTAssertFalse(future.isDueToday)

        let completed = TodoItem(title: "d", isCompleted: true, dueDate: yesterday)
        XCTAssertFalse(completed.isOverdue)

        let completedToday = TodoItem(title: "e", isCompleted: true, dueDate: Date())
        XCTAssertFalse(completedToday.isDueToday)
        XCTAssertFalse(completedToday.isOverdue)
    }

    func testEventIsUpcomingUsesEndTimeForTimedAndCalendarDayForAllDay() {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)

        var finishedToday = CalendarEvent(
            title: "done",
            startDate: startOfToday.addingTimeInterval(8 * 3600),
            endDate: startOfToday.addingTimeInterval(9 * 3600)
        )
        if finishedToday.endDate >= now {
            finishedToday.endDate = now.addingTimeInterval(-60)
            finishedToday.startDate = finishedToday.endDate.addingTimeInterval(-3600)
        }
        XCTAssertFalse(finishedToday.isUpcoming)

        let laterToday = CalendarEvent(
            title: "later",
            startDate: now.addingTimeInterval(3600),
            endDate: now.addingTimeInterval(7200)
        )
        XCTAssertTrue(laterToday.isUpcoming)

        let allDayToday = CalendarEvent(
            title: "all day",
            startDate: startOfToday,
            endDate: startOfToday,
            isAllDay: true
        )
        XCTAssertTrue(allDayToday.isUpcoming)

        let yesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let allDayYesterday = CalendarEvent(
            title: "yesterday",
            startDate: yesterday,
            endDate: yesterday,
            isAllDay: true
        )
        XCTAssertFalse(allDayYesterday.isUpcoming)
    }

    func testPatientDecodesWithoutDateOfBirth() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.firstName, "Ada")
        XCTAssertEqual(patient.profile.dateOfBirth.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testPatientDecodesWithCorruptDateOfBirth() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"not-a-date"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.firstName, "Ada")
        XCTAssertEqual(patient.profile.dateOfBirth.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testPatientDecodesWithoutOptionalCollections() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"1990-01-01T00:00:00Z"}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.profile.firstName, "Ada")
        XCTAssertEqual(patient.profile.gender, .preferNotToSay)
        XCTAssertTrue(patient.medical.allergies.isEmpty)
        XCTAssertTrue(patient.tags.isEmpty)
        XCTAssertFalse(patient.isArchived)
    }

    func testEventDecoderClampsEndBeforeStart() throws {
        let json = """
        {"id":"F47766B6-0849-4C2D-A939-96D6639DD24C","title":"backwards",
         "startDate":"2026-03-05T22:24:01Z","endDate":"2026-03-05T21:00:00Z"}
        """.data(using: .utf8)!
        let event = try decodeJSONData(CalendarEvent.self, from: json)
        XCTAssertGreaterThanOrEqual(event.endDate, event.startDate)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 1800, accuracy: 0.001)
    }

    func testAllDayEventDecoderClampsEndToStart() throws {
        let json = """
        {"id":"F47766B6-0849-4C2D-A939-96D6639DD24C","title":"backwards all day",
         "isAllDay":true,"startDate":"2026-03-05T00:00:00Z","endDate":"2026-03-04T00:00:00Z"}
        """.data(using: .utf8)!
        let event = try decodeJSONData(CalendarEvent.self, from: json)
        XCTAssertTrue(event.isAllDay)
        XCTAssertEqual(event.endDate, event.startDate)
    }

    func testEventDecodesWithoutStartDate() throws {
        let json = """
        {"id":"F47766B6-0849-4C2D-A939-96D6639DD24C","title":"no start"}
        """.data(using: .utf8)!
        let event = try decodeJSONData(CalendarEvent.self, from: json)
        XCTAssertEqual(event.title, "no start")
        XCTAssertGreaterThanOrEqual(event.endDate, event.startDate)
    }

    func testSetAllDayCollapsesOvernightTimedEventToOneDay() {
        let cal = Calendar(identifier: .gregorian)
        let start = DateComponents(calendar: cal, year: 2026, month: 3, day: 5, hour: 23).date!
        var event = CalendarEvent(
            title: "overnight",
            startDate: start,
            endDate: start.addingTimeInterval(2 * 3600),
            isAllDay: false)
        event.setAllDay(true, calendar: cal)
        XCTAssertTrue(event.isAllDay)
        XCTAssertTrue(cal.isDate(event.startDate, inSameDayAs: start))
        XCTAssertTrue(cal.isDate(event.startDate, inSameDayAs: event.endDate))

        event.setAllDay(false, calendar: cal)
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.endDate.timeIntervalSince(event.startDate), 1800, accuracy: 0.001)
    }

    func testHospitalizationDecodesWithMissingDefaults() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673",
         "hospitalName":"Evangelismos",
         "admissionDate":"2026-03-04T22:45:41Z"}
        """.data(using: .utf8)!
        let stay = try decodeJSONData(Hospitalization.self, from: json)
        XCTAssertEqual(stay.hospitalName, "Evangelismos")
        XCTAssertEqual(stay.admissionType, .elective)
        XCTAssertEqual(stay.status, .admitted)
        XCTAssertTrue(stay.isActive)
        XCTAssertFalse(stay.followUpRequired)
        XCTAssertTrue(stay.procedures.isEmpty)
    }

    func testDischargedHospitalizationIsNotActive() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673",
         "admissionDate":"2026-03-01T10:00:00Z",
         "dischargeDate":"2026-03-05T10:00:00Z"}
        """.data(using: .utf8)!
        let stay = try decodeJSONData(Hospitalization.self, from: json)
        XCTAssertEqual(stay.status, .discharged)
        XCTAssertFalse(stay.isActive)
        XCTAssertFalse(stay.isCurrentlyAdmitted)
    }

    func testDiscontinuedHospitalMedicationIsNotActive() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673",
         "medicationName":"Heparin","discontinued":true}
        """.data(using: .utf8)!
        let med = try decodeJSONData(HospitalMedication.self, from: json)
        XCTAssertTrue(med.discontinued)
        XCTAssertFalse(med.isActive)
    }

    func testHospitalMedicationWithPastEndDateIsNotActive() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673",
         "medicationName":"Heparin","endDate":"2020-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let med = try decodeJSONData(HospitalMedication.self, from: json)
        XCTAssertTrue(med.discontinued)
        XCTAssertFalse(med.isActive)
    }

    func testVisitAndTagDecodeWithMissingDefaults() throws {
        let visitJSON = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","date":"2026-03-04T22:45:41Z"}
        """.data(using: .utf8)!
        let visit = try decodeJSONData(Visit.self, from: visitJSON)
        XCTAssertEqual(visit.type, .checkup)
        XCTAssertEqual(visit.status, .completed)
        XCTAssertFalse(visit.followUpRequired)

        let tagJSON = """
        {"id":"3E699CEF-6B9E-4276-BBD8-BC34A96AB178","name":"High Priority"}
        """.data(using: .utf8)!
        let tag = try decodeJSONData(PatientTag.self, from: tagJSON)
        XCTAssertEqual(tag.name, "High Priority")
        XCTAssertEqual(tag.color, .gray)
        XCTAssertEqual(tag.category, .general)
    }

    func testIncompleteAlertDecodeDropsCompletedDate() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"lab",
         "isCompleted":false,"completedDate":"2026-03-05T22:24:01Z"}
        """.data(using: .utf8)!
        let alert = try decodeJSONData(MedicalAlert.self, from: json)
        XCTAssertFalse(alert.isCompleted)
        XCTAssertNil(alert.completedDate)
    }

    func testPatientKeepsMedicalWhenBloodTypeIsWrongType() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace","dateOfBirth":"1996-03-11"},
         "medical":{"bloodType":1,"medications":[{"name":"Lisinopril"}]}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertNil(patient.medical.bloodType)
        XCTAssertEqual(patient.medical.medications.first?.name, "Lisinopril")
    }

    func testPatientKeepsMedicalWhenNestedConditionIdMissing() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace"},
         "medical":{"conditions":[{"name":"Hypertension"},
                                 {"id":"BB48A7E2-342B-4B6E-AD32-ED7177D4A314","name":"Diabetes"}],
                    "allergies":[{"id":"0FF359C5-F490-48CE-9156-08FB6889106B","allergen":"Penicillin"}]}}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(Set(patient.medical.conditions.map(\.name)), Set(["Hypertension", "Diabetes"]))
        XCTAssertEqual(patient.medical.allergies.map(\.allergen), ["Penicillin"])
        XCTAssertNotEqual(patient.medical.conditions.first { $0.name == "Hypertension" }?.id,
                          UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    func testPatientKeepsMedicationsWhenOneEntryIsCorrupt() throws {
        let json = """
        {"id":"958541E5-DEA0-4037-A39E-DF349F179D2F",
         "profile":{"firstName":"Ada","lastName":"Lovelace"},
         "medical":{"medications":[{"name":"Lisinopril"},"bad",{"name":"Metformin"}]},
         "tags":[{"name":"priority"}, 1],
         "hospitalizations":[{"hospitalName":"Evangelismos"},"nope"]}
        """.data(using: .utf8)!
        let patient = try decodeJSONData(Patient.self, from: json)
        XCTAssertEqual(patient.medical.medications.map(\.name), ["Lisinopril", "Metformin"])
        XCTAssertEqual(patient.tags.map(\.name), ["priority"])
        XCTAssertEqual(patient.hospitalizations.map(\.hospitalName), ["Evangelismos"])
    }

    func testAllergyAndMedicationDecodeWithMissingDefaults() throws {
        let allergyJSON = """
        {"id":"0FF359C5-F490-48CE-9156-08FB6889106B","allergen":"Penicillin"}
        """.data(using: .utf8)!
        let allergy = try decodeJSONData(Allergy.self, from: allergyJSON)
        XCTAssertEqual(allergy.allergen, "Penicillin")
        XCTAssertEqual(allergy.severity, .moderate)
        XCTAssertEqual(allergy.notes, "")

        let medJSON = """
        {"id":"F57821B9-33D2-40E2-9767-8575DF0BE8AF","name":"Lisinopril"}
        """.data(using: .utf8)!
        let med = try decodeJSONData(Medication.self, from: medJSON)
        XCTAssertEqual(med.name, "Lisinopril")
        XCTAssertTrue(med.isActive)
        XCTAssertEqual(med.dosage, "")

        let corruptStartJSON = """
        {"id":"F57821B9-33D2-40E2-9767-8575DF0BE8AF","name":"Lisinopril",
         "startDate":"not-a-date"}
        """.data(using: .utf8)!
        let corruptStart = try decodeJSONData(Medication.self, from: corruptStartJSON)
        XCTAssertEqual(corruptStart.name, "Lisinopril")
        XCTAssertTrue(corruptStart.isActive)
    }

    func testMedicationWithPastEndDateIsNotActive() throws {
        let json = """
        {"id":"F57821B9-33D2-40E2-9767-8575DF0BE8AF","name":"Lisinopril",
         "endDate":"2020-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let med = try decodeJSONData(Medication.self, from: json)
        XCTAssertFalse(med.isActive)
    }

    func testMedicationWithEndDateTodayStaysActive() throws {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let today = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        let json = """
        {"id":"F57821B9-33D2-40E2-9767-8575DF0BE8AF","name":"Lisinopril",
         "endDate":"\(today)"}
        """.data(using: .utf8)!
        let med = try decodeJSONData(Medication.self, from: json)
        XCTAssertTrue(med.isActive)
        let endParts = Calendar.current.dateComponents([.year, .month, .day], from: med.endDate!)
        XCTAssertEqual(endParts.year, parts.year)
        XCTAssertEqual(endParts.month, parts.month)
        XCTAssertEqual(endParts.day, parts.day)
    }

    func testMedicationIsCurrentlyActiveIgnoresStaleFlag() {
        let past = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let today = Date()
        let stale = Medication(name: "Lisinopril", endDate: past, isActive: true)
        XCTAssertTrue(stale.isActive)
        XCTAssertFalse(stale.isCurrentlyActive)

        let stopped = Medication(name: "Lisinopril", isActive: false)
        XCTAssertFalse(stopped.isCurrentlyActive)

        let ongoing = Medication(name: "Lisinopril", isActive: true)
        XCTAssertTrue(ongoing.isCurrentlyActive)

        let endingToday = Medication(name: "Lisinopril", endDate: today, isActive: true)
        XCTAssertTrue(endingToday.isCurrentlyActive)
    }

    func testNoteDedupesMentionedPatients() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "createdAt":"2026-03-04T22:45:41Z",
         "mentionedPatients":["958541E5-DEA0-4037-A39E-DF349F179D2F",
                              "958541E5-DEA0-4037-A39E-DF349F179D2F"]}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertEqual(note.mentionedPatients.count, 1)
    }

    func testNoteKeepsValidMentionsWhenOneIdIsCorrupt() throws {
        let good = "958541E5-DEA0-4037-A39E-DF349F179D2F"
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"t","content":"c",
         "mentionedPatients":["\(good)","not-a-uuid"]}
        """.data(using: .utf8)!
        let note = try decodeJSONData(Note.self, from: json)
        XCTAssertEqual(note.mentionedPatients.map(\.uuidString), [good])
    }

    func testTodoDecodesWithCorruptPatientId() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","title":"Call",
         "patientId":"not-a-uuid"}
        """.data(using: .utf8)!
        let todo = try decodeJSONData(TodoItem.self, from: json)
        XCTAssertEqual(todo.title, "Call")
        XCTAssertNil(todo.patientId)
    }

    func testEventDecodesWithCorruptPatientId() throws {
        let json = """
        {"id":"F47766B6-0849-4C2D-A939-96D6639DD24C","title":"Visit",
         "startDate":"2026-03-05T22:24:01Z","patientId":"not-a-uuid"}
        """.data(using: .utf8)!
        let event = try decodeJSONData(CalendarEvent.self, from: json)
        XCTAssertEqual(event.title, "Visit")
        XCTAssertNil(event.patientId)
    }

    func testPatientFileDecodesWithoutFileSize() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","name":"scan.pdf","type":"pdf",
         "uploadDate":"2026-03-04T22:45:41Z","notes":"","tags":[]}
        """.data(using: .utf8)!
        let file = try decodeJSONData(PatientFile.self, from: json)
        XCTAssertEqual(file.name, "scan.pdf")
        XCTAssertEqual(file.type, .pdf)
        XCTAssertEqual(file.fileSize, 0)
        XCTAssertNil(file.data)
    }

    func testPatientFileDecodesWhenFileSizeIsString() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","name":"scan.pdf","type":"pdf",
         "fileSize":"2048"}
        """.data(using: .utf8)!
        let file = try decodeJSONData(PatientFile.self, from: json)
        XCTAssertEqual(file.fileSize, 2048)
    }

    func testPatientAgeComputed() throws {
        let url = Self.testBundle.url(forResource: "patient_full", withExtension: "json")!
        let data = try Data(contentsOf: url)
        let patient = try decodeJSONData(Patient.self, from: data)
        XCTAssertGreaterThan(patient.profile.age, 20)
        XCTAssertLessThan(patient.profile.age, 120)
    }

    func testPatientFullNameOmitsEmptyParts() {
        let unnamed = PatientProfile(firstName: "", lastName: "", dateOfBirth: Date())
        XCTAssertEqual(unnamed.fullName, "")

        let firstOnly = PatientProfile(firstName: "Ada", lastName: "  ", dateOfBirth: Date())
        XCTAssertEqual(firstOnly.fullName, "Ada")

        let lastOnly = PatientProfile(firstName: "", lastName: "Lovelace", dateOfBirth: Date())
        XCTAssertEqual(lastOnly.fullName, "Lovelace")
    }

    func testKnownDateOfBirthIncludesDatesBefore1970() {
        let missing = PatientProfile(
            firstName: "Ada", lastName: "Lovelace",
            dateOfBirth: Date(timeIntervalSince1970: 0))
        XCTAssertFalse(missing.hasKnownDateOfBirth)

        let born1950 = Calendar.current.date(from: DateComponents(year: 1950, month: 6, day: 15))!
        let known = PatientProfile(firstName: "Ada", lastName: "Lovelace", dateOfBirth: born1950)
        XCTAssertTrue(known.hasKnownDateOfBirth)
        XCTAssertGreaterThan(known.age, 50)
    }

    func testAppointmentDecodesWithoutPatientId() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","date":"2026-03-05T22:24:01Z"}
        """.data(using: .utf8)!
        let appointment = try decodeJSONData(Appointment.self, from: json)
        XCTAssertEqual(appointment.duration, 1800)
        XCTAssertEqual(appointment.type, .checkup)
        XCTAssertFalse(appointment.isConfirmed)
    }

    func testAppointmentDecodesWithCorruptPatientId() throws {
        let json = """
        {"id":"2720DBF2-119E-453B-8451-94F382288673","date":"2026-03-05T22:24:01Z",
         "patientId":"not-a-uuid"}
        """.data(using: .utf8)!
        let appointment = try decodeJSONData(Appointment.self, from: json)
        XCTAssertNotEqual(appointment.patientId.uuidString.lowercased(), "not-a-uuid")
    }
}
