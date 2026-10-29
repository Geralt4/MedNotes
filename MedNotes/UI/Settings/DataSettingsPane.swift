import SwiftUI

/// What the Data pane shows about the store: where it is, what it holds,
/// and how many restore points sit beside it.
struct StorageSummary: Equatable {
    /// The newest `backup_create` audit row: when an encrypted backup was
    /// last made, and what it was called. After a restore the trail is the
    /// backup's own, so this is whatever that copy knew.
    struct LastBackup: Equatable {
        let date: Date
        let name: String
    }

    let rootURL: URL
    let backupsURL: URL
    /// Row counts keyed by table, as `Database.counts()` reports them.
    let counts: [String: Int]
    var lastBackup: LastBackup? = nil
    /// The folder an earlier version kept unencrypted backups in, and how many
    /// entries it holds. Nothing in this version writes there.
    var oldBackupsURL: URL? = nil
    var oldBackupCount = 0

    /// Whether there is anything to lose.
    var hasRecords: Bool {
        ["patients", "notes", "todo_items", "calendar_events"].contains { (counts[$0] ?? 0) > 0 }
    }
}

/// One `backup_…` directory beside the store, as the Data pane lists it.
struct RestorePoint: Identifiable, Equatable, Sendable {
    let url: URL
    let createdAt: Date
    let name: String
    let counts: [String: Int]
    /// The database plus every attachment copy; nil until measured.
    let sizeBytes: Int64?

    /// Still sealed under the passphrase an earlier version compiled in, so
    /// anyone with the file can read it. The next unlock reseals it; one that
    /// cannot be converted stays like this until it is deleted.
    var needsUpgrade = false

    var id: String { url.lastPathComponent }
}

/// The outcome of one integrity pass over the open store.
struct IntegrityReport: Equatable {
    let passed: Bool
    let checkedAt: Date
    /// Localised wording when the check passed or a link was broken;
    /// SQLite's own message, verbatim, when the file itself is damaged.
    let detail: String
}

/// The outcome of one rebuild of the derived indexes.
struct IndexRebuildOutcome: Equatable {
    let passed: Bool
    let rebuiltAt: Date
    /// Localised, counts only.
    let detail: String
}

/// Settings › Data: the store on disk, its restore points, an on-demand
/// integrity check, and the one paragraph on what encryption covers.
///
/// Commands stay in the File menu (Back Up…, Restore from Backup…, Import
/// Legacy Data…); this pane says where their output goes and shows the
/// store's health, which nothing else in the app does.
struct DataSettingsPane: View {
    let loadSummary: () async -> StorageSummary?
    let loadRestorePoints: () async -> [RestorePoint]
    let deleteRestorePoint: (RestorePoint) async throws -> Void
    /// Replaces the store's data with a restore point's; the session keeps a
    /// restore point of the current data first.
    let restoreRestorePoint: (RestorePoint) async throws -> Void
    let checkIntegrity: () async -> IntegrityReport
    let rebuildIndexes: () async -> IndexRebuildOutcome
    /// Nil when no folder was chosen or a lock stopped the export.
    let exportMarkdown: () async throws -> MarkdownExportService.ExportReport?
    /// Why the last export stopped short (`AppSession.markdownExportInterruption`).
    /// Passed in rather than kept here: the lock that stops an export also
    /// rebuilds this pane.
    let exportInterruption: String?
    let legacyVaultReport: () async -> VaultReconciliation.Report?
    let legacyVaultURL: URL?
    let deleteLegacyVault: (() async throws -> Void)?
    /// Decides what happens to the mirror's copy of the notes that need it;
    /// returns how many were decided.
    let resolveLegacyVault: ((LegacyVaultChoice) async throws -> Int)?

    @State private var summary: StorageSummary?
    @State private var restorePoints: [RestorePoint] = []
    @State private var pendingDelete: RestorePoint?
    @State private var pendingRestore: RestorePoint?
    @State private var isRestoring = false
    @State private var pendingMirrorReplace = false
    @State private var failure: String?
    @State private var integrity: IntegrityReport?
    @State private var isChecking = false
    @State private var rebuild: IndexRebuildOutcome?
    @State private var isRebuilding = false
    @State private var exportFailure: String?
    @State private var exportedSummary: String?
    @State private var vaultReport: VaultReconciliation.Report?
    @State private var vaultFailure: String?
    @State private var pendingVaultDelete = false
    @State private var isResolvingVault = false

