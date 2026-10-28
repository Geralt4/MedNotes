import SwiftUI

/// Window › Activity: the audit trail, newest first, narrowed by what an
/// entry concerns. Every save, archive, discard, backup, restore and import
/// lands here, so the trail is readable without opening the database.
struct ActivityView: View {
    @EnvironmentObject private var session: AppSession
    @State private var entries: [AuditLogEntry] = []
    @State private var scope: Scope = .all
    @State private var query = ""

    enum Scope: String, CaseIterable, Identifiable {
        case all, patients, notes, todos, events, system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return String(localized: "All")
            case .patients: return String(localized: "Patients")
            case .notes: return String(localized: "Notes")
            case .todos: return String(localized: "Todos")
            case .events: return String(localized: "Events")
            case .system: return String(localized: "System")
            }
        }

        func matches(_ entry: AuditLogEntry) -> Bool {
            switch self {
            case .all: return true
            case .patients: return entry.entityType == "patient"
            case .notes: return entry.entityType == "note"
            case .todos: return entry.entityType == "todo"
            case .events: return entry.entityType == "calendar_event"
            case .system:
                return !["patient", "note", "todo", "calendar_event"].contains(entry.entityType)
            }
        }
    }

    private var filtered: [AuditLogEntry] {
        let needle = WikiLinkParser.normalizedKey(query)
        return entries.filter { entry in
            scope.matches(entry) && (needle.isEmpty
                || WikiLinkParser.normalizedKey(DisplayCopy.auditDetails(entry)).contains(needle)
                || WikiLinkParser.normalizedKey(DisplayCopy.auditAction(entry.action)).contains(needle)
                || WikiLinkParser.normalizedKey(entry.entityId).contains(needle))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Chrome.Space.md) {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ListSearchField(prompt: "Search activity", text: $query)
                    .frame(maxWidth: 260)
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
            .padding(Chrome.Space.md)
            Divider()
            Table(filtered) {
                TableColumn("When") { entry in
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 150, ideal: 170)
                TableColumn("Action") { entry in
                    Text(verbatim: DisplayCopy.auditAction(entry.action))
                }
                .width(min: 140, ideal: 180)
                TableColumn("Details") { entry in
                    Text(verbatim: DisplayCopy.auditDetails(entry))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .overlay {
                if filtered.isEmpty {
                    EmptyStateView(title: "No Activity", systemImage: "clock.arrow.circlepath",
                                   description: "Saves, archives, backups and imports are listed here.")
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        // The trail is dropped while the store is locked (the window is
        // covered too) and read again once it is open, including the first
        // time, when the window was restored before the store was ready.
        .task(id: session.canUseStore) {
            if session.canUseStore {
                await reload()
            } else {
                entries = []
                query = ""
            }
        }
    }

    private func reload() async {
        entries = await session.recentActivity()
    }
}
