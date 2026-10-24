import AppKit
import SwiftUI

/// Offscreen renders of the record editors — patient, todo, event — blank and
/// filled — and of the patient record view, light and dark, at the two
/// detail-column widths the split view spans, plus the three Settings panes
/// at the settings window's width.
/// Review artefacts for UI work; no Screen Recording grant needed.
///
/// `ImageRenderer` skips AppKit-backed controls (grouped `Form`, bezeled text
/// fields, popup buttons), which is exactly what the editors are made of, so
/// each view is hosted in an `NSHostingView` inside an off-screen window and
/// its display tree is drawn into a bitmap. Nothing is captured from the
/// screen. Like `render_rows.swift`, this host never constructs an
/// `AppSession`: the forms take a binding and a few closures instead.
@main
enum RenderEditors {
    /// Copied from `Assets.xcassets/AccentColor.colorset` — this host compiles
    /// no asset catalog, so `Color.accentColor` would fall back to system blue.
    static let accentLight = Color(.sRGB, red: 0.051, green: 0.478, blue: 0.447)
    static let accentDark = Color(.sRGB, red: 0.239, green: 0.812, blue: 0.761)

    /// Detail column at the 1000pt minimum window and at the 1280pt default.
    static let widths: [CGFloat] = [580, 744]

    @MainActor
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1]
            : FileManager.default.currentDirectoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true)

        let patients = SampleData.makePatients(anchor: SampleData.anchor(for: Date()))
        var written = 0
        for scheme in [ColorScheme.light, .dark] {
            for width in widths {
                for editorCase in EditorCase.all(patients: patients) {
                    // A pane with a width of its own renders once, not per
                    // detail width.
                    if editorCase.width != nil, width != widths[0] { continue }
                    let renderWidth = editorCase.width ?? width
                    written += snapshot(
                        editorCase.view,
                        size: CGSize(width: renderWidth, height: editorCase.height),
                        scheme: scheme,
                        name: "\(editorCase.name)-\(Int(renderWidth))",
                        into: outputDirectory)
                }
            }
        }
        print("✅ wrote \(written) PNG(s) to \(outputDirectory.path)")
        print("   Editors covered: PatientEditorForm, TodoEditorForm, EventEditorForm;")
        print("   Settings panes: General, Templates, Sync, Data; the integrity banner.")
    }

    /// Draws the hosting view's display tree at 2x. The window sits far off
    /// screen; it exists only so AppKit performs layout.
    @MainActor
    static func snapshot(_ view: AnyView, size: CGSize, scheme: ColorScheme,
                         name: String, into directory: URL) -> Int {
        let isDark = scheme == .dark
        // Top-aligned: a view with a height of its own (the Settings panes)
        // sits where the window would put it, not centred in the host.
        let root = view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(isDark ? accentDark : accentLight)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()

        // Let SwiftUI and the table-backed Form settle before drawing.
        for _ in 0..<3 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            print("⚠️  could not allocate bitmap for \(name)")
            window.orderOut(nil)
            return 0
        }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)

        let file = directory.appendingPathComponent("\(name)-\(isDark ? "dark" : "light").png")
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("⚠️  could not encode \(file.lastPathComponent)")
            return 0
        }
        do {
            try png.write(to: file)
            return 1
        } catch {
            print("⚠️  could not write \(file.lastPathComponent): \(error.localizedDescription)")
            return 0
        }
    }
}

/// One editor or pane in one state worth looking at.
struct EditorCase {
    let name: String
    let height: CGFloat
    let view: AnyView
    /// Set for views with a width of their own (the Settings panes); nil
    /// renders at each detail-column width.
    var width: CGFloat? = nil

