#if DEBUG

import Foundation

/// Deterministic sample content for `--preview-seed` launches.
///
/// The point is not volume but awkwardness: empty names, six tags, bodies that
/// open on front-matter or a code fence, every todo priority crossed with every
/// due state. An empty store shows only empty states, and a store full of tidy
/// records shows only the easy half of every row.
///
/// Everything is written through the real services, so foreign keys, vault
/// mirroring and wiki-link resolution run on the paths the app actually uses
/// rather than on a seeding-only shortcut.
enum SampleData {

    // MARK: - Entry point

    static func isEmpty(_ store: AppStore) async throws -> Bool {
        let counts = try await store.counts()
        return ["patients", "notes", "todo_items", "calendar_events"]
            .allSatisfy { (counts[$0] ?? 0) == 0 }
    }

    /// Seeds in dependency order: patients first (todos and events carry patient
    /// foreign keys), then notes whose titles are `[[link]]` targets, then the
    /// notes that link to them — so link resolution is reviewed on links that
    /// resolve, not only on broken ones.
    @discardableResult
    static func seed(into store: AppStore, now: Date = Date()) async throws -> Summary {
        let anchor = Self.anchor(for: now)

        let patients = makePatients(anchor: anchor)
        for patient in patients {
            try await store.patients.save(patient)
        }

        let notes = makeNotes(anchor: anchor, patients: patients)
        for note in notes {
            try await save(note, into: store)
        }

        let todos = makeTodos(anchor: anchor, patients: patients)
        for todo in todos {
            try await store.todos.save(todo)
        }

        let events = makeEvents(anchor: anchor, patients: patients)
        for event in events {
            _ = try await store.events.save(event)
        }

        return Summary(
            patients: patients.count, notes: notes.count,
            todos: todos.count, events: events.count)
    }

    struct Summary: Sendable, Equatable {
        let patients: Int
        let notes: Int
        let todos: Int
        let events: Int
    }

