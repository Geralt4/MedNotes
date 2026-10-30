import XCTest
@testable import MedNotes

/// The preferences behind Settings: the launch module, the vault mirror
/// switch, and the two read-only reports the Data pane shows. Every session
/// gets a temporary root and the class's own defaults suite, emptied around
/// every test, so nothing here reads or writes the host's real preferences
/// or store. One fixed suite, not one per test: the hosted suite runs in the
/// app's real container, where each suite leaves a file. See `TestDefaults`.
@MainActor
final class SettingsTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.Settings"
    private var roots: [DataRoot] = []
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        TestDefaults.clear(Self.defaultsName)
    }

    /// The test's defaults: the same suite however often a test asks, the
    /// way a relaunch reads what the last run wrote.
    private func makeDefaults() -> UserDefaults {
        defaults
    }

    private func makeSession(defaults: UserDefaults) async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    // MARK: - Launch module

    func testLaunchModuleRoundTripsThroughItsStorageValue() {
        XCTAssertEqual(LaunchModule(storageValue: nil), .default)
        XCTAssertEqual(LaunchModule(storageValue: "lastUsed"), .lastUsed)
        XCTAssertEqual(LaunchModule(storageValue: "calendar"), .fixed(.calendar))
        XCTAssertEqual(LaunchModule(storageValue: "module-from-a-newer-build"), .default,
                       "an unknown value falls back rather than failing the launch")
        for module in AppModule.allCases {
            XCTAssertEqual(LaunchModule(storageValue: LaunchModule.fixed(module).storageValue), .fixed(module))
        }
        XCTAssertEqual(LaunchModule.lastUsed.startModule(lastUsed: nil), .patients,
                       "a first launch with nothing remembered opens where it always did")
        XCTAssertEqual(LaunchModule.lastUsed.startModule(lastUsed: .graph), .graph)
        XCTAssertEqual(LaunchModule.fixed(.notes).startModule(lastUsed: .graph), .notes)
    }

    func testFreshDefaultsOpenOnPatients() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        XCTAssertEqual(session.launchModule, .fixed(.patients))
        XCTAssertEqual(session.selectedModule, .patients)
    }

    func testFixedLaunchModuleIsHonoured() async throws {
        let defaults = makeDefaults()
        let first = try await makeSession(defaults: defaults)
        first.launchModule = .fixed(.calendar)
        XCTAssertEqual(defaults.string(forKey: AppSession.launchModuleDefaultsKey), "calendar")

        let second = try await makeSession(defaults: defaults)
        XCTAssertEqual(second.launchModule, .fixed(.calendar))
        XCTAssertEqual(second.selectedModule, .calendar)
    }

    func testLastUsedLaunchModuleFollowsTheSelection() async throws {
        let defaults = makeDefaults()
        let first = try await makeSession(defaults: defaults)
        first.launchModule = .lastUsed
        first.selectedModule = .todos
        first.selectedModule = .graph
        XCTAssertEqual(defaults.string(forKey: AppSession.lastModuleDefaultsKey), "graph")

        let second = try await makeSession(defaults: defaults)
        XCTAssertEqual(second.selectedModule, .graph)
        // Reading the remembered module at launch must not overwrite it.
        XCTAssertEqual(defaults.string(forKey: AppSession.lastModuleDefaultsKey), "graph")
    }

    // MARK: - Device keys and the retired mirror

    func testRetiredVaultMirroringPreferenceIsIgnored() async throws {
        // The continuous mirror is retired: a leftover preference from an
        // older build must not bring it back.
        let defaults = makeDefaults()
        defaults.set(true, forKey: "vaultMirroringEnabled")
        let session = try await makeSession(defaults: defaults)
        let mirroringNames = await session.recentActivity().map(\.action)
        XCTAssertFalse(mirroringNames.contains("vault_mirroring_on"))
    }

    // MARK: - Automatic sync

    func testAutomaticSyncDefaultsOnPersistsAndIsAudited() async throws {
        let defaults = makeDefaults()
        let session = try await makeSession(defaults: defaults)
        XCTAssertTrue(session.calendarAutoSyncEnabled, "on by default: how the bridges always behaved")
        XCTAssertTrue(session.remindersAutoSyncEnabled)

        await session.setCalendarAutoSync(false)
        await session.setRemindersAutoSync(false)
        await session.setRemindersAutoSync(false)   // a repeat is not a change
        XCTAssertEqual(defaults.object(forKey: AppSession.calendarAutoSyncDefaultsKey) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: AppSession.remindersAutoSyncDefaultsKey) as? Bool, false)
        let actions = await session.recentActivity().map(\.action)
        XCTAssertEqual(actions.filter { $0.hasSuffix("auto_sync_off") }.sorted(),
                       ["calendar_auto_sync_off", "reminders_auto_sync_off"], "got \(actions)")
        XCTAssertEqual(DisplayCopy.auditAction("calendar_auto_sync_off"), "Calendar auto-sync off")

        let relaunched = try await makeSession(defaults: defaults)
        XCTAssertFalse(relaunched.calendarAutoSyncEnabled, "the switch survives a relaunch")
        XCTAssertFalse(relaunched.remindersAutoSyncEnabled)
        await relaunched.setCalendarAutoSync(true)
        XCTAssertTrue(relaunched.calendarAutoSyncEnabled)
    }

    /// The test host never holds Calendar access, so this proves the row is
    /// left alone and the flag is honoured, not that EventKit stayed quiet;
    /// that half is the owner's live check with a granted bridge.
    func testSavedEventStaysLocalWhileAutomaticSyncIsOff() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        await session.setCalendarAutoSync(false)
        await session.newEvent()
        let loaded = await session.loadSelectedEvent()
        var event = try XCTUnwrap(loaded)
        event.title = "Post-op review"
        let saved = await session.save(event)
        XCTAssertTrue(saved)
        let stored = await session.loadSelectedEvent()
        XCTAssertEqual(stored?.syncStatus, .localOnly)
        XCTAssertNil(stored?.lastSyncDate)
        XCTAssertNil(stored?.ekEventIdentifier)
        await session.syncCalendarNow(automatic: true)
        XCTAssertNil(session.lastCalendarSyncSummary, "an automatic pass does nothing while the switch is off")
    }

    // MARK: - Templates

    func testTemplatesListBuiltInsInShippedOrderThenCustomsByName() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        var zeta = try await session.newTemplate()
        zeta.name = "Zeta"
        try await session.saveTemplate(zeta)
        var alpha = try await session.newTemplate()
        alpha.name = "alpha"
        try await session.saveTemplate(alpha)

        let list = try await session.loadTemplates()
        XCTAssertEqual(Array(list.prefix(3).map(\.id)), ["tpl-soap", "tpl-admission", "tpl-discharge"])
        XCTAssertEqual(Array(list.dropFirst(3).map(\.name)), ["alpha", "Zeta"])
        XCTAssertTrue(alpha.id.hasPrefix(NoteTemplate.customIDPrefix))
        let menu = await session.templatesForMenu()
        XCTAssertEqual(menu.map(\.id), list.map(\.id), "the note editor's menu keeps the same order")
    }

    func testEditedBuiltInIsMarkedSurvivesReloadAndResets() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        let initial = try await session.loadTemplates()
        var soap = try XCTUnwrap(initial.first)
        XCTAssertFalse(soap.isEditedBuiltIn)
        soap.content = "# SOAP — {{patient}}\n\n## Subjective\n- changed"
        try await session.saveTemplate(soap)
        XCTAssertEqual(session.templateEpoch, 1)

        let reloaded = try await session.loadTemplates()
        XCTAssertEqual(reloaded.first?.content, soap.content)
        XCTAssertEqual(reloaded.first?.isEditedBuiltIn, true)
        XCTAssertEqual(reloaded.count, 3, "editing a built-in changes its row, it never adds one")

        let shipped = try await session.resetTemplate(id: soap.id)
        XCTAssertEqual(shipped, TemplateService.builtIns[0])
        XCTAssertEqual(session.templateEpoch, 2)
        let after = try await session.loadTemplates()
        XCTAssertEqual(after.first?.isEditedBuiltIn, false)

        let actions = await session.recentActivity().map(\.action)
        XCTAssertTrue(actions.contains("template_reset"), "got \(actions)")
        XCTAssertEqual(DisplayCopy.auditAction("template_reset"), "Reset template")
        XCTAssertEqual(DisplayCopy.auditAction("template_save"), "Saved template")
    }

    func testUntouchedNewTemplateIsDiscardedAndANamedOneKept() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        let fresh = try await session.newTemplate()
        XCTAssertTrue(fresh.isUntouchedNewRecord)
        XCTAssertFalse(fresh.isBuiltIn)
        var list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 4)

        await session.discardTemplateIfUntouched(fresh)
        list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 3, "an abandoned + leaves no row behind")

        var kept = try await session.newTemplate()
        kept.name = "Ward round"
        try await session.saveTemplate(kept)
        XCTAssertFalse(kept.isUntouchedNewRecord)
        await session.discardTemplateIfUntouched(kept)
        list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 4, "a named template is not discarded")

        try await session.deleteTemplate(id: kept.id)
        list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 3)
        let actions = await session.recentActivity().map(\.action)
        XCTAssertTrue(actions.contains("template_delete"), "got \(actions)")
    }

    func testDefaultTemplateSeedsNewNotesAndKeepsTheDiscardRule() async throws {
        let defaults = makeDefaults()
        let session = try await makeSession(defaults: defaults)
        XCTAssertNil(session.defaultNoteTemplateID)
        session.defaultNoteTemplateID = "tpl-soap"
        XCTAssertEqual(defaults.string(forKey: AppSession.defaultNoteTemplateDefaultsKey), "tpl-soap")

        await session.newNote()
        let seededLoad = await session.loadSelectedNote()
        let seeded = try XCTUnwrap(seededLoad)
        XCTAssertTrue(seeded.content.hasPrefix("# SOAP — —"), "seeded from the template with no patient: \(seeded.content)")
        XCTAssertFalse(seeded.isUntouchedNewRecord, "a plain comparison would keep it")
        XCTAssertTrue(session.isUntouchedNewNote(seeded), "the session knows what it seeded")
        session.select(nil)
        await session.discardIfUntouched(seeded)
        let gone = await session.noteExists(id: seeded.id)
        XCTAssertEqual(gone, false, "an abandoned templated note leaves no row behind")

        await session.newNote()
        let typedLoad = await session.loadSelectedNote()
        var typed = try XCTUnwrap(typedLoad)
        typed.content += "\n- pain 3/10"
        let saved = await session.save(typed)
        XCTAssertTrue(saved)
        XCTAssertFalse(session.isUntouchedNewNote(typed))
        await session.discardIfUntouched(typed)
        let kept = await session.noteExists(id: typed.id)
        XCTAssertEqual(kept, true, "one typed line keeps it")

        let relaunched = try await makeSession(defaults: defaults)
        XCTAssertEqual(relaunched.defaultNoteTemplateID, "tpl-soap", "the choice survives a relaunch")
    }

    func testDeletingTheDefaultTemplateClearsThePreference() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        var custom = try await session.newTemplate()
        custom.name = "Ward round"
        try await session.saveTemplate(custom)
        session.defaultNoteTemplateID = custom.id
        try await session.deleteTemplate(id: custom.id)
        XCTAssertNil(session.defaultNoteTemplateID)
        await session.newNote()
        let blankLoad = await session.loadSelectedNote()
        let note = try XCTUnwrap(blankLoad)
        XCTAssertEqual(note.content, "", "back to blank notes")
    }

    func testDuplicateMakesACustomCopyNamedAfterTheOriginal() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        let copy = TemplateService.builtIns[0].duplicate()
        XCTAssertTrue(copy.id.hasPrefix(NoteTemplate.customIDPrefix))
        XCTAssertEqual(copy.name, "SOAP Note copy")
        XCTAssertEqual(copy.kind, .custom)
        XCTAssertEqual(copy.content, TemplateService.builtIns[0].content)
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertFalse(copy.isUntouchedNewRecord, "a copy has content and a real name")

        try await session.saveTemplate(copy)
        let list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 4)
        XCTAssertEqual(list.last?.id, copy.id, "customs follow the built-ins")
        try await session.deleteTemplate(id: copy.id)
        let after = try await session.loadTemplates()
        XCTAssertEqual(after.count, 3, "a copy of a built-in is deletable")
    }

    func testBuiltInTemplatesCannotBeDeleted() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        do {
            try await session.deleteTemplate(id: "tpl-soap")
            XCTFail("deleting a built-in must throw")
        } catch {
            XCTAssertTrue(error is TemplateError, "got \(error)")
        }
        let list = try await session.loadTemplates()
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(session.templateEpoch, 0, "a refused delete changes nothing")
    }

    // MARK: - Data pane

    func testStorageSummaryDescribesTheOpenStore() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        await session.newPatient()
        let loaded = await session.loadSelectedPatient()
        var patient = try XCTUnwrap(loaded)
        patient.profile.firstName = "Ελένη"
        let saved = await session.save(patient)
        XCTAssertTrue(saved)

        let loadedSummary = await session.storageSummary()
        let summary = try XCTUnwrap(loadedSummary)
        let root = try XCTUnwrap(roots.last)
        XCTAssertEqual(summary.rootURL, root.rootURL)
        XCTAssertEqual(summary.backupsURL, root.restorePointsURL)
        XCTAssertEqual(summary.counts["patients"], 1)
        XCTAssertEqual(summary.counts["notes"], 0)
        XCTAssertEqual(summary.hasRecords, true)
        XCTAssertEqual(BackupFlowSheet.summary(counts: summary.counts),
                       "1 patients · 0 notes · 0 todos · 0 events")

        // Restore points are .mnrp files in their own folder; a stray file or
        // an old backup directory must not appear.
        let none = await session.restorePoints()
        XCTAssertTrue(none.isEmpty)
        try FileManager.default.createDirectory(
            at: root.backupsURL.appendingPathComponent("backup_2026-09-12_10-00-00_abcd1234"),
            withIntermediateDirectories: true)
        try Data().write(to: root.backupsURL.appendingPathComponent("stray.txt"))
        let store = try XCTUnwrap(session.store)
        _ = try await store.backups.createEncryptedRestorePoint(
            name: "Pre-import snapshot")
        let points = await session.restorePoints()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.name, "Pre-import snapshot")
        XCTAssertGreaterThan(points.first?.sizeBytes ?? 0, 0, "the encrypted point has a size")
    }

    func testRestorePointsPruneToTheNewestAndDeleteIsAudited() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        let root = try XCTUnwrap(roots.last)
        let store = try XCTUnwrap(session.store)
        var made: [URL] = []
        for index in 0..<7 {
            let name = try await store.backups.createEncryptedRestorePoint(
                name: "Point \(index)")
            made.append(root.restorePointsURL.appendingPathComponent(name))
            try await Task.sleep(nanoseconds: 20_000_000)   // points order by creation date
        }
        await session.pruneRestorePoints()
        let kept = await session.restorePoints()
        XCTAssertEqual(kept.count, BackupService.restorePointsToKeep)
        XCTAssertEqual(kept.first?.url.lastPathComponent, made.last?.lastPathComponent, "the newest survives")
        XCTAssertEqual(kept.map(\.name), ["Point 6", "Point 5", "Point 4", "Point 3", "Point 2"])
        for old in made.prefix(2) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "the oldest went")
        }
        await session.pruneRestorePoints()
        let again = await session.restorePoints()
        XCTAssertEqual(again.count, 5, "a second prune removes nothing")

        let victim = try XCTUnwrap(kept.last)
        try await session.deleteRestorePoint(victim)
        let after = await session.restorePoints()
        XCTAssertEqual(after.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.url.path))

        let actions = await session.recentActivity().map(\.action)
        XCTAssertEqual(actions.filter { $0 == "restore_point_prune" }.count, 1, "got \(actions)")
        XCTAssertTrue(actions.contains("restore_point_delete"), "got \(actions)")
        XCTAssertEqual(DisplayCopy.auditAction("restore_point_prune"), "Pruned restore points")
    }

    func testLastBackupComesFromTheNewestAuditRow() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        let fresh = await session.storageSummary()
        XCTAssertNil(fresh?.lastBackup, "a fresh store was never backed up")
        XCTAssertEqual(fresh?.hasRecords, false)

        let store = try XCTUnwrap(session.store)
        try await store.audit.log(action: "backup_create", entityType: "backup",
                                  entityId: "old.mednotesbackup", details: "0 patients")
        try await Task.sleep(nanoseconds: 30_000_000)   // timestamps carry milliseconds
        try await store.audit.log(action: "backup_create", entityType: "backup",
                                  entityId: "practice.mednotesbackup", details: "0 patients")
        try await store.audit.log(action: "backup_restore", entityType: "backup",
                                  entityId: "other.mednotesbackup", details: "")

        let after = await session.storageSummary()
        let last = try XCTUnwrap(after?.lastBackup)
        XCTAssertEqual(last.name, "practice.mednotesbackup", "the newest backup_create row, not a restore")
        XCTAssertEqual(last.date.timeIntervalSinceNow, 0, accuracy: 5)
    }

    func testIntegrityCheckPassesOnAFreshStoreAndIsAudited() async throws {
        let session = try await makeSession(defaults: makeDefaults())
        XCTAssertNil(session.integrityWarning, "a healthy store raises nothing at launch")
        let report = await session.checkIntegrity()
        XCTAssertTrue(report.passed, report.detail)
        XCTAssertEqual(report.detail, "No problems found.")
        XCTAssertNil(session.integrityWarning)
        let entries = await session.recentActivity()
        let entry = try XCTUnwrap(entries.first { $0.action == "integrity_check" })
        XCTAssertEqual(entry.details, "ok")
        XCTAssertEqual(entries.filter { $0.action == "integrity_check" }.count, 1,
                       "the launch check on a healthy store writes no row")
        XCTAssertEqual(DisplayCopy.auditAction("integrity_check"), "Checked integrity")
    }

    /// A todo pointing at a patient that does not exist, written with foreign
    /// keys off the way a damaged file would carry it: the launch check must
    /// notice, warn, and log it; a later passing check clears the warning.
    func testBrokenStoreWarnsAtLaunchAndAPassingCheckClearsIt() async throws {
        let root = try DataRoot.temporary()
        roots.append(root)
        // Stage the damage through the actor's own connection so the file
        // stays a consistent encrypted store; only the FK is violated.
        let db = try Database(path: root.databaseURL.path, key: TestKeys.database(for: root))
        try await db.execForTesting("PRAGMA foreign_keys = OFF")
        try await db.execForTesting("""
            INSERT INTO todo_items (id, title, created_at, patient_id)
            VALUES ('55555555-5555-5555-5555-555555555555', 'Orphan', '2024-03-03T08:00:00.000',
                    '99999999-9999-9999-9999-999999999999')
            """)
        try await db.execForTesting("PRAGMA foreign_keys = ON")
        await db.close()

        let session = AppSession.testSession(dataRoot: root, defaults: makeDefaults())
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while session.integrityWarning == nil, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertEqual(session.integrityWarning, "1 records point to a patient that no longer exists.")
        let entries = await session.recentActivity()
        let launchRow = try XCTUnwrap(entries.first { $0.action == "integrity_check" })
        XCTAssertEqual(launchRow.entityId, "launch")

        // Mend the store (drop the orphan), then a manual check passes and clears.
        let store = try XCTUnwrap(session.store)
        try await store.todos.delete(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
        let report = await session.checkIntegrity()
        XCTAssertTrue(report.passed, report.detail)
        XCTAssertNil(session.integrityWarning)
    }
}
