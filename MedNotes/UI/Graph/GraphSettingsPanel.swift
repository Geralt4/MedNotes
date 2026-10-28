import SwiftUI

/// The graph's settings, in the column at the right of the canvas: what to
/// show (Filters), what to colour (Groups), how to draw it (Display) and how
/// the layout pulls and pushes (Forces).
struct GraphSettingsPanel: View {
    static let width: CGFloat = 270

    @EnvironmentObject private var session: AppSession
    @State private var filtersOpen = true
    @State private var groupsOpen = false
    @State private var displayOpen = false
    @State private var forcesOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.Space.sm) {
                section("Filters", isOpen: $filtersOpen) { filters }
                section("Groups", isOpen: $groupsOpen) { groups }
                section("Display", isOpen: $displayOpen) { display }
                section("Forces", isOpen: $forcesOpen) { forces }
            }
            .padding(Chrome.Space.md)
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph settings")
    }

    // MARK: - Sections

    private var filters: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            queryField("Search notes", text: $session.graphSettings.query)
            Toggle("Patients", isOn: $session.graphSettings.showPatients)
            Toggle("Events", isOn: $session.graphSettings.showEvents)
            Toggle("Orphans", isOn: $session.graphSettings.showOrphans)
                .help("Show notes that link to nothing and are linked from nothing")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            ForEach($session.graphSettings.groups) { $group in
                VStack(alignment: .leading, spacing: Chrome.Space.xs) {
                    HStack(spacing: Chrome.Space.xs) {
                        queryField("Group search", text: $group.query)
                        Button {
                            session.graphSettings.groups.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove group")
                        .accessibilityLabel("Remove group")
                    }
                    colorRow(selection: $group.colorIndex)
                }
            }
            if session.graphSettings.groups.count < GraphSettings.maxGroups {
                Button {
                    // The next colour no group uses yet.
                    let used = Set(session.graphSettings.groups.map(\.colorIndex))
                    let next = (0..<GraphGroup.paletteSize).first { !used.contains($0) } ?? 0
                    session.graphSettings.groups.append(GraphGroup(colorIndex: next))
                } label: {
                    Label("New group", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }
            if session.graphSettings.groups.isEmpty {
                Text("A group colours the notes a search finds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Toggle("Arrows", isOn: $session.graphSettings.arrows)
            Toggle("Size by links", isOn: $session.graphSettings.sizeByDegree)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var forces: some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            slider("Center force", value: $session.graphSettings.forces.center, range: GraphLayout.Forces.centerRange)
            slider("Repel force", value: $session.graphSettings.forces.repel, range: GraphLayout.Forces.repelRange)
            slider("Link force", value: $session.graphSettings.forces.linkStrength, range: GraphLayout.Forces.linkStrengthRange)
            slider("Link distance", value: $session.graphSettings.forces.linkDistance, range: GraphLayout.Forces.linkDistanceRange)
            Button("Reset forces") { session.graphSettings.forces = .standard }
                .buttonStyle(.borderless)
                .disabled(session.graphSettings.forces == .standard)
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(
        _ title: LocalizedStringKey, isOpen: Binding<Bool>, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Chrome.Space.sm) {
            Button {
                isOpen.wrappedValue.toggle()
            } label: {
                HStack(spacing: Chrome.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isOpen.wrappedValue ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            if isOpen.wrappedValue {
                content()
                    .padding(.leading, Chrome.Space.md)
            }
        }
    }

    private func queryField(_ prompt: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack(spacing: Chrome.Space.xs) {
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            SearchSyntaxHelpButton()
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: range) { Text(title) }
                .controlSize(.small)
        }
    }

    private func colorRow(selection: Binding<Int>) -> some View {
        HStack(spacing: Chrome.Space.xs + 1) {
            ForEach(0..<GraphGroup.paletteSize, id: \.self) { index in
                Button {
                    selection.wrappedValue = index
                } label: {
                    Circle()
                        .fill(GraphPalette.color(index))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().strokeBorder(
                            Color.primary.opacity(selection.wrappedValue == index ? 0.8 : 0), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(selection.wrappedValue == index ? .isSelected : [])
            }
        }
    }
}
