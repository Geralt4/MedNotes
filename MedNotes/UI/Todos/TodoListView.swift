import SwiftUI

struct TodoListView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var swipe = SwipeRevealController()
    @State private var pendingDeleteId: UUID?

    var body: some View {
        List(selection: Binding<UUID?>(
            get: { session.selectedTodoId },
            set: { session.selectTodo($0) }
        )) {
            ForEach(session.todos) { todo in
                TodoRowView(todo: todo)
                    .swipeToDelete(id: todo.id, label: "Delete todo")
                    .tag(todo.id)
                    .contextMenu {
                        Button {
                            Task { await session.toggleTodo(id: todo.id) }
                        } label: {
                            Label(todo.isCompleted ? "Mark as not done" : "Mark as done",
                                  systemImage: todo.isCompleted ? "circle" : "checkmark.circle")
                        }
                        Divider()
                        Button(role: .destructive) {
                            pendingDeleteId = todo.id
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .swipeToDeleteContainer(swipe) { pendingDeleteId = $0 }
        .softTopEdge()
        // Rows re-sort as todos are completed or filtered; animate on identity
        // and order alone, so editing a title in the detail pane stays still.
        .animation(.default, value: session.todos.map(\.id))
        .navigationTitle("Todos")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // Icon-only, and no menu chevron, to keep this as narrow as the
                // sync and add buttons. The trailing toolbar items are laid out
                // as one cluster right-aligned to the window, so any width spent
                // here pushes the leading item left across the split divider —
                // a text label was wide enough to sit on the seam ("All" fit,
                // but "Completed" would not have).
                // The filled glyph stands in for the label the icon gave up:
                // it says a filter is narrowing the list without costing width.
                Menu {
                    Picker("Filter", selection: Binding(
                        get: { session.todoFilter },
                        set: { session.todoFilter = $0 }
                    )) {
                        ForEach(TodoFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: session.todoFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter: \(session.todoFilter.title)")
                .accessibilityLabel("Filter")
                .accessibilityValue(session.todoFilter.title)
            }
            ToolbarItem(placement: .automatic) {
                SyncPillMenu(bridge: .reminders, service: session.appleReminders,
                             summary: session.lastRemindersSyncSummary) {
                    Task { await session.syncRemindersNow() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.newTodo() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New todo")
                .accessibilityLabel("New todo")
            }
        }
        .overlay {
            if session.todos.isEmpty {
                listEmptyState
            }
        }
        // Search lives in the column, not the toolbar: as a toolbar item
        // macOS pins it to a fixed width at the window's trailing edge,
        // which pushed this list's own buttons across the split divider.
        .safeAreaInset(edge: .top) {
            ListSearchField(
                prompt: "Search todos",
                text: Binding(
                    get: { session.todoSearchText },
                    set: { session.todoSearchText = $0 }
                ),
                focusToken: session.searchFocusToken
            )
            .padding(.horizontal, Chrome.Space.sm)
            .padding(.bottom, Chrome.Space.sm - 2)
        }
        .confirmationDialog("Delete this todo?", isPresented: Binding(
            get: { pendingDeleteId != nil },
            set: { if !$0 { pendingDeleteId = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    Task { await session.deleteTodo(id: id) }
                }
                pendingDeleteId = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteId = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private var listEmptyState: some View {
        let query = session.todoSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            EmptyStateView.search(text: session.todoSearchText)
        } else if session.todoFilter != .all && session.todoPoolCount > 0 {
            EmptyStateView(title: "No Matching Todos", systemImage: "checklist", description: "Try a different filter.")
        } else {
            EmptyStateView(title: "No Todos", systemImage: "checklist", description: "Create a todo to get started.")
        }
    }
}