    /// See `GeneralSettingsPane.height`; a check's result adds two rows, an
    /// overdue backup a caption, the vault report a section that grows by a
    /// row per listed note. The base was re-measured when the notes became
    /// footers: the English content plus the margin the old base kept over
    /// it for the Greek notes, which wrap a line more.
    var preferredHeight: CGFloat {
        var height: CGFloat = 720 + max(41, 46 * CGFloat(min(restorePoints.count, 6)))
            + (integrity == nil ? 0 : 70) + (backupIsOverdue ? 24 : 0) + (failure == nil ? 0 : 24)
            // The Indexes section: header, button and a three-line footer, and
            // a result of two rows.
            + 130 + (rebuild == nil ? 0 : 70)
        if let vaultReport {
            let listed = vaultReport.unresolvedVaultOnly.count + vaultReport.unresolvedDivergent.count
            height += 225 + 37 * CGFloat(min(listed, 6)) + (vaultReport.parseFailures.isEmpty ? 0 : 37)
                // One row per bulk action (mirror-only notes, differing notes)
                // and one for the skipped-items notice.
                + (vaultReport.unresolvedVaultOnly.isEmpty ? 0 : 37)
                + (vaultReport.unresolvedDivergent.isEmpty ? 0 : 37)
                + (vaultReport.skipped.isEmpty ? 0 : 37)
            if vaultFailure != nil { height += 24 }
        }
        if exportedSummary != nil { height += 24 }
        if exportFailure != nil { height += 24 }
        // Measured with the caption's longest form: 60 pt in Greek, 47 in English.
        if exportInterruption != nil { height += 60 }
        return height
    }

    /// A backup older than this, or none at all over a store with records,
    /// is called out. The owner's number; one constant.
    static let staleBackupAge: TimeInterval = 30 * 24 * 3600

    private var backupIsOverdue: Bool {
        guard let summary else { return false }
        guard let last = summary.lastBackup else { return summary.hasRecords }
        return Date().timeIntervalSince(last.date) > Self.staleBackupAge
    }

    private var lastBackupText: String {
        guard let last = summary?.lastBackup else { return String(localized: "Never") }
        return last.date.formatted(.relative(presentation: .named)) + " · " + last.name
    }