    /// Truncated, not `date(bySetting:)` — that searches *forward* for the next
    /// matching minute, which can land the anchor up to an hour ahead and render
    /// every backdated note as "in 57 minutes".
    static func anchor(for now: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: now)) ?? now
    }

    /// The `updatedAt` each note is *meant* to carry, keyed by title. Exposed so
    /// a test can prove the backdating pass in `save(_:into:)` actually stuck,
    /// rather than settling for "differs from now".
    static func expectedNoteTimestamps(now: Date) -> [String: Date] {
        let anchor = Self.anchor(for: now)
        let notes = makeNotes(anchor: anchor, patients: makePatients(anchor: anchor))
        return Dictionary(uniqueKeysWithValues: notes.map { ($0.title, $0.updatedAt) })
    }

    // MARK: - Notes need their timestamps put back

    /// `NoteService.save` stamps `updatedAt = Date()` unconditionally, which is
    /// right for a user edit and wrong for a seed: every row would read "just
    /// now", and the notes list sorts on `is_pinned DESC, updated_at DESC`, so
    /// both the stamps and the ordering under review would be flattened.
    ///
    /// The service save runs the real path (link resolution included); the raw
    /// write then restores the intended timestamp.
    private static func save(_ note: Note, into store: AppStore) async throws {
        try await store.notes.save(note)
        try await store.db.saveNote(note)
    }

    // MARK: - Patients

    static func makePatients(anchor: Date) -> [Patient] {
        [
            person("Γεώργιος", "Παπαδόπουλος", age: 64, amka: "12047812347",
                   phone: "6944012345", anchor: anchor,
                   conditions: [("Υπέρταση", .active), ("Διαβήτης τύπου 2", .chronic),
                                ("Δυσλιπιδαιμία", .active), ("Οστεοαρθρίτιδα", .active)]),
            person("Μαρία", "Αντωνοπούλου", age: 47, amka: "03047711225",
                   phone: "6970112233", anchor: anchor,
                   conditions: [("Σιδηροπενική αναιμία", .active)]),
            person("Ελένη", "Κωνσταντινοπούλου-Χατζηγεωργίου", age: 38,
                   amka: "22118604416", phone: "6988445566", anchor: anchor,
                   conditions: [("Θυρεοειδίτιδα Hashimoto", .chronic)]),
            person("Δημήτρης", "Νικολάου", age: 71, amka: "05045211983",
                   phone: "", anchor: anchor,
                   conditions: [("Κολπική μαρμαρυγή", .active), ("ΧΑΠ", .chronic),
                                ("Χρόνια νεφρική νόσος", .active)]),
            person("Σοφία", "Βασιλείου", age: 29, amka: "", phone: "6912345678",
                   anchor: anchor, conditions: []),
            person("Ανδρέας", "Μακρής", age: 55, amka: "18046911006", phone: "2109988776",
                   anchor: anchor, conditions: [("Ουρική αρθρίτιδα", .inactive)]),
            person("Κατερίνα", "Ιωάννου", age: 33, amka: "07039100446", phone: "",
                   anchor: anchor, conditions: []),
            person("Νίκος", "Σταυρίδης", age: 8, amka: "14011612000", phone: "6945550001",
                   anchor: anchor, conditions: [("Άσθμα", .active)]),
            // Unnamed on purpose: DisplayCopy.patient falls back to "Unnamed Patient",
            // and the row must still lay out with an initials-less monogram.
            person("", "", age: 0, amka: "", phone: "", anchor: anchor,
                   conditions: [], knownDateOfBirth: false),
            person("Αναστασία", "Ρούσσου", age: 82, amka: "30044012877",
                   phone: "6976543210", anchor: anchor,
                   conditions: [("Καρδιακή ανεπάρκεια", .active),
                                ("Οστεοπόρωση", .chronic), ("Καταρράκτης", .resolved)]),
            person("Παύλος", "Δημητρίου", age: 41, amka: "11048300559", phone: "6900123456",
                   anchor: anchor, conditions: [("Ημικρανία", .active)]),
            person("Χριστίνα", "Λαμπροπούλου", age: 26, amka: "26049812337", phone: "",
                   anchor: anchor, conditions: [])
        ]
    }

    private static func person(
        _ first: String, _ last: String, age: Int, amka: String, phone: String,
        anchor: Date, conditions: [(String, ConditionStatus)],
        knownDateOfBirth: Bool = true
    ) -> Patient {
        // Epoch-0 is the app's missing-DOB sentinel; the row then shows no age.
        let dob = knownDateOfBirth
            ? (Calendar.current.date(byAdding: .year, value: -age, to: anchor) ?? anchor)
            : Date(timeIntervalSince1970: 0)
        // A sample AMKA encodes the sample birth date, as a real one does, so
        // the editor's advisory check reads clean on review data; only the
        // serial digits of the literal above survive.
        let encodedAMKA = amka.isEmpty ? "" : Self.amka(encoding: dob, serial: String(amka.dropFirst(6).prefix(4)))
        let profile = PatientProfile(
            firstName: first, lastName: last, dateOfBirth: dob,
            gender: .preferNotToSay, amka: encodedAMKA, phone: phone,
            email: first.isEmpty ? "" : "\(encodedAMKA)@example.invalid")
        let medical = MedicalInfo(conditions: conditions.map {
            MedicalCondition(name: $0.0, status: $0.1)
        })
        return Patient(profile: profile, medical: medical,
                       createdAt: anchor, lastModified: anchor)
    }

    /// A well-formed AMKA: the birth date as DDMMYY, the serial, a Luhn digit.
    static func amka(encoding dateOfBirth: Date, serial: String) -> String {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.day, .month, .year], from: dateOfBirth)
        let prefix = String(format: "%02d%02d%02d", parts.day ?? 1, parts.month ?? 1, (parts.year ?? 2000) % 100)
            + serial
        return prefix + String(AMKA.checkDigit(for: prefix) ?? "0")
    }

    // MARK: - Notes

    static func makeNotes(anchor: Date, patients: [Patient]) -> [Note] {
        let linkTargetTitle = "Ward round protocol"
        let linkedPatient = patients[0].displayName

        func back(_ seconds: TimeInterval) -> Date { anchor.addingTimeInterval(-seconds) }
        let minute: TimeInterval = 60, hour = 3600.0, day = 86_400.0, week = 604_800.0

        return [
            // Seeded first: it is what the wiki-links below resolve against.
            Note(title: linkTargetTitle,
                 content: """
                 Morning round order: ICU, then step-down, then ward.
                 Escalate anything with a MEWS above 4 before moving on.
                 """,
                 createdAt: back(6 * week), updatedAt: back(3 * week),
                 tags: ["protocol"]),

            Note(title: "Cardiology follow-up",
                 content: """
                 ---
                 title: Cardiology follow-up
                 tags: [cardio]
                 ---

                 # Assessment

                 Patient reports **improved** exertional dyspnea since the dose change.
                 NYHA II. Continue current regimen and reassess in six weeks.
                 """,
                 createdAt: back(4 * hour), updatedAt: back(12 * minute),
                 tags: ["cardio", "follow-up"], isPinned: true),

            Note(title: "Round notes — north ward",
                 content: """
                 Followed [[\(linkTargetTitle)]] as usual. Discussed
                 [[\(linkedPatient)]] with the registrar; awaiting renal panel.
                 """,
                 createdAt: back(2 * day), updatedAt: back(2 * hour),
                 tags: ["rounds"], isPinned: true),

            Note(title: "Lab query template",
                 content: """
                 ```sql
                 SELECT * FROM labs WHERE patient_id = ? ORDER BY drawn_at DESC;
                 ```

                 Repeat the metabolic panel in six weeks and flag anything trending.
                 """,
                 createdAt: back(3 * week), updatedAt: back(5 * hour),
                 tags: ["labs", "sql"]),

            Note(title: "Discharge checklist",
                 content: """
                 - [ ] Medication reconciliation
                 - [x] Family briefed
                 - [ ] Transport arranged
                 1. Print summary for the GP
                 """,
                 createdAt: back(day), updatedAt: back(40 * minute),
                 tags: ["discharge", "checklist", "ward", "admin", "template", "draft"]),

            // The stripper must keep "#tag" (no space) while dropping "# heading".
            Note(title: "Tagging convention",
                 content: "#cardiology and #respiratory are the two we actually use.",
                 createdAt: back(5 * week), updatedAt: back(6 * day),
                 tags: ["meta"]),

            Note(title: "Guideline links",
                 content: """
                 See [the 2024 guideline](https://example.invalid/guideline) and set
                 `dose = 5mg` daily unless eGFR is below 30.
                 """,
                 createdAt: back(2 * week), updatedAt: back(9 * hour),
                 tags: ["reference"]),

            Note(title: "Handover",
                 content: """
                 ---
                 > Prior shift reported the patient stable overnight.

                 ***

                 ## Plan
                 Continue observation; no new orders.
                 """,
                 createdAt: back(8 * hour), updatedAt: back(3 * minute),
                 tags: ["handover"], isPinned: true),

            Note(title: "Untitled thoughts on triage",
                 content: """
                 Triage is mostly about who *cannot* wait, not who arrived first.
                 The queue lies; the observations do not.
                 """,
                 createdAt: back(3 * day), updatedAt: back(day),
                 tags: []),

            // Empty body: the row must collapse the preview line, not leave a gap.
            Note(title: "Placeholder", content: "",
                 createdAt: back(week), updatedAt: back(4 * day), tags: ["todo"]),

            Note(title: "", content: "Body with no title — the row falls back to “Untitled”.",
                 createdAt: back(11 * day), updatedAt: back(2 * week), tags: []),

            Note(title: "Equipment request",
                 content: "Two more infusion pumps for the north ward; ordered 12 Aug.",
                 createdAt: back(6 * week), updatedAt: back(5 * week),
                 tags: ["admin", "kit"]),

            Note(title: "Antibiotic stewardship",
                 content: """
                 ![chart](chart.png)

                 De-escalate within 48h where cultures allow. ~~Ceftriaxone by default~~
                 is no longer the local policy.
                 """,
                 createdAt: back(9 * week), updatedAt: back(7 * week),
                 tags: ["abx", "policy", "audit"]),

            Note(title: "Teaching session",
                 content: "ECG interpretation, Thursday 14:00, seminar room 2.",
                 createdAt: back(14 * week), updatedAt: back(13 * week),
                 tags: ["teaching"])
        ]
    }

    // MARK: - Todos

    private static func makeTodos(anchor: Date, patients: [Patient]) -> [TodoItem] {
        let cal = Calendar.current
        func day(_ offset: Int) -> Date {
            cal.date(byAdding: .day, value: offset, to: anchor) ?? anchor
        }

        // Every priority crossed with every due state, so the Low-priority pill
        // being absent is visible next to Medium and High rows that show one.
        return [
            TodoItem(title: "Chase renal panel", createdAt: day(-9), priority: .high,
                     dueDate: day(-3), patientId: patients[0].id, tags: ["labs", "urgent"]),
            TodoItem(title: "Sign discharge summary", createdAt: day(-6),
                     priority: .medium, dueDate: day(-1), patientId: patients[3].id,
                     tags: ["discharge"]),
            TodoItem(title: "Tidy the drug fridge log", createdAt: day(-20),
                     priority: .low, dueDate: day(-5), tags: ["admin"]),
            TodoItem(title: "Call about the echo slot", createdAt: day(-2),
                     priority: .high, dueDate: anchor, patientId: patients[9].id,
                     tags: ["cardio"]),
            TodoItem(title: "Review overnight observations", createdAt: day(-1),
                     priority: .medium, dueDate: anchor, tags: []),
            TodoItem(title: "Restock consult room 3", createdAt: day(-4),
                     priority: .low, dueDate: anchor, tags: ["kit", "ward"]),
            TodoItem(title: "Prepare teaching slides", createdAt: day(-3),
                     priority: .high, dueDate: day(2), tags: ["teaching"]),
            TodoItem(title: "Book the interpreter", createdAt: day(-3),
                     priority: .medium, dueDate: day(4), patientId: patients[2].id,
                     tags: ["admin", "access"]),
            TodoItem(title: "Update the ward noticeboard", createdAt: day(-8),
                     priority: .low, dueDate: day(9), tags: []),
            TodoItem(title: "Audit antibiotic durations", createdAt: day(-12),
                     priority: .medium, dueDate: day(21),
                     tags: ["abx", "audit", "policy", "quarterly", "governance"]),
            TodoItem(title: "Order spirometry cassettes", createdAt: day(-15),
                     priority: .low, tags: ["kit"]),
            TodoItem(title: "Chase histology", createdAt: day(-11), priority: .high,
                     patientId: patients[5].id, tags: ["path"]),
            TodoItem(title: "File the incident form", isCompleted: true,
                     createdAt: day(-14), completedAt: day(-13), priority: .high,
                     dueDate: day(-13), tags: ["governance"]),
            TodoItem(title: "Send GP letter", isCompleted: true, createdAt: day(-10),
                     completedAt: day(-9), priority: .medium, dueDate: day(-9),
                     patientId: patients[1].id, tags: ["correspondence"]),
            TodoItem(title: "Archive last quarter's rota", isCompleted: true,
                     createdAt: day(-30), completedAt: day(-28), priority: .low,
                     tags: ["admin"]),
            TodoItem(title: "Confirm the vaccine order arrived", createdAt: day(-5),
                     priority: .medium, dueDate: day(1), tags: ["vaccine"])
        ]
    }

    // MARK: - Events

    private static func makeEvents(anchor: Date, patients: [Patient]) -> [CalendarEvent] {
        let cal = Calendar.current
        // Built from components rather than `date(bySettingHour:)`, which also
        // searches forward and would silently push a morning slot to the next day.
        func at(_ dayOffset: Int, _ hour: Int, minutes: Int = 60) -> (Date, Date) {
            let base = cal.date(byAdding: .day, value: dayOffset, to: anchor) ?? anchor
            var components = cal.dateComponents([.year, .month, .day], from: base)
            components.hour = hour
            let start = cal.date(from: components) ?? base
            return (start, start.addingTimeInterval(TimeInterval(minutes) * 60))
        }

        // Spread across three months so the list renders more than one section header.
        let spec: [(String, Int, Int, EventType, Int?, Bool)] = [
            ("Καρδιολογικό ραντεβού", -38, 9, .appointment, 0, false),
            ("Post-op review", -33, 11, .checkup, 3, false),
            ("Εμβολιασμός γρίπης", -30, 15, .vaccine, 7, false),
            ("MDT meeting", -24, 8, .consultation, nil, false),
            ("Αιματολογικός έλεγχος", -18, 10, .labResult, 1, false),
            ("Αλλαγή αγωγής", -12, 13, .medicationChange, 0, false),
            ("Ward audit day", -9, 9, .observation, nil, true),
            ("Χειρουργείο — αρθροπλαστική", -6, 7, .surgery, 9, false),
            ("Follow-up call", -3, 16, .consultation, 2, false),
            ("Ετήσιος έλεγχος", -1, 12, .checkup, 4, false),
            ("Επίσκεψη ρουτίνας", 0, 10, .appointment, 5, false),
            ("Σπιρομέτρηση", 1, 14, .labResult, 7, false),
            ("Ενδοσκόπηση", 4, 8, .surgery, 3, false),
            ("Εμβόλιο αναμνηστική δόση", 7, 11, .vaccine, 11, false),
            ("Study leave", 9, 9, .customEvent, nil, true),
            ("Νευρολογική εκτίμηση", 13, 15, .consultation, 10, false),
            ("Αξιολόγηση πόνου", 19, 13, .observation, 9, false),
            ("Προεγχειρητικός έλεγχος", 26, 9, .checkup, 3, false),
            ("Τροποποίηση αντιπηκτικής αγωγής", 34, 10, .medicationChange, 0, false),
            ("Ετήσια ανασκόπηση φαρμάκων", 41, 16, .appointment, 1, false)
        ]

        return spec.map { title, dayOffset, hour, type, patientIndex, allDay in
            let (start, end) = at(dayOffset, hour)
            var event = CalendarEvent(
                title: title, startDate: start, endDate: end, isAllDay: allDay,
                patientId: patientIndex.map { patients[$0].id },
                eventType: type, createdAt: anchor, updatedAt: anchor)
            if allDay { event.setAllDay(true) }
            return event
        }
    }
}

#endif
