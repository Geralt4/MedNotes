import XCTest
@testable import MedNotes

final class SQLStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mednotes-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeDB() throws -> Database {
        try Database.testDatabase(path: tempDir.appendingPathComponent("test.db").path)
    }

    private func samplePatient(name: String = "Test", amka: String = "12345678901") -> Patient {
        var profile = PatientProfile(
            firstName: name,
            lastName: "Patient",
            dateOfBirth: Calendar.current.date(byAdding: .year, value: -40, to: Date())!,
            gender: .male,
            amka: amka,
            phone: "6900000000",
            email: "\(name.lowercased())@example.com")
        profile.address = Address(street: "Main 1", city: "Athens", postalCode: "12345",
                                  region: "Attica", country: "Greece")
        return Patient(profile: profile)
    }

    func testSchemaMigratesAndIntegrityHolds() async throws {
        let db = try makeDB()
        let integrity = try await db.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        let violations = try await db.foreignKeyCheck()
        XCTAssertEqual(violations, 0)
        let counts = try await db.counts()
        XCTAssertEqual(counts["patients"], 0)
        XCTAssertEqual(counts["notes"], 0)
    }

    func testForeignKeysAreEnforced() async throws {
        let db = try makeDB()
        let event = CalendarEvent(
            title: "orphan",
            patientId: UUID())
        do {
            try await db.saveEvent(event)
            XCTFail("Expected FK violation for missing patient")
        } catch {
            XCTAssertTrue(true)
        }
        _ = try await db.integrityCheck()
    }

    func testSaveEventClampsEndBeforeStart() async throws {
        let db = try makeDB()
        let start = Date()
        let event = CalendarEvent(
            title: "backwards",
            startDate: start,
            endDate: start.addingTimeInterval(-3600))
        try await db.saveEvent(event)
        let loaded = try await db.loadEvent(id: event.id)
        XCTAssertNotNil(loaded)
        XCTAssertGreaterThanOrEqual(loaded!.endDate, loaded!.startDate)
        XCTAssertEqual(loaded!.endDate.timeIntervalSince(loaded!.startDate), 1800, accuracy: 1)
    }

    func testSaveAllDayEventClampsEndToStart() async throws {
        let db = try makeDB()
        let start = Date()
        let event = CalendarEvent(
            title: "backwards all day",
            startDate: start,
            endDate: start.addingTimeInterval(-3600),
            isAllDay: true)
        try await db.saveEvent(event)
        let loaded = try await db.loadEvent(id: event.id)
        XCTAssertNotNil(loaded)
        XCTAssertTrue(loaded!.isAllDay)
        XCTAssertEqual(loaded!.endDate.timeIntervalSince(loaded!.startDate), 0, accuracy: 1)
    }

    func testEventFKAllowsNullPatient() async throws {
        let db = try makeDB()
        let event = CalendarEvent(title: "no patient", patientId: nil)
        try await db.saveEvent(event)
        let loaded = try await db.loadEvent(id: event.id)
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.patientId)
    }

    func testPatientSaveLoadRoundTrip() async throws {
        let db = try makeDB()
        let patient = samplePatient()
        try await db.savePatient(patient)

        let loaded = try await db.loadPatient(id: patient.id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.profile.firstName, "Test")
        XCTAssertEqual(loaded?.profile.amka, "12345678901")
        XCTAssertEqual(loaded?.profile.address.city, "Athens")
        XCTAssertEqual(loaded?.msNormalized(), patient.msNormalized())
    }

    func testLoadPatientKeepsTagsWhenOneEntryIsCorrupt() async throws {
        let db = try makeDB()
        var patient = samplePatient()
        patient.tags = [PatientTag(name: "priority")]
        try await db.savePatient(patient)
        await db.close()

        let conn = try SQLConnection.testConnection(path: tempDir.appendingPathComponent("test.db").path)
        try conn.exec("UPDATE patients SET tags_json = '[{\"name\":\"priority\"},\"bad\"]'")
        conn.close()

        let reopened = try makeDB()
        let loaded = try await reopened.loadPatient(id: patient.id)
        XCTAssertEqual(loaded?.tags.map(\.name), ["priority"])
    }

    func testLoadPatientWithCorruptDateOfBirth() async throws {
        let db = try makeDB()
        let patient = samplePatient()
        try await db.savePatient(patient)
        await db.close()

        let conn = try SQLConnection.testConnection(path: tempDir.appendingPathComponent("test.db").path)
        try conn.exec("UPDATE patients SET date_of_birth = 'not-a-date'")
        conn.close()

        let reopened = try makeDB()
        let loaded = try await reopened.loadAllPatients()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, patient.id)
        XCTAssertEqual(loaded.first?.profile.firstName, "Test")
    }

    func testTodoUpsertIsIdempotent() async throws {
        let db = try makeDB()
        let todo = TodoItem(title: "task", priority: .high)
        try await db.saveTodo(todo)
        try await db.saveTodo(todo)
        let all = try await db.loadAllTodos()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.priority, .high)
    }

    func testToggleNotePinnedLeavesTitleIntact() async throws {
        let db = try makeDB()
        var note = Note(title: "keep me", content: "body")
        try await db.saveNote(note)
        note.title = "unsaved"
        try await db.toggleNotePinned(id: note.id)
        let loaded = try await db.loadNote(id: note.id)
        XCTAssertEqual(loaded?.title, "keep me")
        XCTAssertEqual(loaded?.content, "body")
        XCTAssertEqual(loaded?.isPinned, true)
        try await db.toggleNotePinned(id: note.id)
        let unpinned = try await db.loadNote(id: note.id)
        XCTAssertEqual(unpinned?.isPinned, false)
        XCTAssertEqual(unpinned?.title, "keep me")
    }

    func testToggleTodoCompletedLeavesTitleIntact() async throws {
        let db = try makeDB()
        var todo = TodoItem(title: "keep me", priority: .high)
        try await db.saveTodo(todo)
        todo.title = "unsaved"
        try await db.toggleTodoCompleted(id: todo.id)
        let loaded = try await db.loadTodo(id: todo.id)
        XCTAssertEqual(loaded?.title, "keep me")
        XCTAssertEqual(loaded?.priority, .high)
        XCTAssertEqual(loaded?.isCompleted, true)
        XCTAssertNotNil(loaded?.completedAt)
        try await db.toggleTodoCompleted(id: todo.id)
        let open = try await db.loadTodo(id: todo.id)
        XCTAssertEqual(open?.isCompleted, false)
        XCTAssertNil(open?.completedAt)
        XCTAssertEqual(open?.title, "keep me")
    }

    func testLoadIncompleteTodoDropsCompletedAt() async throws {
        let db = try makeDB()
        let todo = TodoItem(title: "task", isCompleted: true, completedAt: Date())
        try await db.saveTodo(todo)
        await db.close()

        let conn = try SQLConnection.testConnection(path: tempDir.appendingPathComponent("test.db").path)
        try conn.exec("UPDATE todo_items SET is_completed = 0")
        conn.close()

        let reopened = try makeDB()
        let loaded = try await reopened.loadTodo(id: todo.id)
        XCTAssertEqual(loaded?.isCompleted, false)
        XCTAssertNil(loaded?.completedAt)
    }

    func testCascadeDeleteRemovesJunction() async throws {
        let db = try makeDB()
        let patient = samplePatient()
        try await db.savePatient(patient)
        var note = Note(title: "n", content: "c")
        note.mentionedPatients = [patient.id]
        try await db.saveNote(note)

        let links = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(links, 1)

        try await db.deletePatient(id: patient.id)
        let afterDelete = try await db.noteLinkCount(noteId: note.id)
        XCTAssertEqual(afterDelete, 0)
        let notes = try await db.loadAllNotes()
        XCTAssertEqual(notes.count, 1)
    }

    func testFTSPatientSearch() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient(name: "Nikos"))
        try await db.savePatient(samplePatient(name: "Maria", amka: "99999999999"))

        let hits = try await db.searchPatients("Nikos")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.profile.firstName, "Nikos")

        let phoneHits = try await db.searchPatients("6900000000")
        XCTAssertEqual(phoneHits.count, 2, "both patients share this phone")

        let emailHits = try await db.searchPatients("maria@example.com")
        XCTAssertEqual(emailHits.count, 1)
        XCTAssertEqual(emailHits.first?.profile.firstName, "Maria")
    }

    /// savePatient upserts, so the FTS row must be rewritten by the UPDATE
    /// trigger. A stale index would keep matching the old name forever.
    func testRenamedPatientDropsOldNameFromFTS() async throws {
        let db = try makeDB()
        var patient = samplePatient(name: "Nikos")
        patient.profile.lastName = "Georgiou"
        // Neutral email: FTS indexes it too, so a name-derived address would
        // keep matching the old name and mask a genuinely stale index row.
        patient.profile.email = "contact@example.com"
        try await db.savePatient(patient)
        let before = try await db.searchPatients("Nikos")
        XCTAssertEqual(before.count, 1)

        patient.profile.firstName = "Dimitris"
        patient.profile.lastName = "Pappas"
        try await db.savePatient(patient)

        let oldFirst = try await db.searchPatients("Nikos")
        XCTAssertTrue(oldFirst.isEmpty, "stale FTS row still matches the old first name")
        let oldLast = try await db.searchPatients("Georgiou")
        XCTAssertTrue(oldLast.isEmpty, "stale FTS row still matches the old last name")
        let renamed = try await db.searchPatients("Dimitris")
        XCTAssertEqual(renamed.map(\.profile.lastName), ["Pappas"])
        let fullName = try await db.searchPatients("Dimitris Pappas")
        XCTAssertEqual(fullName.count, 1, "full_name must be recomputed by the trigger")
    }

    func testPatientSearchDoesNotStopAtFiftyMatches() async throws {
        let db = try makeDB()
        for i in 0..<60 {
            try await db.savePatient(samplePatient(name: "Nikos", amka: String(format: "100000000%02d", i)))
        }
        let hits = try await db.searchPatients("Nikos")
        XCTAssertEqual(hits.count, 60)
    }

    func testPatientSearchMatchesFathersName() async throws {
        let db = try makeDB()
        var named = samplePatient(name: "Nikos", amka: "11111111111")
        named.profile.fathersName = "Georgios"
        try await db.savePatient(named)
        try await db.savePatient(samplePatient(name: "Maria", amka: "22222222222"))

        let hits = try await db.searchPatients("Georgios")
        XCTAssertEqual(hits.map(\.profile.firstName), ["Nikos"])

        let mixed = try await db.searchPatients("Nikos Georgios")
        XCTAssertEqual(mixed.map(\.profile.firstName), ["Nikos"])
    }

    func testPatientSearchMatchesGreekFathersNameCaseInsensitively() async throws {
        let db = try makeDB()
        var named = samplePatient(name: "Nikos", amka: "11111111111")
        named.profile.fathersName = "Γεώργιος"
        try await db.savePatient(named)
        try await db.savePatient(samplePatient(name: "Maria", amka: "22222222222"))

        let hits = try await db.searchPatients("γεώργιος")
        XCTAssertEqual(hits.map(\.profile.firstName), ["Nikos"])
    }

    func testFTSPunctuationOnlyQueryReturnsEmpty() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient(name: "Nikos"))
        try await db.saveNote(Note(title: "Lisinopril review", content: "check"))

        let patients = try await db.searchPatients("!!!")
        XCTAssertTrue(patients.isEmpty)
        let notes = try await db.searchNotes("???")
        XCTAssertTrue(notes.isEmpty)
    }

    func testWhitespaceAMKADoesNotCollide() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient(name: "One", amka: "   "))
        try await db.savePatient(samplePatient(name: "Two", amka: "   "))
        let count = try await db.loadAllPatients().count
        XCTAssertEqual(count, 2)
    }

    func testFTSNoteSearch() async throws {
        let db = try makeDB()
        try await db.saveNote(Note(title: "Lisinopril review",
                                   content: "Blood pressure medication effectiveness check"))
        try await db.saveNote(Note(title: "Groceries", content: "milk eggs bread"))

        let medHits = try await db.searchNotes("lisinopril")
        XCTAssertEqual(medHits.count, 1)
        XCTAssertEqual(medNotesTitles(medHits), ["Lisinopril review"])

        let empty = try await db.searchNotes("zzzznotfound")
        XCTAssertTrue(empty.isEmpty)
    }

    func testFTSNoteSearchMatchesMentionedPatientName() async throws {
        let db = try makeDB()
        let patient = samplePatient(name: "Nikos")
        try await db.savePatient(patient)
        var note = Note(title: "Follow-up", content: "no name in body")
        note.mentionedPatients = [patient.id]
        try await db.saveNote(note)
        try await db.saveNote(Note(title: "Unrelated", content: "other"))

        let hits = try await db.searchNotes("Nikos")
        XCTAssertEqual(hits.map(\.id), [note.id])
    }

    func testFTSNoteSearchMatchesMentionedPatientFathersName() async throws {
        let db = try makeDB()
        var patient = samplePatient(name: "Nikos")
        patient.profile.fathersName = "Georgios"
        try await db.savePatient(patient)
        var note = Note(title: "Follow-up", content: "no name in body")
        note.mentionedPatients = [patient.id]
        try await db.saveNote(note)
        try await db.saveNote(Note(title: "Unrelated", content: "other"))

        let hits = try await db.searchNotes("Georgios")
        XCTAssertEqual(hits.map(\.id), [note.id])

        let mixed = try await db.searchNotes("Nikos Georgios")
        XCTAssertEqual(mixed.map(\.id), [note.id])
    }

    func testAuditLogWritten() async throws {
        let db = try makeDB()
        let entry = AuditLogEntry(action: "test_action", entityType: "patient",
                                  entityId: UUID().uuidString, details: "hello")
        try await db.logAudit(entry)
        let logs = try await db.recentAuditLogs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.action, "test_action")
    }

    func testEventDateRangeQuery() async throws {
        let db = try makeDB()

        let now = Date()
        let inRange = CalendarEvent(
            title: "inside", startDate: now, endDate: now.addingTimeInterval(3600))
        try await db.saveEvent(inRange)
        let farFuture = Calendar(
            identifier: .gregorian).date(byAdding: .year, value: 2, to: now)!
        let outOfRange = CalendarEvent(
            title: "outside", startDate: farFuture, endDate: farFuture.addingTimeInterval(3600))
        try await db.saveEvent(outOfRange)

        let results = try await db.loadEvents(
            from: now.addingTimeInterval(-3600),
            to: now.addingTimeInterval(86400 * 7))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "inside")

        let spanning = CalendarEvent(
            title: "spans",
            startDate: now.addingTimeInterval(-86400 * 2),
            endDate: now.addingTimeInterval(86400 * 2))
        try await db.saveEvent(spanning)
        let overlapping = try await db.loadEvents(
            from: now.addingTimeInterval(-3600),
            to: now.addingTimeInterval(86400 * 7))
        XCTAssertEqual(Set(overlapping.map(\.title)), Set(["inside", "spans"]))
    }

    func testCheckpointProducesCleanCopy() async throws {
        let db = try makeDB()
        try await db.savePatient(samplePatient())
        try await db.checkpoint()
        let walPath = tempDir.appendingPathComponent("test.db-wal").path
        // No log file is as clean as an empty one.
        let size = FileManager.default.fileExists(atPath: walPath)
            ? try FileManager.default.attributesOfItem(atPath: walPath)[.size] as? Int ?? -1
            : 0
        XCTAssertEqual(size, 0, "nothing is left in the write-ahead log after a checkpoint")
    }

    private func medNotesTitles(_ notes: [Note]) -> [String] {
        notes.map(\.title)
    }
}

extension Patient {
    func msNormalized() -> Patient {
        func ms(_ d: Date) -> Date {
            Date(timeIntervalSince1970: (d.timeIntervalSince1970 * 1000).rounded() / 1000)
        }
        var copy = self
        copy.createdAt = ms(createdAt)
        copy.lastModified = ms(lastModified)
        copy.profile.dateOfBirth = ms(profile.dateOfBirth)
        return copy
    }
}
