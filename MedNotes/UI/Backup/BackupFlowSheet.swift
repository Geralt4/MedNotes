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
    /// The passphrase "Generate" made, kept only while this sheet is open (and
    /// wiped when it goes), so the backup can tell it from a typed one. It is
    /// kept even when the fields are edited away from it: typing one character
    /// and deleting it must not turn it into a typed passphrase.
    @State private var generated: String?
    /// The backup has started, so the generated passphrase is off the screen:
    /// it is shown until then, and not again.
    @State private var generatedHidden = false
    @State private var confirmedSaved = false
    @State private var copied = false
    @State private var generateFailed = false
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

    /// Where the passphrase in the fields came from: the generated one for as
    /// long as the fields hold exactly it, whatever was typed and undone in
    /// between; otherwise a typed one.
    static func source(passphrase: String, generated: String?, confirmedSaved: Bool) -> BackupPassphraseSource {
        guard let generated, passphrase == generated else { return .typed }
        return .generated(confirmedSaved: confirmedSaved)
    }

    /// Whether the Back Up button is enabled. A generated passphrase also needs
    /// the user's word that it is saved.
    static func canBackUp(name: String, passphrase: String, confirmation: String,
                          generated: String?, confirmedSaved: Bool, isWorking: Bool) -> Bool {
        guard !passphrase.isEmpty, passphrase == confirmation,
              BackupPassphrasePolicy.isAcceptable(passphrase), !isWorking,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return source(passphrase: passphrase, generated: generated, confirmedSaved: confirmedSaved)
            != .generated(confirmedSaved: false)
    }

    /// The passphrase fields and Generate wait while a backup is being written:
    /// a new passphrase then would not be the one the archive is sealed with.
    static func canEditPassphrase(isWorking: Bool) -> Bool { !isWorking }

    private var canBackUp: Bool {
        Self.canBackUp(name: name, passphrase: passphrase, confirmation: confirmation,
                       generated: generated, confirmedSaved: confirmedSaved, isWorking: isWorking)
    }

    /// What `performBackup` is told about where the passphrase came from.
    private var source: BackupPassphraseSource {
        Self.source(passphrase: passphrase, generated: generated, confirmedSaved: confirmedSaved)
    }

    /// The generated passphrase is on screen: while the fields still hold it,
    /// until the backup starts.
    private var showsGenerated: Bool {
        generated != nil && passphrase == generated && !generatedHidden
    }

    private func generate() {
        do {
            let new = try BackupPassphrasePolicy.generate()
            passphrase = new
            confirmation = new
            generated = new
            generatedHidden = false
            confirmedSaved = false
            copied = false
            generateFailed = false
        } catch {
            generateFailed = true
        }
    }

    /// Takes the generated passphrase out of the state.
    private func forgetGenerated() {
        generated = nil
        generatedHidden = false
        confirmedSaved = false
        copied = false
    }

    private var generatedBlock: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Text("Write this passphrase down now. It is shown only once, and without it the backup cannot be opened.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let generated {
                Text(verbatim: generated)
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                    .textSelection(.disabled)
                    .padding(Chrome.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Chrome.editorFill, in: RoundedRectangle(cornerRadius: Chrome.Radius.card))
                    .accessibilityIdentifier("generatedPassphrase")
                HStack {
                    Button(copied ? "Copied" : "Copy") {
                        PassphraseClipboard.shared.copy(generated)
                        copied = true
                    }
                    Text("The clipboard is cleared after a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("I have saved this passphrase", isOn: $confirmedSaved)
                .toggleStyle(.checkbox)
            if !confirmedSaved {
                Text("Confirm that you have saved the passphrase before the backup is made.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
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
                HStack {
                    SecureField("Passphrase", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .disabled(!Self.canEditPassphrase(isWorking: isWorking))
                    Button("Generate", action: generate)
                        .help("Make a strong passphrase")
                        .disabled(!Self.canEditPassphrase(isWorking: isWorking))
                }
            }
            if showsGenerated { generatedBlock }
            if generateFailed {
                Text("A passphrase could not be generated. Try again, or type your own.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            EditorField("Confirm passphrase") {
                SecureField("Confirm passphrase", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .disabled(!Self.canEditPassphrase(isWorking: isWorking))
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
                    // Shown once: from here on the passphrase is no longer on screen.
                    generatedHidden = true
                    let source = source
                    Task {
                        do {
                            try await session.performBackup(name: name, passphrase: passphrase, source: source)
                        } catch {
                            failure = UserFacingFailure.message(for: error, during: .backup)
                        }
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .prominentActionButtonStyle()
                .disabled(!canBackUp)  // an empty name would save as ".mednotesbackup", a hidden file
            }
        }
        .onDisappear {
            passphrase = ""
            confirmation = ""
            forgetGenerated()
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
                failure = UserFacingFailure.message(for: error, during: .restore)
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
                failure = UserFacingFailure.message(for: error, during: .restore)
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
