# File coverage

Inventory of every source, config, schema, test and doc file in the working tree (commit 8a1d105 plus uncommitted changes). Tick = read in full.

Format: `- [ ] path (lines)`


### .
- [x] BUG_AUDIT.md (161)
- [x] BUG_FIX_REPORT.md (50)

### CLI
- [x] CLI/main.swift (219)

### docs/adr
- [x] docs/adr/0001-encryption-at-rest.md (94)
- [x] docs/adr/0002-encrypted-store.md (153)

### docs
- [x] docs/dependencies.md (24)

### docs/reviews/2026-10-22
- [x] docs/reviews/2026-10-22/BugReviewReproductionTests.swift (262)
- [x] docs/reviews/2026-10-22/critical-bugs.md (102)

### docs/reviews/2026-10-23
- [x] docs/reviews/2026-10-23/IndependentVerificationTests.swift (109)
- [x] docs/reviews/2026-10-23/verification.md (76)

### docs
- [x] docs/security.md (108)

### .
- [x] FINAL_VERIFICATION.md (108)

### MedNotes.xcodeproj
- [x] MedNotes.xcodeproj/project.pbxproj (531)

### MedNotes.xcodeproj/xcshareddata/xcschemes
- [x] MedNotes.xcodeproj/xcshareddata/xcschemes/MedNotes.xcscheme (93)

### MedNotes/Assets.xcassets/AccentColor.colorset
- [x] MedNotes/Assets.xcassets/AccentColor.colorset/Contents.json (38)

### MedNotes/Assets.xcassets/AppIcon.appiconset
- [x] MedNotes/Assets.xcassets/AppIcon.appiconset/Contents.json (67)

### MedNotes/Assets.xcassets
- [x] MedNotes/Assets.xcassets/Contents.json (6)

### MedNotes
- [x] MedNotes/ContentView.swift (437)

### MedNotes/Import
- [x] MedNotes/Import/JSONImporter.swift (345)

### MedNotes
- [x] MedNotes/InfoPlist.xcstrings (42)
- [x] MedNotes/MedNotes.entitlements (16)
- [x] MedNotes/MedNotesApp.swift (152)

### MedNotes/Models
- [x] MedNotes/Models/Core.swift (332)
- [x] MedNotes/Models/NewRecord.swift (101)
- [x] MedNotes/Models/Patient.swift (1097)

### MedNotes/Services
- [x] MedNotes/Services/AppleCalendarService.swift (467)
- [x] MedNotes/Services/AppleRemindersService.swift (540)
- [x] MedNotes/Services/AppStore.swift (89)
- [x] MedNotes/Services/BackupService.swift (872)
- [x] MedNotes/Services/LinkingService.swift (458)
- [x] MedNotes/Services/MarkdownExportService.swift (310)
- [x] MedNotes/Services/Services.swift (602)
- [x] MedNotes/Services/SyncBridgeAccess.swift (17)
- [x] MedNotes/Services/SyncDestinationCore.swift (85)
- [x] MedNotes/Services/SyncDestinationDatabase.swift (176)
- [x] MedNotes/Services/SyncDestinationStore.swift (193)
- [x] MedNotes/Services/TemplateService.swift (228)

### MedNotes/Storage
- [x] MedNotes/Storage/AttachmentStore.swift (28)
- [x] MedNotes/Storage/Database.swift (1598)
- [x] MedNotes/Storage/EncryptedFileStore.swift (311)
- [x] MedNotes/Storage/Schema.swift (304)
- [x] MedNotes/Storage/SecureStoreCoordinator.swift (253)
- [x] MedNotes/Storage/SQLConnection.swift (297)
- [x] MedNotes/Storage/StoreMigrator.swift (414)
- [x] MedNotes/Storage/StoreRecovery.swift (210)

### MedNotes/Support
- [x] MedNotes/Support/AMKA.swift (86)
- [x] MedNotes/Support/ArchiveExtraction.swift (115)
- [x] MedNotes/Support/BackupArchiveV2.swift (657)
- [x] MedNotes/Support/BackupPassphrasePolicy.swift (85)
- [x] MedNotes/Support/DataRoot.swift (133)
- [x] MedNotes/Support/EncryptedBackupFormat.swift (117)
- [x] MedNotes/Support/KeyManager.swift (206)
- [x] MedNotes/Support/LegacyBackupReader.swift (251)
- [x] MedNotes/Support/LenientCodable.swift (251)
- [x] MedNotes/Support/PreviewSeed.swift (30)
- [x] MedNotes/Support/SampleData.swift (401)
- [x] MedNotes/Support/SecurityLog.swift (61)

### MedNotes/UI
- [x] MedNotes/UI/ActivityView.swift (113)

### MedNotes/UI/Backup
- [x] MedNotes/UI/Backup/BackupFlowSheet.swift (198)
- [x] MedNotes/UI/Backup/FilePanels.swift (119)
- [x] MedNotes/UI/Backup/ImportFlowSheet.swift (153)