    /// `initialIntegrity` is a render seam only: the offscreen harness and the
    /// render test show a checked pane without pressing the button.
    init(loadSummary: @escaping () async -> StorageSummary?,
         loadRestorePoints: @escaping () async -> [RestorePoint] = { [] },
         deleteRestorePoint: @escaping (RestorePoint) async throws -> Void = { _ in },
         restoreRestorePoint: @escaping (RestorePoint) async throws -> Void = { _ in },
         checkIntegrity: @escaping () async -> IntegrityReport,
         rebuildIndexes: @escaping () async -> IndexRebuildOutcome = {
             IndexRebuildOutcome(passed: true, rebuiltAt: Date(), detail: "")
         },
         initialIntegrity: IntegrityReport? = nil,
         initialRebuild: IndexRebuildOutcome? = nil,
         exportMarkdown: @escaping () async throws -> MarkdownExportService.ExportReport? = { nil },
         exportInterruption: String? = nil,
         legacyVaultReport: @escaping () async -> VaultReconciliation.Report? = { nil },
         legacyVaultURL: URL? = nil,
         deleteLegacyVault: (() async throws -> Void)? = nil,
         resolveLegacyVault: ((LegacyVaultChoice) async throws -> Int)? = nil) {
        self.resolveLegacyVault = resolveLegacyVault
        self.loadSummary = loadSummary
        self.loadRestorePoints = loadRestorePoints
        self.deleteRestorePoint = deleteRestorePoint
        self.restoreRestorePoint = restoreRestorePoint
        self.checkIntegrity = checkIntegrity
        self.rebuildIndexes = rebuildIndexes
        self.exportMarkdown = exportMarkdown
        self.exportInterruption = exportInterruption
        self.legacyVaultReport = legacyVaultReport
        self.legacyVaultURL = legacyVaultURL
        self.deleteLegacyVault = deleteLegacyVault
        _integrity = State(initialValue: initialIntegrity)
        _rebuild = State(initialValue: initialRebuild)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    if let summary {
                        Text(verbatim: Self.abbreviated(summary.rootURL))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(summary.rootURL.path)
                            .accessibilityIdentifier(SettingsIdentifiers.storageLocation)
                    } else {
                        Text("Opening…")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Records") {
                    Text(verbatim: summary.map { BackupFlowSheet.summary(counts: $0.counts) } ?? "")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(SettingsIdentifiers.storageCounts)
                }
                if let summary {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([summary.rootURL])
                    }
                }
            } header: {
                DetailSectionHeader(title: "Storage", systemImage: "internaldrive")
            }

            Section {
                LabeledContent("Last backup") {
                    Text(verbatim: summary == nil ? "" : lastBackupText)
                        .foregroundStyle(backupIsOverdue ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier(SettingsIdentifiers.lastBackup)
                }
                if backupIsOverdue {
                    Text("Make a new one with File › Back Up…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if restorePoints.isEmpty {
                    LabeledContent("Restore points") {
                        Text("None yet")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(restorePoints) { point in
                        RestorePointRow(
                            point: point,
                            canRestore: !isRestoring,
                            onRestore: { pendingRestore = point },
                            onDelete: { pendingDelete = point })
                    }
                }
                if let failure {
                    Text(verbatim: failure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let summary {
                    Button("Show Backups in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([summary.backupsURL])
                    }
                    if let old = summary.oldBackupsURL, summary.oldBackupCount > 0 {
                        Text("\(summary.oldBackupCount) backup(s) from an earlier version are in a folder that is not encrypted. Make an encrypted backup with File › Back Up…, then delete them.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show Old Backups in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([old])
                        }
                    }
                }
            } header: {
                DetailSectionHeader(title: "Backups", systemImage: "externaldrive.badge.timemachine")
            } footer: {
                SettingsNote("Restore points are encrypted snapshots MedNotes keeps inside its container before an import or a restore; the newest five are kept. Encrypted backups are made with File › Back Up… and saved where you choose.")
            }

            Section {
                HStack(spacing: Chrome.Space.md) {
                    Button(isChecking ? "Checking…" : "Check Now") {
                        isChecking = true
                        Task {
                            integrity = await checkIntegrity()
                            isChecking = false
                        }
                    }
                    .disabled(isChecking || summary == nil)
                    .accessibilityIdentifier(SettingsIdentifiers.integrityButton)
                    if let integrity {
                        Label {
                            Text(verbatim: integrity.detail)
                        } icon: {
                            Image(systemName: integrity.passed
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(integrity.passed ? Color.green : Color.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let integrity {
                    Text("Checked \(integrity.checkedAt, format: .dateTime.hour().minute())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                DetailSectionHeader(title: "Integrity", systemImage: "checkmark.shield")
            } footer: {
                SettingsNote("Runs SQLite's own integrity check and confirms every link between records. Backups are checked the same way before they are trusted.")
            }

            Section {
                HStack(spacing: Chrome.Space.md) {
                    Button(isRebuilding ? "Rebuilding…" : "Rebuild Indexes") {
                        isRebuilding = true
                        Task {
                            rebuild = await rebuildIndexes()
                            isRebuilding = false
                        }
                    }
                    .disabled(isRebuilding || summary == nil)
                    .accessibilityIdentifier(SettingsIdentifiers.rebuildIndexesButton)
                    if let rebuild {
                        Label {
                            Text(verbatim: rebuild.detail)
                        } icon: {
                            Image(systemName: rebuild.passed
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(rebuild.passed ? Color.green : Color.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let rebuild {
                    Text("Rebuilt \(rebuild.rebuiltAt, format: .dateTime.hour().minute())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                DetailSectionHeader(title: "Indexes", systemImage: "arrow.triangle.2.circlepath")
            } footer: {
                SettingsNote("Rebuilds search, links, tags and properties from your notes, then checks them. Your notes and patients are not changed.")
            }

            // How the store is protected is General › Security's to say; this
            // section is only the one way to take notes out as plaintext.
            Section {
                Button("Export Markdown Vault…") {
                    exportFailure = nil
                    exportedSummary = nil
                    Task {
                        do {
                            if let report = try await exportMarkdown() {
                                exportedSummary = String(
                                    localized: "Exported \(report.notesWritten) notes as plaintext Markdown.")
                            }
                        } catch {
                            exportFailure = error.localizedDescription
                        }
                    }
                }
                .accessibilityIdentifier(SettingsIdentifiers.markdownExport)
                if let exportedSummary {
                    Text(verbatim: exportedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let exportFailure {
                    Text(verbatim: exportFailure)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exportInterruption {
                    Text(verbatim: exportInterruption)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                DetailSectionHeader(title: "Export", systemImage: "square.and.arrow.up")
            } footer: {
                SettingsNote("Writes every note as a readable Markdown file to a folder you choose, for use in another app. The result is plaintext. This replaces the old continuous mirror, which no longer runs.")
            }

            if let vaultReport {
                Section {
                    SettingsNote("An old plaintext Markdown mirror is still on disk. Review it before deleting: notes that exist only there can be imported, and notes that differ are shown for a choice.")
                    ForEach(vaultReport.unresolvedVaultOnly) { item in
                        LabeledContent(item.title.isEmpty ? String(localized: "(untitled)") : item.title,
                                       value: String(localized: "Only in the mirror"))
                    }
                    ForEach(vaultReport.unresolvedDivergent) { item in
                        LabeledContent(item.title.isEmpty ? String(localized: "(untitled)") : item.title,
                                       value: String(localized: "Differs"))
                    }
                    if !vaultReport.unresolvedVaultOnly.isEmpty {
                        Button(String(localized: "Import \(vaultReport.unresolvedVaultOnly.count) note(s) only in the mirror")) {
                            resolveVault(.importMirrorOnly)
                        }
                        .disabled(isResolvingVault || resolveLegacyVault == nil)
                    }
                    if !vaultReport.unresolvedDivergent.isEmpty {
                        Menu(String(localized: "Decide \(vaultReport.unresolvedDivergent.count) differing note(s)")) {
                            Button("Keep the database versions") { resolveVault(.keepDatabase) }
                            Button("Import the mirror versions as copies") { resolveVault(.importAsCopies) }
                            Button("Replace with the mirror versions", role: .destructive) { pendingMirrorReplace = true }
                        }
                        .disabled(isResolvingVault || resolveLegacyVault == nil)
                    }
                    if !vaultReport.parseFailures.isEmpty {
                        Text(verbatim: String(localized: "\(vaultReport.parseFailures.count) file(s) could not be read."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !vaultReport.skipped.isEmpty {
                        Text(verbatim: String(localized: "\(vaultReport.skipped.count) item(s) in the mirror are not notes (folders, other files, links) and are deleted with it."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let vaultFailure {
                        Text(verbatim: vaultFailure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let legacyVaultURL {
                        Button("Show Mirror in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([legacyVaultURL])
                        }
                    }
                    Button("Delete Plaintext Mirror", role: .destructive) {
                        pendingVaultDelete = true
                    }
                    // Never offered while a note exists only in the mirror, or
                    // differs, and has not been decided.
                    .disabled(vaultReport.hasUnresolved || isResolvingVault)
                } header: {
                    DetailSectionHeader(title: "Old Markdown Mirror", systemImage: "doc.text")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: preferredHeight)
        .task {
            summary = await loadSummary()
            restorePoints = await loadRestorePoints()
            vaultReport = await legacyVaultReport()
            vaultFailure = nil
        }
        .confirmationDialog("Delete this restore point?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let point = pendingDelete else { return }
                Task { await delete(point) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog("Restore from this restore point?", isPresented: Binding(
            get: { pendingRestore != nil },
            set: { if !$0 { pendingRestore = nil } }
        ), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let point = pendingRestore else { return }
                Task { await restore(point) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current data is replaced by what this restore point holds. A restore point of the current data is made first.")
        }
        .confirmationDialog("Replace the database versions with the mirror versions?",
                            isPresented: $pendingMirrorReplace, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { resolveVault(.useMirror) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mirrorReplaceMessage)
        }
        .confirmationDialog("Delete the plaintext Markdown mirror?", isPresented: $pendingVaultDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await deleteLegacyVault?()
                        vaultReport = nil
                        vaultFailure = nil
                    } catch {
                        vaultFailure = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(vaultDeleteMessage)
        }
    }

    private var mirrorReplaceMessage: String {
        let count = vaultReport?.unresolvedDivergent.count ?? 0
        return String(localized: "\(count) note(s) in the database are overwritten by the older text in the mirror. A restore point of the current data is made first.")
    }

    /// The warning, plus how many entries go without ever having been read as
    /// notes (folders, other files, links, files that failed to parse).
    private var vaultDeleteMessage: String {
        var message = String(localized: "The files are readable clinical text. Deleting them cannot be undone; APFS snapshots or backups may still hold copies.")
        if let vaultReport {
            let unseen = vaultReport.skipped.count + vaultReport.parseFailures.count
            if unseen > 0 {
                message += " " + String(localized: "\(unseen) item(s) that could not be read as notes will be deleted too.")
            }
        }
        return message
    }

    private func resolveVault(_ choice: LegacyVaultChoice) {
        guard let resolveLegacyVault else { return }
        isResolvingVault = true
        vaultFailure = nil
        Task {
            do {
                _ = try await resolveLegacyVault(choice)
            } catch {
                vaultFailure = error.localizedDescription
            }
            vaultReport = await legacyVaultReport()
            isResolvingVault = false
        }
    }

    private func restore(_ point: RestorePoint) async {
        isRestoring = true
        failure = nil
        do {
            try await restoreRestorePoint(point)
        } catch {
            failure = error.localizedDescription
        }
        restorePoints = await loadRestorePoints()
        isRestoring = false
        pendingRestore = nil
    }

    private func delete(_ point: RestorePoint) async {
        do {
            try await deleteRestorePoint(point)
            failure = nil
            restorePoints.removeAll { $0.id == point.id }
        } catch {
            failure = error.localizedDescription
        }
        pendingDelete = nil
    }

    static func sizeText(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    /// `~/Library/Containers/…` rather than the full home path: the row is
    /// one line, and the interesting part is the tail. Abbreviated against
    /// the account's home, not `NSHomeDirectory()`: inside the sandbox that
    /// is the container itself, which would fold the container out of the
    /// path and show the store somewhere it is not.
    static func abbreviated(_ url: URL) -> String {
        let path = url.path
        let home = userHomePath
        guard !home.isEmpty, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The account's home directory from its passwd entry, which the sandbox
    /// leaves alone.
    static var userHomePath: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "" }
        return String(cString: dir)
    }
}

/// When it was made and what it holds on the left, its size and a trash
/// button on the right.
private struct RestorePointRow: View {
    let point: RestorePoint
    let canRestore: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Chrome.Space.md) {
            VStack(alignment: .leading, spacing: Chrome.Space.xxs) {
                Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text(verbatim: "\(DisplayCopy.backupName(point.name)) · \(BackupFlowSheet.summary(counts: point.counts))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if point.needsUpgrade {
                    Text("Old format: readable by anyone with the file until it is converted. Lock and unlock to convert it, or delete it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Chrome.Space.sm)
            Text(verbatim: DataSettingsPane.sizeText(point.sizeBytes))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: onRestore) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!canRestore)
            .help("Restore from this restore point")
            .accessibilityLabel("Restore from this restore point")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete restore point")
            .accessibilityLabel("Delete restore point")
        }
        .padding(.vertical, Chrome.Space.xxs)
    }
}
