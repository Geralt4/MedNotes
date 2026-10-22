import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var swipe = SwipeRevealController()
    @State private var pendingDeleteId: UUID?

    private var pinned: [Note] { session.notes.filter(\.isPinned) }
    private var unpinned: [Note] { session.notes.filter { !$0.isPinned } }

    var body: some View {
        List(selection: Binding<UUID?>(
            get: { session.selectedNoteId },
            set: { session.select($0) }
        )) {
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { note in
                        noteRow(note)
                    }
                }
            }
            Section {
                ForEach(unpinned) { note in
                    noteRow(note)
                }
            }
        }
        .listStyle(.sidebar)
        .swipeToDeleteContainer(swipe) { pendingDeleteId = $0 }
        .softTopEdge()
        // Pinning moves a row between sections; animate on identity and order
        // alone, so typing in the detail pane does not ripple the list.
        .animation(.default, value: session.notes.map(\.id))
        .navigationTitle("Notes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.newNote() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New note")
                .accessibilityLabel("New note")
            }
        }
        .overlay {
            if session.notes.isEmpty {
                listEmptyState
            }
        }
        // Search lives in the column, not the toolbar: as a toolbar item
        // macOS pins it to a fixed width at the window's trailing edge,
        // which pushed this list's own buttons across the split divider.
        .safeAreaInset(edge: .top) {
            ListSearchField(
                prompt: "Search notes",
                text: Binding(
                    get: { session.searchText },
                    set: { session.searchText = $0 }
                ),
                focusToken: session.searchFocusToken
            )
            .padding(.horizontal, Chrome.Space.sm)
            .padding(.bottom, Chrome.Space.sm - 2)
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(
            get: { pendingDeleteId != nil },
            set: { if !$0 { pendingDeleteId = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    Task { await session.deleteNote(id: id) }
                }
                pendingDeleteId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func noteRow(_ note: Note) -> some View {
        NoteRowView(note: note)
            .swipeToDelete(id: note.id, label: "Delete note")
            .tag(note.id)
            .contextMenu {
                Button {
                    Task { await session.togglePin(note) }
                } label: {
                    Label(note.isPinned ? "Unpin" : "Pin",
                          systemImage: note.isPinned ? "pin.slash" : "pin")
                }
                Divider()
                Button(role: .destructive) {
                    pendingDeleteId = note.id
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    @ViewBuilder
    private var listEmptyState: some View {
        let query = session.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            EmptyStateView.search(text: session.searchText)
        } else {
            EmptyStateView(title: "No Notes", systemImage: "doc.text", description: "Create a note to get started.")
        }
    }
}
