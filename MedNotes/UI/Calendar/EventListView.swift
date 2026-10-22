import SwiftUI

struct EventListView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var swipe = SwipeRevealController()
    @State private var pendingDeleteId: UUID?

    private var monthGroups: [(key: Date, events: [CalendarEvent])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: session.events) { event in
            cal.dateInterval(of: .month, for: event.startDate)?.start ?? event.startDate
        }
        return grouped.keys.sorted().map { key in
            (key, grouped[key]!.sorted { $0.startDate < $1.startDate })
        }
    }

    var body: some View {
        List(selection: Binding<UUID?>(
            get: { session.selectedEventId },
            set: { session.selectEvent($0) }
        )) {
            ForEach(monthGroups, id: \.key) { group in
                Section {
                    ForEach(group.events) { event in
                        EventRowView(event: event)
                            .swipeToDelete(id: event.id, label: "Delete event")
                            .tag(event.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeleteId = event.id
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text(group.key, format: Date.FormatStyle().month(.wide).year())
                }
            }
        }
        .listStyle(.sidebar)
        .swipeToDeleteContainer(swipe) { pendingDeleteId = $0 }
        .softTopEdge()
        .animation(.default, value: session.events.map(\.id))
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                // Icon-only, and no menu chevron, to keep this as narrow as the
                // sync and add buttons. The trailing toolbar items are laid out
                // as one cluster right-aligned to the window, so any width spent
                // here pushes the leading item left across the split divider —
                // a text label ("Upcoming") was wide enough to sit on the seam.
                // The filled glyph stands in for the label the icon gave up:
                // it says a filter is narrowing the list without costing width.
                Menu {
                    Picker("Filter", selection: Binding(
                        get: { session.eventFilter },
                        set: { session.eventFilter = $0 }
                    )) {
                        ForEach(EventFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: session.eventFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter: \(session.eventFilter.title)")
                .accessibilityLabel("Filter")
                .accessibilityValue(session.eventFilter.title)
            }
            ToolbarItem(placement: .automatic) {
                SyncPillMenu(bridge: .calendar, service: session.appleCalendar,
                             summary: session.lastCalendarSyncSummary) {
                    Task { await session.syncCalendarNow() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.newEvent() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New event")
                .accessibilityLabel("New event")
            }
        }
        .overlay {
            if session.events.isEmpty {
                listEmptyState
            }
        }
        // Search lives in the column, not the toolbar: as a toolbar item
        // macOS pins it to a fixed width at the window's trailing edge,
        // which pushed this list's own buttons across the split divider.
        .safeAreaInset(edge: .top) {
            ListSearchField(
                prompt: "Search events",
                text: Binding(
                    get: { session.eventSearchText },
                    set: { session.eventSearchText = $0 }
                ),
                focusToken: session.searchFocusToken
            )
            .padding(.horizontal, Chrome.Space.sm)
            .padding(.bottom, Chrome.Space.sm - 2)
        }
        .confirmationDialog("Delete this event?", isPresented: Binding(
            get: { pendingDeleteId != nil },
            set: { if !$0 { pendingDeleteId = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteId {
                    Task { await session.deleteEvent(id: id) }
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
        let query = session.eventSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            EmptyStateView.search(text: session.eventSearchText)
        } else if session.eventFilter != .all && session.eventPoolCount > 0 {
            EmptyStateView(title: "No Matching Events", systemImage: "calendar", description: "Try a different filter.")
        } else {
            EmptyStateView(title: "No Events", systemImage: "calendar", description: "Create an event to get started.")
        }
    }
}