### MedNotes/UI/Calendar
- [x] MedNotes/UI/Calendar/EventDetailView.swift (241)
- [x] MedNotes/UI/Calendar/EventEditorForm.swift (121)
- [x] MedNotes/UI/Calendar/EventListView.swift (141)
- [x] MedNotes/UI/Calendar/EventRecordView.swift (106)
- [x] MedNotes/UI/Calendar/EventRowView.swift (61)
- [x] MedNotes/UI/Calendar/EventSummary.swift (66)

### MedNotes/UI
- [x] MedNotes/UI/DeleteShortcut.swift (73)
- [x] MedNotes/UI/FocusParking.swift (135)

### MedNotes/UI/Graph
- [x] MedNotes/UI/Graph/GraphLayout.swift (197)
- [x] MedNotes/UI/Graph/GraphView.swift (362)

### MedNotes/UI/Markdown
- [x] MedNotes/UI/Markdown/MarkdownPreview.swift (202)

### MedNotes/UI/Notes
- [x] MedNotes/UI/Notes/AppSession.swift (3602)
- [x] MedNotes/UI/Notes/MarkdownStyler.swift (115)
- [x] MedNotes/UI/Notes/NoteBodyEditor.swift (327)
- [x] MedNotes/UI/Notes/NoteDetailView.swift (578)
- [x] MedNotes/UI/Notes/NoteListView.swift (118)
- [x] MedNotes/UI/Notes/NoteRowView.swift (43)
- [x] MedNotes/UI/Notes/OpenEditorDraft.swift (19)
- [x] MedNotes/UI/Notes/QuickSwitcherView.swift (164)

### MedNotes/UI/Patients
- [x] MedNotes/UI/Patients/PatientDetailView.swift (313)
- [x] MedNotes/UI/Patients/PatientEditorForm.swift (357)
- [x] MedNotes/UI/Patients/PatientListView.swift (150)
- [x] MedNotes/UI/Patients/PatientMedicalSections.swift (384)
- [x] MedNotes/UI/Patients/PatientRecordFields.swift (170)
- [x] MedNotes/UI/Patients/PatientRecordView.swift (176)
- [x] MedNotes/UI/Patients/PatientRowView.swift (63)

### MedNotes/UI
- [x] MedNotes/UI/PrivacyCover.swift (63)

### MedNotes/UI/Settings
- [x] MedNotes/UI/Settings/DataSettingsPane.swift (424)
- [x] MedNotes/UI/Settings/GeneralSettingsPane.swift (85)
- [x] MedNotes/UI/Settings/SettingsIdentifiers.swift (32)
- [x] MedNotes/UI/Settings/SettingsView.swift (74)
- [x] MedNotes/UI/Settings/SyncSettingsPane.swift (193)
- [x] MedNotes/UI/Settings/TemplatesSettingsPane.swift (417)

### MedNotes/UI/Sidebar
- [x] MedNotes/UI/Sidebar/SidebarView.swift (56)

### MedNotes/UI/Sync
- [x] MedNotes/UI/Sync/SyncDestinationWizard.swift (245)
- [x] MedNotes/UI/Sync/SyncPillMenu.swift (111)

### MedNotes/UI/Theme
- [x] MedNotes/UI/Theme/Chrome.swift (499)
- [x] MedNotes/UI/Theme/Compatibility.swift (118)
- [x] MedNotes/UI/Theme/Components.swift (651)
- [x] MedNotes/UI/Theme/FlowLayout.swift (48)
- [x] MedNotes/UI/Theme/SwipeActions.swift (574)
- [x] MedNotes/UI/Theme/SwipeDiagnostics.swift (109)

### MedNotes/UI/Todos
- [x] MedNotes/UI/Todos/TodoDetailView.swift (296)
- [x] MedNotes/UI/Todos/TodoEditorForm.swift (155)
- [x] MedNotes/UI/Todos/TodoListView.swift (135)
- [x] MedNotes/UI/Todos/TodoRecordView.swift (179)
- [x] MedNotes/UI/Todos/TodoRowView.swift (131)

### MedNotesTests
- [x] MedNotesTests/AMKATests.swift (74)
- [x] MedNotesTests/ArchiveTests.swift (113)
- [x] MedNotesTests/BackendFixTests.swift (1110)
- [x] MedNotesTests/BackupRestoreTests.swift (210)
- [x] MedNotesTests/CLIDryRunTests.swift (107)
- [x] MedNotesTests/CriticalFixTests.swift (785)
- [x] MedNotesTests/DataRootTests.swift (42)
- [x] MedNotesTests/DeleteShortcutTests.swift (302)
- [x] MedNotesTests/DisplayCopyTests.swift (110)
- [x] MedNotesTests/EditorRenderTests.swift (117)
- [x] MedNotesTests/EditorSwitchTests.swift (119)
- [x] MedNotesTests/EncryptedBackupTests.swift (425)
- [x] MedNotesTests/EntitlementsTests.swift (26)
- [x] MedNotesTests/EventSummaryTests.swift (65)
- [x] MedNotesTests/ExternalCopiesTests.swift (186)
- [x] MedNotesTests/FilePanelLockTests.swift (666)

