import SwiftUI

/// Obsidian-style ⌘O quick open. Light matching over notes, patients, todos,
/// and events via one overlay; Enter opens the highlighted hit.
struct QuickSwitcherView: View {
    @EnvironmentObject private var session: AppSession
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Scrim: click-through blocker that also dismisses.
            scrim
            panel
        }
        .task {
            focused = true
            await session.updateSwitcherResults()
        }
        // Narrowing the query can leave the highlight past the end of the new
        // results, where Enter silently does nothing. Start over on each edit.
        .onChange(of: session.switcherText) {
            selection = 0
        }
        // Results arrive after a debounce, so the highlight restarts with them too.
        .onChange(of: session.switcherResults) {
            selection = 0
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.25)
            .ignoresSafeArea()
            .onTapGesture { session.showSwitcher = false }
    }

    private var panel: some View {
        let moveUp = { selection = max(selection - 1, 0) }
        let moveDown = { selection = min(selection + 1, max(session.switcherResults.count - 1, 0)) }

        return VStack(spacing: 0) {
            searchBar
            Divider()
            resultsArea
        }
        .frame(width: 560, height: 400)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .quickSwitcherArrowKeys(up: moveUp, down: moveDown)
        .onExitCommand { session.showSwitcher = false }
    }

    private var searchBar: some View {
        HStack(spacing: Chrome.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Jump to note, patient, todo or event…", text: $session.switcherText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { confirmSelection() }
            Text("esc")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Chrome.Space.md)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if session.switcherResults.isEmpty {
            Text(session.switcherText.isEmpty ? "Type to search" : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Chrome.Space.xl)
        } else {
            resultList
        }
    }

    private var resultList: some View {
        List(selection: $selection) {
            ForEach(Array(session.switcherResults.enumerated()), id: \.element.id) { index, hit in
                rowButton(hit, index: index)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func rowButton(_ hit: AppSession.SwitcherHit, index: Int) -> some View {
        Button {
            selection = index
            confirmSelection()
        } label: {
            QuickSwitcherRow(hit: hit)
        }
        .buttonStyle(.plain)
        .tag(index)
        .listRowBackground(index == selection
            ? Color.accentColor.opacity(0.15)
            : Color.clear)
    }

    private func confirmSelection() {
        guard session.switcherResults.indices.contains(selection) else { return }
        let hit = session.switcherResults[selection]
        Task { await session.open(hit) }
    }
}

// Arrow keys drive the highlighted row on macOS 14+; on macOS 13 rows remain
// mouse-selectable and Enter opens the first match.
extension View {
    @ViewBuilder
    func quickSwitcherArrowKeys(up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self
                .onKeyPress(.downArrow) { down(); return .handled }
                .onKeyPress(.upArrow) { up(); return .handled }
        } else {
            self
        }
    }
}

private struct QuickSwitcherRow: View {
    let hit: AppSession.SwitcherHit

    private var icon: String {
        switch hit.kind {
        case .note: return "doc.text"
        case .patient: return "person"
        case .todo: return "checklist"
        case .event: return "calendar"
        }
    }

    private var tint: Color {
        switch hit.kind {
        case .note: return Color.accentColor
        case .patient: return Color(nsColor: .systemBlue)
        case .todo: return Color(nsColor: .systemOrange)
        case .event: return Color(nsColor: .systemIndigo)
        }
    }

    var body: some View {
        HStack(spacing: Chrome.Space.sm) {
            IconBadge(systemImage: icon, tint: tint)
                .controlSize(.small)
            Text(hit.title)
                .font(.body)
                .lineLimit(1)
            Spacer()
            Text(hit.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
