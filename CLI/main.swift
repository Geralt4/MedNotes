import Foundation

@main
struct MedNotesImportCLI {
    static func main() async {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        var sourcePath: String?
        var keepStaging = false
        var isDryRun = true // Default is dry-run

        var i = 1
        while i < args.count {
            let arg = args[i]
            if arg == "--source" {
                guard i + 1 < args.count else {
                    print("❌ ERROR: --source requires a path")
                    fflush(stdout)
                    exit(1)
                }
                sourcePath = args[i + 1]
                i += 2
                continue
            } else if arg == "--keep-staging" {
                keepStaging = true
            } else if arg == "--dry-run" {
                isDryRun = true
            } else {
                print("❌ ERROR: Unknown argument '\(arg)'")
                printUsage()
                fflush(stdout)
                exit(1)
            }
            i += 1
        }

        let defaultICloudPath = (NSHomeDirectory() as NSString).appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Documents/MedNotes"
        )

        let targetSourcePath = sourcePath ?? defaultICloudPath
        let sourceURL = URL(fileURLWithPath: (targetSourcePath as NSString).expandingTildeInPath)

        print("================================================================")
        print(" MedNotes JSON Import Tool - \(isDryRun ? "DRY-RUN MODE" : "LIVE IMPORT")")
        print("================================================================")
        print("Source Directory: \(sourceURL.path)")
        fflush(stdout)

        // Validation & Safety
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            print("❌ ERROR: Source path does not exist or is not a directory: \(sourceURL.path)")
            fflush(stdout)
            exit(1)
        }

        // Check the resolved path as well as the literal one: a symlink with an
        // innocuous name pointing at a Backups folder would otherwise walk
        // straight past this guard and import the test dumps.
        func namesABackupFolder(_ path: String) -> Bool {
            let lowered = path.lowercased()
            let components: [String] = lowered.split(separator: "/").map(String.init)
            for component in components {
                if component == "backups" { return true }
                if component == "backup" { return true }
                if component.hasPrefix("backup_") { return true }
            }
            return false
        }
        let isBackupFolder = namesABackupFolder(sourceURL.path)
            || namesABackupFolder(sourceURL.resolvingSymlinksInPath().path)
        if isBackupFolder {
            print("❌ SAFETY REFUSAL: Target directory appears to be a Backups folder.")
            print("   Importing test/backup dumps is prohibited by default.")
            fflush(stdout)
            exit(1)
        }

        let tempUUID = UUID().uuidString
        let stagingDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mednotes-dryrun-\(tempUUID)")

        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let stagingDBPath = stagingDir.appendingPathComponent("mednotes.db").path

            print("Staging Database: \(stagingDBPath)")
            print("Scanning source subfolders...\n")
            fflush(stdout)

            // Initialize clean database
            let db = try Database(path: stagingDBPath)
            print("Database initialized.")
            fflush(stdout)

            // Perform import
            let startTime = Date()
            let importer = JSONImporter(directoryURL: sourceURL)
            let stagingFiles = stagingDir.appendingPathComponent("Files", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingFiles, withIntermediateDirectories: true)
            print("Importing (single transaction)...")
            let report = try await importer.importAll(into: db, filesRoot: stagingFiles)
            print("Import complete.")
            let duration = Date().timeIntervalSince(startTime)

            // Verify integrity and foreign keys
            let integrity = try await db.integrityCheck()
            let fkViolations = try await db.foreignKeyCheck()
            let dbCounts = try await db.counts()

            // Fetch details for report
            let todos = try await db.loadAllTodos(includeCompleted: true)
            let events = try await db.loadAllEvents()
            _ = try await db.loadAllPatients(includeArchived: true)
            _ = try await db.loadAllNotes()

            // Print Report
            print("================================================================")
            print("                      IMPORT REPORT                             ")
            print("================================================================")
            print("Duration: \(String(format: "%.3f", duration))s")
            print("\n📊 Entity Summary:")
            print("  • Patients imported:       \(report.patientsImported) (in DB: \(dbCounts["patients"] ?? 0))")
            print("  • Notes imported:          \(report.notesImported) (in DB: \(dbCounts["notes"] ?? 0))")
            print("  • Todos imported:          \(report.todosImported) (in DB: \(dbCounts["todo_items"] ?? 0))")
            print("  • CalendarEvents imported: \(report.eventsImported) (in DB: \(dbCounts["calendar_events"] ?? 0))")
            print("  • Files skipped:           \(report.filesSkipped)")

            print("\n🛡️  Database Integrity:")
            print("  • Integrity check:         \(integrity)")
            print("  • Foreign key violations:  \(fkViolations)")

            if !report.warnings.isEmpty {
                print("\n⚠️  Warnings (\(report.warnings.count)):")
                for (idx, w) in report.warnings.prefix(15).enumerated() {
                    print("  [\(idx + 1)] \(w)")
                }
                if report.warnings.count > 15 {
                    print("  ... and \(report.warnings.count - 15) more warnings.")
                }
            }

            if !report.errors.isEmpty {
                print("\n❌ Errors (\(report.errors.count)):")
                for (idx, e) in report.errors.enumerated() {
                    print("  [\(idx + 1)] \(e)")
                }
            }

            // Detailed Breakdown
            if !todos.isEmpty {
                print("\n📝 Imported Todos (\(todos.count)):")
                for t in todos {
                    let dueStr = t.dueDate != nil ? LenientDate.encodeJSON(t.dueDate!) : "None"
                    let statusStr = t.isCompleted ? "[COMPLETED]" : (t.isOverdue ? "[OVERDUE]" : "[PENDING]")
                    print("  • \(statusStr) \(t.title) (Priority: \(t.priority.rawValue), Due: \(dueStr), Sync: \(t.syncStatus.rawValue))")
                }
            }

            if !events.isEmpty {
                let unlinkedCount = events.filter { $0.patientId == nil }.count
                print("\n📅 Calendar Events (\(events.count) total, \(unlinkedCount) unlinked):")
                for e in events.prefix(10) {
                    let patientRef = e.patientId == nil ? "(Unlinked)" : "(Patient: \(e.patientId!.uuidString.prefix(8)))"
                    print("  • [\(e.eventType.rawValue)] \(e.title) \(patientRef)")
                }
                if events.count > 10 {
                    print("  ... and \(events.count - 10) more calendar events.")
                }
            }

            // Cleanup
            await db.close()

            if keepStaging {
                print("\n💾 Staging database PRESERVED at:")
                print("   \(stagingDBPath)")
            } else {
                try FileManager.default.removeItem(at: stagingDir)
                print("\n🧹 Staging database deleted successfully. No changes made to live storage.")
            }
            print("================================================================\n")
            fflush(stdout)

            if integrity != "ok" || fkViolations != 0 || !report.errors.isEmpty {
                exit(1)
            }

        } catch {
            print("\n❌ Unexpected error during import: \(error)")
            if keepStaging {
                print("💾 Staging database PRESERVED at:")
                print("   \(stagingDir.path)")
            } else {
                try? FileManager.default.removeItem(at: stagingDir)
            }
            fflush(stdout)
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage: mednotes-import [options]

        Options:
          --source <path>     Path to the MedNotes folder containing Patients, Notes, Todos, CalendarEvents
                              (Defaults to iCloud Drive/Documents/MedNotes)
          --dry-run           Execute import against a temporary throwaway database (default)
          --keep-staging      Do not delete the temporary database after the dry-run report
          --help, -h          Show this help message
        """)
    }
}