### MedNotesTests/Fixtures
- [x] MedNotesTests/Fixtures/event_appointment.json (0)
- [x] MedNotesTests/Fixtures/note_simple.json (0)
- [x] MedNotesTests/Fixtures/patient_full.json (0)
- [x] MedNotesTests/Fixtures/todo_high.json (0)
- [x] MedNotesTests/Fixtures/todo_workflow.json (0)

### MedNotesTests
- [x] MedNotesTests/GraphLayoutTests.swift (103)
- [x] MedNotesTests/ImporterTests.swift (227)
- [x] MedNotesTests/LockCommandTests.swift (69)
- [x] MedNotesTests/MarkdownStylerTests.swift (77)
- [x] MedNotesTests/ModelRoundTripTests.swift (726)
- [x] MedNotesTests/NewRecordTests.swift (196)
- [x] MedNotesTests/NoteBodyEditorTests.swift (416)
- [x] MedNotesTests/NoteEditorUndoTests.swift (426)
- [x] MedNotesTests/ObsidianCoreTests.swift (878)
- [x] MedNotesTests/OffscreenHosting.swift (272)
- [x] MedNotesTests/PatientRecordFieldsTests.swift (99)
- [x] MedNotesTests/RemindersSyncTests.swift (234)
- [x] MedNotesTests/SampleDataTests.swift (183)
- [x] MedNotesTests/SecurityTests.swift (2533)
- [x] MedNotesTests/SessionFlowTests.swift (396)
- [x] MedNotesTests/SettingsRenderTests.swift (180)
- [x] MedNotesTests/SettingsTests.swift (447)
- [x] MedNotesTests/SQLStoreTests.swift (432)
- [x] MedNotesTests/TestSupport.swift (196)
- [x] MedNotesTests/TodoRecordTests.swift (57)

### .
- [x] opencode.json (4)
- [x] README.md (296)

### scripts
- [x] scripts/build_cli.sh (55)
- [x] scripts/check_l10n.py (579)
- [x] scripts/generate_app_icon.swift (127)
- [x] scripts/preview_shots.sh (251)
- [x] scripts/release.sh (141)
- [x] scripts/render_editors.swift (405)
- [x] scripts/render_rows.swift (108)
- [x] scripts/scan_dependencies.py (72)

### scripts/swipe-probe
- [x] scripts/swipe-probe/main.swift (197)
- [x] scripts/swipe-probe/probe2.swift (114)
- [x] scripts/swipe-probe/run.sh (25)

### scripts
- [x] scripts/verify_entitlements.py (66)

## Excluded (not source: dependencies, build output, generated, binary)

- `build/` — build output and preview screenshots (84 PNGs)
- `bin/mednotes-import` — compiled CLI binary (source is `CLI/main.swift`, which is in the list)
- `default.profraw` — coverage run artefact
- `MedNotes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` — lock file
- `MedNotes.xcodeproj/project.xcworkspace/xcuserdata/` — per-user Xcode state
- `Recovery/` — 14 string/symbol dumps extracted from the old compiled binary (generated, 60k+ lines); described in README.md
- `MedNotes/Localizable.xcstrings` — Xcode-generated string catalog (7,197 lines); checked by `scripts/check_l10n.py`, which is in the list
- `MedNotes/Assets.xcassets/**/*.png` — image assets
- tooling dot-directories (5 files: local editor/agent plan notes and a worktree rule) — not part of the product; excluded from commits
- `.DS_Store` — Finder metadata

## How the files were read

- 163 of 163 inventory files ticked; 0 skipped.
- Eight reader agents each read one slice in full and reported, per file, the line count and the last non-empty line. I re-counted every file and compared its last line; all matched (a few counts differ by one where the reader counted a final line without a newline).
- Because most files end in `}`, the last line is a weak proof on its own. I therefore also read these files myself and checked the readers' claims about them: `Storage/Schema.swift`, `Services/LinkingService.swift`, `Models/Core.swift`, `Support/SecurityLog.swift`, `UI/Graph/GraphLayout.swift`, `UI/Markdown/MarkdownPreview.swift`, `UI/Notes/MarkdownStyler.swift`, `docs/security.md`, and the audit, search, WAL and `NoteService.save` code in `Storage/Database.swift` and `Services/Services.swift`. Further claims checked against source are listed in GAP_ANALYSIS.md.
- The research source is the 34-page PDF "Obsidian Architecture Reverse-Engineering Report" (no RESEARCH.md exists in the repo); it was read in full.
