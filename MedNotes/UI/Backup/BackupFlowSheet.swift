import SwiftUI

/// The two dialogs behind File › Back Up… and File › Restore from Backup….
/// The session runs the panels and the service; this view only collects the
/// passphrase, shows what a backup contains, and reports the outcome.
struct BackupFlowSheet: View {
    @EnvironmentObject private var session: AppSession
    let flow: AppSession.BackupFlow

    @State private var name = String(localized: "MedNotes backup")
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var manifest: BackupManifest?
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            switch flow {
            case .backUp:
                backUpForm
            case .restore(let fileURL):
                restoreForm(fileURL)
            }
        }
        .padding(Chrome.Space.xl)
        .frame(width: 460)
        .controlSize(.large)
    }

    // MARK: - Back up

    private var passphrasesMatch: Bool {
        !passphrase.isEmpty && passphrase == confirmation
    }

    private var backUpForm: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            Label("Back Up", systemImage: "externaldrive.badge.timemachine")
                .font(.title3.weight(.semibold))
            Text("The backup is encrypted with this passphrase. There is no way to open it without the passphrase, and MedNotes does not keep a copy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            EditorTextField("Name", text: $name)
            EditorField("Passphrase") {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            EditorField("Confirm passphrase") {
                SecureField("Confirm passphrase", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
            }
            if !confirmation.isEmpty, !passphrasesMatch {
                Text("The passphrases do not match.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.dismissBackupFlow() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Location & Back Up…") {
                    isWorking = true
                    failure = nil
                    Task {
                        do {
                            try await session.performBackup(name: name, passphrase: passphrase)
                        } catch {
                            failure = error.localizedDescription
                        }
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .prominentActionButtonStyle()
                .disabled(!passphrasesMatch || isWorking)
            }
        }
    }

    // MARK: - Restore

    private func restoreForm(_ fileURL: URL) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.lg) {
            Label("Restore from Backup", systemImage: "arrow.counterclockwise.circle")
                .font(.title3.weight(.semibold))
            Text(verbatim: fileURL.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
            EditorField("Passphrase") {
                SecureField("Passphrase", text: $passphrase)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { inspect(fileURL) }
            }
            if let manifest {
                VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                    Text(verbatim: DisplayCopy.backupName(manifest.name))
                        .font(.headline)
                    Text("Made \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(verbatim: Self.summary(of: manifest))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Restoring replaces every record in MedNotes with this backup. A restore point of the current data is kept first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Chrome.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Chrome.editorFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.card))
            }
            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { session.dismissBackupFlow() }
                    .keyboardShortcut(.cancelAction)
                if manifest == nil {
                    Button("Check Backup") { inspect(fileURL) }
                        .keyboardShortcut(.defaultAction)
                        .prominentActionButtonStyle()
                        .disabled(passphrase.isEmpty || isWorking)
                } else {
                    Button("Restore", role: .destructive) {
                        isWorking = true
                        failure = nil
                        Task {
                            do {
                                try await session.performRestore(from: fileURL, passphrase: passphrase)
                            } catch {
                                failure = error.localizedDescription
                            }
                            isWorking = false
                        }
                    }
                    .prominentActionButtonStyle()
                    .disabled(isWorking)
                }
            }
        }
    }

    private func inspect(_ fileURL: URL) {
        isWorking = true
        failure = nil
        Task {
            do {
                manifest = try await session.inspectBackup(at: fileURL, passphrase: passphrase)
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    static func summary(of manifest: BackupManifest) -> String {
        summary(counts: manifest.counts)
    }

    /// "12 patients · 40 notes · …" from row counts keyed by table, the shape
    /// both a backup manifest and `Database.counts()` produce.
    static func summary(counts: [String: Int]) -> String {
        let order = ["patients", "notes", "todo_items", "calendar_events"]
        let labels: [String: String] = [
            "patients": String(localized: "patients"),
            "notes": String(localized: "notes"),
            "todo_items": String(localized: "todos"),
            "calendar_events": String(localized: "events")
        ]
        return order.compactMap { key in
            counts[key].map { "\($0) \(labels[key] ?? key)" }
        }.joined(separator: " · ")
    }
}
