import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        VStack(spacing: 0) {
            // Banners sit below the split view: above it they pushed the
            // toolbar's reserved height into the content, leaving a blurred
            // band over the list search fields (macOS 26).
            content
            #if DEBUG
            // `PreviewSeed.isActive` is already a hardcoded `false` in release,
            // so the branch is dead there either way; the `#if` also keeps the
            // banner's strings out of the shipped binary.
            if PreviewSeed.isActive {
                SampleDataBanner()
            }
            #endif
            if let warning = session.integrityWarning {
                IntegrityBanner(message: warning) {
                    session.integrityWarning = nil
                }
            }
        }
        // The overlays below are only as big as this stack. It fills the
        // window whatever `content` shows: the startup error view sizes to its
        // text, and the curtain over a cancelled unlock or a missing key used
        // to shrink to a box in the middle, with the window around it bare.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The session keeps keyboard focus out of this window under the curtain.
        .background(WindowReader { session.coverWindow($0) })
        .overlay {
            if session.showSwitcher {
                QuickSwitcherView()
                    .transition(.opacity)
            }
        }
        // The curtain hides this only from sight: without this, VoiceOver and
        // any app with Accessibility access still read the rows under it.
        .accessibilityHidden(session.showsPrivacyCurtain)
        // The privacy curtain: while locked or migrating, no record may be
        // visible, and the window is covered before it is torn down.
        .overlay {
            if session.showsPrivacyCurtain {
                PrivacyCurtain(
                    session: session,
                    onUnlock: { Task { await session.unlock() } })
            }
        }
        // Switching apps raises and lowers the curtain from
        // `AppSession.observeAppActivation`, window or no window. A launch in
        // the background never resigns active, so the curtain takes its first
        // state from here.
        .onAppear {
            session.windowDidAppear(appIsActive: NSApp.isActive)
        }
        // Screen lock, sleep and user switching lock the store from
        // `AppSession.observeSystemLockEvents`, window or no window.
        // Pointer movement over the window postpones the idle lock while
        // MedNotes is active; so do keys, clicks, scrolling and dictation
        // (`AppSession.observeUserInput`), and coming back to the app
        // (`AppSession.observeAppActivation`).
        .onContinuousHover { _ in session.noteInteraction() }
        // Alerts and sheets are drawn above the curtain. A lock dismisses
        // them all; an alert raised while locked (a draft the lock could not
        // save) waits for the unlock, and a sheet is covered while inactive.
        .alert("Error", isPresented: Binding(
            get: { session.errorMessage != nil && !session.isLocked },
            set: { if !$0 { session.dismissError() } }
        )) {
            Button("OK") { session.dismissError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .sheet(item: $session.backupFlow) { flow in
            BackupFlowSheet(flow: flow)
                .environmentObject(session)
                .privacyCover(session)
        }
        .sheet(item: $session.importFlow) { flow in
            ImportFlowSheet(flow: flow)
                .environmentObject(session)
                .privacyCover(session)
        }
        .sheet(item: $session.destinationFlow) { flow in
            flow.wizard
                .privacyCover(session)
        }
        .alert("MedNotes", isPresented: Binding(
            get: { session.notice != nil && !session.isLocked },
            set: { if !$0 { session.notice = nil } }
        )) {
            Button("OK") { session.notice = nil }
        } message: {
            Text(verbatim: session.notice ?? "")
        }
        .confirmationDialog(session.pendingDeleteTitle, isPresented: $session.confirmDelete, titleVisibility: .visible) {
            let archives = session.pendingDeletionArchives
            Button(archives ? "Archive" : "Delete",
                   role: archives ? nil : .destructive) {
                Task { await session.deleteInCurrentModule() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: session.pendingDeleteMessage)
        }
        // Edit › Delete is enabled only while this window is key and can ask
        // about its selection. See `DeleteShortcut`.
        .focusedSceneValue(\.deleteCommand, session.canRequestDelete
                           ? DeleteCommand { session.requestDelete() } : nil)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let initError = session.initError {
                StartupErrorView(message: initError)
            } else if !session.isReady {
                StartupProgressView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 216, max: 280)
                } content: {
                    Group {
                        switch session.selectedModule {
                        case .notes:
                            NoteListView()
                        case .patients:
                            PatientListView()
                        case .todos:
                            TodoListView()
                        case .calendar:
                            EventListView()
                        case .graph:
                            GraphNodeListView()
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 440)
                    .id(session.selectedModule)
                } detail: {
                    detailView
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        // Centres a startup error in the space above the banners instead of
        // leaving it at the top of the stack.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailView: some View {
        switch session.selectedModule {
        case .notes:
            if session.selectedNoteId != nil {
                NoteDetailView()
            } else {
                ModuleEmptyState(
                    title: "No note selected",
                    systemImage: "doc.text",
                    description: "Select a note, or create a new one to get started.",
                    actionTitle: "New Note"
                ) {
                    Task { await session.newNote() }
                }
            }
        case .patients:
            if session.selectedPatientId != nil {
                PatientDetailView()
            } else {
                ModuleEmptyState(
                    title: "No patient selected",
                    systemImage: "person.2",
                    description: "Select a patient, or create a new one to get started.",
                    actionTitle: "New Patient"
                ) {
                    Task { await session.newPatient() }
                }
            }
        case .todos:
            if session.selectedTodoId != nil {
                TodoDetailView()
            } else {
                ModuleEmptyState(
                    title: "No todo selected",
                    systemImage: "checklist",
                    description: "Select a todo, or create a new one to get started.",
                    actionTitle: "New Todo"
                ) {
                    Task { await session.newTodo() }
                }
            }
        case .calendar:
            if session.selectedEventId != nil {
                EventDetailView()
            } else {
                ModuleEmptyState(
                    title: "No event selected",
                    systemImage: "calendar",
                    description: "Select an event, or create a new one to get started.",
                    actionTitle: "New Event"
                ) {
                    Task { await session.newEvent() }
                }
            }
        case .graph:
            GraphView()
        }
    }
}

#if DEBUG

/// Shown only under `--preview-seed`. Two windows of the same app, one of them
/// over a store that will eventually hold real patient records, is not a state
/// to leave the reviewer guessing about.
private struct SampleDataBanner: View {
    var body: some View {
        HStack(spacing: Chrome.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("SAMPLE DATA — throwaway preview store, not your records")
                .fontWeight(.semibold)
            Spacer(minLength: 0)
        }
        .font(.caption)
        // Fixed dark-on-orange: the bar keeps its warning colour in both themes.
        .foregroundStyle(.black.opacity(0.85))
        .padding(.horizontal, Chrome.Space.md)
        .padding(.vertical, Chrome.Space.sm - 2)
        .frame(maxWidth: .infinity)
        .background(Color.orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample data. This window is running on a throwaway preview store.")
    }
}

#endif

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        EmptyStateView(
            title: "Backend failed to start",
            systemImage: "exclamationmark.triangle.fill",
            message: message
        )
    }
}

/// The lock screen. It covers the window the instant the app becomes
/// inactive, so no patient record is ever visible behind a locked session.
private struct PrivacyCurtain: View {
    let session: AppSession
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
            VStack(spacing: Chrome.Space.md) {
                Image(systemName: session.needsRecovery ? "exclamationmark.triangle.fill" : "lock.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(session.needsRecovery ? Color.orange : Color.secondary)
                Text(session.needsRecovery
                     ? "The device key is missing"
                     : (session.isMigrating ? "Encrypting MedNotes" : "MedNotes is locked"))
                    .font(.title3.weight(.semibold))
                Text(verbatim: curtainMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                if session.needsRecovery {
                    RecoveryChooser(session: session)
                } else if session.isMigrating {
                    MigrationWizard(session: session)
                } else {
                    // Why the last attempt failed, e.g. a cancelled Touch ID
                    // prompt. The store behind it is intact; Unlock retries.
                    if session.isLocked, let failure = session.initError {
                        Text(verbatim: failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    Button("Unlock", action: onUnlock)
                        .keyboardShortcut(.defaultAction)
                        .prominentActionButtonStyle()
                }
            }
            .padding(Chrome.Space.xl)
        }
        .transition(.opacity)
    }

    private var curtainMessage: String {
        if session.needsRecovery {
            return String(localized: "Encrypted data exists, but the Keychain item that holds its key is gone. Restore a portable backup to recover. MedNotes will not start an empty database over this data.")
        }
        if session.isMigrating {
            return String(localized: "MedNotes is converting this store to an encrypted one. Make and verify a backup first; the wizard will not touch your data until it has.")
        }
        return String(localized: "Touch ID or your account password unlocks MedNotes.")
    }
}

/// The missing-key recovery path: pick a portable backup and its passphrase,
/// then restore it with a fresh device key.
private struct RecoveryChooser: View {
    @ObservedObject var session: AppSession
    @State private var backupURL: URL?
    @State private var passphrase = ""
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: Chrome.Space.sm) {
            if let backupURL {
                Text(verbatim: backupURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Button("Choose Backup…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [.data]
                    panel.message = String(localized: "Choose a portable backup (.mednotesbackup) to recover this store.")
                    if panel.runModal() == .OK { backupURL = panel.url }
                }
            }
            SecureField("Backup passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .labelsHidden()
            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360)
            }
            Button(isWorking ? "Recovering…" : "Recover Store") {
                guard let backupURL else { return }
                isWorking = true
                failure = nil
                Task {
                    do {
                        try await session.recoverFromBackup(at: backupURL, passphrase: passphrase)
                    } catch {
                        failure = error.localizedDescription
                    }
                    isWorking = false
                }
            }
            .disabled(backupURL == nil || passphrase.isEmpty || isWorking)
            .prominentActionButtonStyle()
        }
        .padding(.top, Chrome.Space.sm)
    }
}

/// The plaintext → encrypted conversion wizard. It requires a verified v2
/// backup before it will stage anything.
private struct MigrationWizard: View {
    @ObservedObject var session: AppSession
    @State private var backupURL: URL?
    @State private var passphrase = ""
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: Chrome.Space.sm) {
            if let backupURL {
                Text(verbatim: backupURL.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Button("Choose Backup Location…") {
                    let panel = NSSavePanel()
                    panel.canCreateDirectories = true
                    panel.nameFieldStringValue = "\(String(localized: "MedNotes Encryption Backup")).\(BackupArchiveV2.fileExtension)"
                    panel.message = String(localized: "MedNotes will write a portable backup here and verify it before encrypting anything.")
                    if panel.runModal() == .OK { backupURL = panel.url }
                }
            }
            SecureField("Backup passphrase (16+ characters)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .labelsHidden()
            if let failure {
                Text(verbatim: failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360)
            }
            Button(isWorking ? "Encrypting…" : "Encrypt Store") {
                guard let backupURL else { return }
                isWorking = true
                failure = nil
                Task {
                    do {
                        // A portable v2 backup is written, then re-opened to
                        // prove the passphrase and the file, before staging.
                        try await session.migrationBackup(to: backupURL, passphrase: passphrase)
                        try await session.runMigration(backupURL: backupURL, passphrase: passphrase)
                    } catch {
                        failure = error.localizedDescription
                    }
                    isWorking = false
                }
            }
            .disabled(backupURL == nil || passphrase.count < BackupPassphrasePolicy.minimumCustomLength || isWorking)
            Button("Cancel") { session.cancelMigration() }
                .disabled(isWorking)
        }
        .padding(.top, Chrome.Space.sm)
    }
}

private struct StartupProgressView: View {
    var body: some View {
        VStack(spacing: Chrome.Space.lg) {
            ProgressView()
            Text("Starting MedNotes…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
