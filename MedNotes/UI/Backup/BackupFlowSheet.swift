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
    /// The safety copy of the current data failed: offer to go on without it.
    @State private var offerRestoreWithoutCopy = false

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
            if !passphrase.isEmpty, let problem = BackupPassphrasePolicy.validate(passphrase) {
                Text(verbatim: problem)
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
                .disabled(!passphrasesMatch || !BackupPassphrasePolicy.isAcceptable(passphrase) || isWorking
                          // An empty name would save as ".mednotesbackup", a hidden file.
                          || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    // A checked manifest describes the passphrase used for the
                    // check; editing the field invalidates it.
                    .onChange(of: passphrase) { manifest = nil }
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
                    if offerRestoreWithoutCopy {
                        Button("Restore Without a Copy", role: .destructive) {
                            restore(fileURL, withoutSafetyCopy: true)
                        }
                        .disabled(isWorking)
                    }
                    Button("Restore", role: .destructive) {
                        restore(fileURL, withoutSafetyCopy: false)
                    }
                    .prominentActionButtonStyle()
                    .disabled(isWorking)
                }
            }
        }
    }

    private func restore(_ fileURL: URL, withoutSafetyCopy: Bool) {
        isWorking = true
        failure = nil
        Task {
            do {
                try await session.performRestore(
                    from: fileURL, passphrase: passphrase, withoutSafetyCopy: withoutSafetyCopy)
            } catch {
                failure = error.localizedDescription
                if case .safetyCopyIncomplete = error as? BackupError { offerRestoreWithoutCopy = true }
            }
            isWorking = false
        }
    }

    private func inspect(_ fileURL: URL) {
        // Return can submit the field while a check is already running; a
        // second Argon2 derivation over the same file would race the first
        // result into the sheet.
        guard !isWorking, !passphrase.isEmpty else { return }
        isWorking = true
        failure = nil
        manifest = nil
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
