import SwiftUI

@main
struct MedNotesApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            MedNotesCommands(session: session)
        }

        // The main window's curtain cannot reach these two windows.
        Window("Activity", id: "activity") {
            ActivityView()
                .environmentObject(session)
                .privacyCover(session)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .defaultSize(width: 760, height: 480)

        Settings {
            SettingsView()
                .environmentObject(session)
                .privacyCover(session)
        }
    }
}

private struct MedNotesCommands: Commands {
    @ObservedObject var session: AppSession
    @FocusedValue(\.deleteCommand) private var deleteCommand

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(session.selectedModule.newItemTitle) {
                Task { await session.createInCurrentModule() }
            }
            .keyboardShortcut("n")
            .disabled(!session.canUseStore)
        }

        // Locking applies to the whole session, so it lives in the app menu
        // just below Settings…, as password managers do. Not ⌘L: that is a
        // text-editing shortcut, and ⇧⌘L already opens the Activity window.
        //
        // The group is replaced rather than a group placed `after:
        // .appSettings`: on this SDK that lands the new item *before* the
        // system's Settings…, moving Settings… off the app-menu position the
        // AX review scripts use. Settings… is rebuilt first, with the same
        // title and ⌘,, and the lock sits under it.
        CommandGroup(replacing: .appSettings) {
            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Lock MedNotes") {
                Task { await session.lockOnRequest() }
            }
            .keyboardShortcut("l", modifiers: [.control, .command])
            .disabled(!session.canUseStore)
        }

        CommandGroup(after: .importExport) {
            Button("Back Up…") {
                session.presentBackup()
            }
            .disabled(!session.canUseStore)

            Button("Restore from Backup…") {
                Task { await session.presentRestore() }
            }
            .disabled(!session.canUseStore)

            Divider()

            Button("Import Legacy Data…") {
                Task { await session.presentImport() }
            }
            .disabled(!session.canUseStore)
        }

        CommandGroup(after: .toolbar) {
            Button("Quick Open…") {
                session.showSwitcher = true
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!session.canUseStore)

            Button("Sync Calendar Now") {
                Task { await session.syncCalendarNow() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!session.canUseStore)

            Button("Sync Reminders Now") {
                Task { await session.syncRemindersNow() }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!session.canUseStore)
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                session.focusSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(!session.canUseStore || !session.selectedModule.hasSearch)
        }

        CommandGroup(after: .pasteboard) {
            // Only the main window publishes this; in Settings or Activity
            // the item is disabled and ⌘⌫ stays with their own views. ⌘⌫
            // while typing deletes to the start of the line instead.
            Button("Delete") {
                deleteCommand?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(deleteCommand == nil)

            Button(session.selectedNoteIsPinned ? "Unpin" : "Pin") {
                Task { await session.pinSelectedNote() }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!session.canPinSelection)

            Button("Toggle Completed") {
                Task { await session.toggleSelectedTodo() }
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!session.canToggleSelectedTodo)
        }

        CommandMenu("Go") {
            ForEach(Array(AppModule.allCases.enumerated()), id: \.element.id) { index, module in
                Button(module.title) {
                    session.selectedModule = module
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!session.canUseStore)
            }
        }
    }
}