    @MainActor
    static func all(patients: [Patient]) -> [EditorCase] {
        let day: TimeInterval = 24 * 3600

        var filled = patients[0]
        filled.profile.fathersName = "Νικόλαος"
        filled.profile.address = Address(street: "Λεωφ. Κηφισίας 12", city: "Αθήνα",
                                         postalCode: "115 26", region: "Αττική", country: "Ελλάδα")
        filled.medical.allergies = [Allergy(allergen: "Πενικιλλίνη", severity: .severe, reaction: "Εξάνθημα")]
        filled.medical.medications = [
            Medication(name: "Μετφορμίνη", dosage: "850 mg", frequency: "2× ημερησίως"),
            Medication(name: "Ραμιπρίλη", dosage: "5 mg", frequency: "1× ημερησίως")
        ]

        // A mistyped check digit while the date of birth is still unknown, so
        // both the warning and the "use from AMKA" offer show.
        var mistyped = Patient.newRecord()
        mistyped.profile.firstName = "Νίκος"
        mistyped.profile.lastName = "Σταυρίδης"
        mistyped.profile.amka = "12047812345"

        // Someone else's AMKA on a record whose birth date disagrees with it.
        var duplicate = patients[1]
        duplicate.profile.amka = patients[0].profile.amka

        // An archived record reads, but does not edit, until it is restored.
        var archived = patients[3]
        archived.isArchived = true

        let filledTodo = TodoItem(
            title: "Chase renal panel results", priority: .high,
            dueDate: Date().addingTimeInterval(-2 * day),
            notes: "Lab called; sample re-drawn Tuesday.",
            patientName: patients[0].displayName, patientId: patients[0].id,
            tags: ["labs", "urgent", "nephrology"])
        let filledEvent = CalendarEvent(
            title: "Post-op review", description: "Check wound, remove sutures if healed.",
            startDate: Date().addingTimeInterval(3 * day),
            endDate: Date().addingTimeInterval(3 * day + 1800),
            patientId: patients[1].id, eventType: .surgery)

        // The Templates pane over the shipped set with one built-in edited
        // and one custom template, so every row style shows.
        var editedAdmission = TemplateService.builtIns[1]
        editedAdmission.content += "\n## Ward round\n"
        let templateSet = [
            TemplateService.builtIns[0], editedAdmission, TemplateService.builtIns[2],
            NoteTemplate(id: NoteTemplate.customIDPrefix + "demo", name: "Ward round",
                         kind: .custom, content: "# Ward round — {{patient}}\n_{{date}}_\n\n- ")
        ]

        // The Data pane over a store the size of a busy practice, checked
        // once clean and once with a broken link, so both outcomes are seen.
        let containerRoot = URL(fileURLWithPath: DataSettingsPane.userHomePath)
            .appendingPathComponent("Library/Containers/com.johnteam.MedNotes/Data/Library/Application Support/com.johnteam.MedNotes")
        let storage = StorageSummary(
            rootURL: containerRoot,
            backupsURL: containerRoot.appendingPathComponent("Backups"),
            counts: ["patients": 412, "notes": 1893, "todo_items": 37, "calendar_events": 640, "audit_logs": 9000],
            lastBackup: StorageSummary.LastBackup(date: Date().addingTimeInterval(-3 * day),
                                                  name: "practice.mednotesbackup"))
        let restorePoints = [
            RestorePoint(url: containerRoot.appendingPathComponent("Backups/backup_2026-09-12_10-00-00_abcd1234"),
                         createdAt: Date().addingTimeInterval(-2 * 3600), name: "Pre-restore snapshot",
                         counts: ["patients": 412, "notes": 1893, "todo_items": 37, "calendar_events": 640],
                         sizeBytes: 184_000_000),
            RestorePoint(url: containerRoot.appendingPathComponent("Backups/backup_2026-09-01_09-30-00_ef015678"),
                         createdAt: Date().addingTimeInterval(-11 * day), name: "Pre-import snapshot",
                         counts: ["patients": 410, "notes": 1850, "todo_items": 35, "calendar_events": 610],
                         sizeBytes: 181_000_000)
        ]
        var overdue = storage
        overdue.lastBackup = StorageSummary.LastBackup(date: Date().addingTimeInterval(-45 * day),
                                                       name: "practice.mednotesbackup")
        let clean = IntegrityReport(passed: true, checkedAt: Date(), detail: "No problems found.")
        let broken = IntegrityReport(passed: false, checkedAt: Date(),
                                     detail: "2 records point to a patient that no longer exists.")

        return [
            EditorCase(name: "editor-patient-new", height: 1400,
                       view: AnyView(PatientHost(patient: Patient.newRecord(), others: patients))),
            EditorCase(name: "editor-patient-filled", height: 1400,
                       view: AnyView(PatientHost(patient: filled, others: patients))),
            EditorCase(name: "editor-patient-expanded", height: 2100,
                       view: AnyView(PatientHost(
                           patient: filled, others: patients,
                           expanded: Set([filled.medical.conditions[1].id,
                                          filled.medical.allergies[0].id,
                                          filled.medical.medications[0].id])))),
            EditorCase(name: "editor-patient-amka-mistyped", height: 520,
                       view: AnyView(PatientHost(patient: mistyped, others: patients))),
            EditorCase(name: "editor-patient-amka-duplicate", height: 520,
                       view: AnyView(PatientHost(patient: duplicate, others: patients))),
            EditorCase(name: "editor-patient-archived", height: 720,
                       view: AnyView(PatientHost(patient: archived, others: patients).disabled(true))),
            EditorCase(name: "record-patient-filled", height: 1400,
                       view: AnyView(PatientRecordHost(patient: filled))),
            EditorCase(name: "record-patient-sparse", height: 900,
                       view: AnyView(PatientRecordHost(patient: patients.min {
                           PatientRecordFields($0).sections.count < PatientRecordFields($1).sections.count
                       } ?? filled))),
            EditorCase(name: "editor-todo-new", height: 820,
                       view: AnyView(TodoHost(todo: TodoItem.newRecord(), patients: patients))),
            EditorCase(name: "editor-todo-filled", height: 820,
                       view: AnyView(TodoHost(todo: filledTodo, patients: patients))),
            EditorCase(name: "editor-event-new", height: 820,
                       view: AnyView(EventHost(event: CalendarEvent.newRecord(), patients: patients))),
            EditorCase(name: "editor-event-filled", height: 820,
                       view: AnyView(EventHost(event: filledEvent, patients: patients))),
            EditorCase(name: "record-event-filled", height: 620,
                       view: AnyView(EventRecordView(event: filledEvent,
                                                     patientName: patients.first.map { DisplayCopy.patient($0) },
                                                     onOpenPatient: {}))),
            EditorCase(name: "record-event-allday", height: 420,
                       view: AnyView(EventRecordView(event: CalendarEvent(
                           title: "Study leave", startDate: Date(), endDate: Date().addingTimeInterval(2 * 86_400),
                           isAllDay: true, eventType: .customEvent)))),
            EditorCase(name: "integrity-banner", height: 44,
                       view: AnyView(IntegrityBanner(
                           message: "2 records point to a patient that no longer exists.", onDismiss: {})),
                       width: 1000),
            EditorCase(name: "settings-general", height: GeneralSettingsPane.height,
                       view: AnyView(GeneralSettingsHost(launch: .default, isEncrypted: true)),
                       width: SettingsView.width),
            EditorCase(name: "settings-templates", height: TemplatesSettingsPane.height,
                       view: AnyView(TemplatesSettingsHost(templates: templateSet, defaultID: "tpl-soap")),
                       width: SettingsView.width),
            EditorCase(name: "settings-sync", height: 640,
                       view: AnyView(SyncSettingsHost(calendarSummary: "pushed 2, updated 1")),
                       width: SettingsView.width),
            EditorCase(name: "settings-data-clean", height: 920,
                       view: AnyView(DataSettingsPane(loadSummary: { storage },
                                                      loadRestorePoints: { restorePoints },
                                                      checkIntegrity: { clean }, initialIntegrity: clean)),
                       width: SettingsView.width),
            EditorCase(name: "settings-data-broken", height: 920,
                       view: AnyView(DataSettingsPane(loadSummary: { overdue },
                                                      loadRestorePoints: { restorePoints },
                                                      checkIntegrity: { broken }, initialIntegrity: broken)),
                       width: SettingsView.width)
        ]
    }
}

