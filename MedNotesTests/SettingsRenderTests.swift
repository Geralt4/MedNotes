import AppKit
import SwiftUI
import XCTest
@testable import MedNotes

/// Settings coverage that does not depend on AppKit's view tree.
///
/// The four former subview-walking tests asserted on exact `NSPopUpButton`
/// titles, `NSSwitch` counts and `NSTextField` string values. Those are
/// implementation details of SwiftUI's AppKit backing, and they broke on
/// ordinary control changes (a picker gaining an item, a toggle becoming a
/// menu). The replacements below assert the values the panes are given and the
/// strings the shared formatters produce, plus one bitmap smoke test per pane
/// that only checks something rendered. Stable accessibility identifiers now
/// exist on the controls for any future UI-level test.
@MainActor
final class SettingsRenderTests: XCTestCase {
    private let offscreen = OffscreenHost()

    override func tearDown() {
        offscreen.tearDown()
    }

    // MARK: - View models

    func testGeneralPaneInputsDescribeTheSecurityPosture() {
        var launch = LaunchModule.fixed(.calendar)
        let pane = GeneralSettingsPane(
            launchModule: Binding(get: { launch }, set: { launch = $0 }),
            isEncrypted: true, idleMinutes: 5)
        XCTAssertEqual(launch, .fixed(.calendar))
        XCTAssertTrue(pane.isEncrypted)
        XCTAssertEqual(pane.idleMinutes, 5)
        XCTAssertEqual(SettingsIdentifiers.launchPicker, "settings.general.launchPicker")
        XCTAssertEqual(SettingsIdentifiers.storeState, "settings.general.storeState")
    }

    /// A Markdown export a lock cut short is said in the Data pane, which makes
    /// room for the caption. The session keeps the text across the lock's
    /// rebuild of the pane (`FilePanelLockTests`).
    func testDataPaneMakesRoomForAnInterruptedExport() {
        let report = IntegrityReport(passed: true, checkedAt: Date(), detail: "No problems found.")
        let plain = DataSettingsPane(loadSummary: { nil }, checkIntegrity: { report })
        let interrupted = DataSettingsPane(loadSummary: { nil }, checkIntegrity: { report },
                                           exportInterruption: "stopped")
        XCTAssertNil(plain.exportInterruption)
        XCTAssertEqual(interrupted.exportInterruption, "stopped")
        XCTAssertGreaterThan(interrupted.preferredHeight, plain.preferredHeight)
    }

    func testDataPaneFormatsCountsAndSizes() {
        XCTAssertEqual(
            BackupFlowSheet.summary(counts: ["patients": 12, "notes": 40, "todo_items": 8, "calendar_events": 172]),
            "12 patients · 40 notes · 8 todos · 172 events")
        XCTAssertEqual(DataSettingsPane.sizeText(3_400_000),
                       ByteCountFormatter.string(fromByteCount: 3_400_000, countStyle: .file))
        XCTAssertEqual(DataSettingsPane.sizeText(nil), "—")
    }

    func testDestinationStateDescribesConfirmedAndStaleConnections() {
        let confirmed = SyncDestinationViewState(
            calendarTitle: "MedNotes", sourceTitle: "iCloud", sourceType: "calDAV",
            state: .confirmed, appCreated: true)
        XCTAssertTrue(confirmed.statusText.contains("MedNotes"))
        let stale = SyncDestinationViewState(
            calendarTitle: "MedNotes", sourceTitle: "iCloud", sourceType: "calDAV",
            state: .needsReconnection, appCreated: false)
        XCTAssertEqual(stale.statusText, "Needs reconnection")
    }

    // MARK: - Render smoke tests

    func testEveryPaneRendersInk() {
        let general = offscreen.host(
            GeneralHost(launch: .fixed(.calendar), isEncrypted: true),
            width: SettingsView.width, height: 420)
        let templates = offscreen.host(
            TemplatesHost(templates: [TemplateService.builtIns[0]], defaultID: "tpl-soap"),
            width: SettingsView.width, height: TemplatesSettingsPane.height)
        let sync = offscreen.host(
            SyncHost(calendarSummary: "pushed 2, updated 1"),
            width: SettingsView.width, height: 640)
        let data = offscreen.host(
            DataHost(),
            width: SettingsView.width, height: 900)
        for (name, hosting) in [("general", general), ("templates", templates),
                                ("sync", sync), ("data", data)] {
            XCTAssertTrue(OffscreenHost.hasInk(hosting), "\(name) pane rendered blank")
        }
    }

    func testIntegrityBannerRenders() {
        let hosting = offscreen.host(
            IntegrityBanner(message: "2 records point to a patient that no longer exists.", onDismiss: {}),
            width: 1000, height: 60)
        XCTAssertTrue(OffscreenHost.hasInk(hosting), "integrity banner rendered blank")
    }

    // MARK: - Settings model behaviour

    func testBackupSummaryNamesEveryEntityKind() {
        let manifest = BackupManifest(
            name: "practice", createdAt: Date(), schemaVersion: Schema.currentVersion,
            counts: ["patients": 2, "notes": 3, "todo_items": 4, "calendar_events": 5])
        XCTAssertEqual(BackupFlowSheet.summary(of: manifest),
                       "2 patients · 3 notes · 4 todos · 5 events")
    }

    func testRestorePointSizeIsMeasuredForASingleFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("size-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("point.mnrp")
        try Data(repeating: 0x41, count: 2048).write(to: file)
        XCTAssertEqual(BackupService.sizeOnDisk(at: file), 2048)
        try? FileManager.default.removeItem(at: dir)
    }
}

// Hosts own the state so the panes render without a session.

private struct GeneralHost: View {
    @State var launch: LaunchModule
    let isEncrypted: Bool

    var body: some View {
        GeneralSettingsPane(launchModule: $launch, isEncrypted: isEncrypted, idleMinutes: 5)
    }
}

private struct TemplatesHost: View {
    let templates: [NoteTemplate]
    @State var defaultID: String?

    var body: some View {
        TemplatesSettingsPane(actions: .inMemory(templates), defaultTemplateID: $defaultID)
    }
}

private struct SyncHost: View {
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

private struct DataHost: View {
    var body: some View {
        let root = URL(fileURLWithPath: DataSettingsPane.userHomePath)
            .appendingPathComponent("Library/Containers/com.johnteam.MedNotes/Data/Library/Application Support/com.johnteam.MedNotes")
        let summary = StorageSummary(
            rootURL: root, backupsURL: root.appendingPathComponent("Backups"),
            counts: ["patients": 12, "notes": 40, "todo_items": 8, "calendar_events": 172, "audit_logs": 900],
            lastBackup: StorageSummary.LastBackup(date: Date().addingTimeInterval(-3600), name: "practice.mednotesbackup"))
        let point = RestorePoint(
            url: root.appendingPathComponent("RestorePoints/restore_2026-09-12_10-00-00_abcd1234.mnrp"),
            createdAt: Date().addingTimeInterval(-86_400), name: "restore_2026-09-12_10-00-00_abcd1234",
            counts: ["patients": 12], sizeBytes: 3_400_000)
        let report = IntegrityReport(passed: true, checkedAt: Date(), detail: "No problems found.")
        DataSettingsPane(loadSummary: { summary }, loadRestorePoints: { [point] },
                         checkIntegrity: { report }, initialIntegrity: report)
    }
}