// The Settings panes are driven the same way: state lives in the host.

struct TemplatesSettingsHost: View {
    let templates: [NoteTemplate]
    @State var defaultID: String?

    var body: some View {
        TemplatesSettingsPane(actions: .inMemory(templates), defaultTemplateID: $defaultID)
    }
}

struct GeneralSettingsHost: View {
    @State var launch: LaunchModule
    let isEncrypted: Bool

    var body: some View {
        GeneralSettingsPane(launchModule: $launch, isEncrypted: isEncrypted, idleMinutes: 5)
    }
}

/// The bridges report whatever TCC says about this unsigned host — normally
/// "not connected" — which is the state a first launch shows anyway.
struct SyncSettingsHost: View {
    @StateObject private var calendar = AppleCalendarService()
    @StateObject private var reminders = AppleRemindersService()
    @State private var calendarAutoSync = true
    @State private var remindersAutoSync = false
    let calendarSummary: String?

    var body: some View {
        SyncSettingsPane(
            calendar: calendar, reminders: reminders,
            destinations: [
                .calendar: SyncDestinationViewState(
                    calendarTitle: "MedNotes", sourceTitle: "iCloud", sourceType: "calDAV",
                    state: .confirmed, appCreated: true)
            ],
            calendarSummary: calendarSummary, remindersSummary: nil,
            calendarAutoSync: $calendarAutoSync, remindersAutoSync: $remindersAutoSync,
            onSyncCalendar: {}, onSyncReminders: {})
    }
}

// Hosts own the draft so the forms render without a session.

struct PatientRecordHost: View {
    @State var patient: Patient
    var body: some View { PatientRecordView(patient: $patient, onEdit: {}) }
}

struct PatientHost: View {
    @State var patient: Patient
    let others: [Patient]
    var expanded: Set<UUID> = []

    var body: some View {
        PatientEditorForm(
            draft: $patient,
            duplicateAMKA: { amka in
                others.first { $0.id != patient.id && AMKA.normalized($0.profile.amka) == amka }
            },
            expandedMedicalRows: expanded
        )
    }
}

struct TodoHost: View {
    @State var todo: TodoItem
    let patients: [Patient]

    var body: some View {
        TodoEditorForm(
            draft: $todo,
            patientOptions: patients,
            isKnownPatient: { id in patients.contains { $0.id == id } },
            onSetCompleted: { done in
                todo.isCompleted = done
                todo.completedAt = done ? Date() : nil
            }
        )
    }
}

struct EventHost: View {
    @State var event: CalendarEvent
    let patients: [Patient]

    var body: some View {
        EventEditorForm(
            draft: $event,
            patientOptions: patients,
            isKnownPatient: { id in patients.contains { $0.id == id } }
        )
    }
}
