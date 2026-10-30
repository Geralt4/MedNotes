import SwiftUI

/// The open note's neighbourhood: the notes, patients and events within a
/// few links of it, drawn small, with the same nodes listed under the
/// picture for keyboard and screen-reader users. Closed by default, and the
/// whole graph is read only while it is open.
struct NoteGraphSection: View {
    let noteID: UUID

    @EnvironmentObject private var session: AppSession
    @State private var expanded: Bool
    @State private var local = FilteredGraph()
    @State private var viewport = GraphViewport()

    init(noteID: UUID, initiallyExpanded: Bool = false) {
        self.noteID = noteID
        self._expanded = State(initialValue: initiallyExpanded)
    }

    private static let listLimit = 12
    private var nodeID: String { "n:\(noteID.uuidString)" }

    var body: some View {
        InspectorSection(
            title: "Local graph", systemImage: "point.3.connected.trianglepath.dotted",
            count: max(0, local.nodes.count - 1), expanded: $expanded
        ) {
            VStack(alignment: .leading, spacing: Chrome.Space.sm) {
                Picker("Depth", selection: $session.localGraphSettings.localDepth) {
                    ForEach(Array(GraphSettings.depthRange), id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .help("How many links away from this note to look")

                HStack(spacing: Chrome.Space.md) {
                    Toggle("Patients", isOn: $session.localGraphSettings.showPatients)
                    Toggle("Events", isOn: $session.localGraphSettings.showEvents)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                if local.nodes.count > 1 {
                    GraphCanvas(
                        graph: local,
                        display: GraphCanvas.Display(settings: session.localGraphSettings),
                        highlight: nodeID, allowsPan: false, viewport: $viewport
                    ) { node in
                        Task { await session.jumpToGraphNode(node) }
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: Chrome.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: Chrome.Radius.chip)
                            .strokeBorder(Chrome.chipFillStrong, lineWidth: 1))
                    neighbours
                } else {
                    Text("This note is not linked to anything yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        // The graph is read, and the neighbourhood worked out, only while the
        // section is open; leaving it open follows edits through the epochs.
        .task(id: "\(expanded)|\(session.noteEpoch)|\(session.eventEpoch)|\(session.patientEpoch)") {
            guard expanded else { return }
            await session.loadGraph()
        }
        .task(id: localKey) {
            guard expanded else { local = FilteredGraph(); return }
            let id = nodeID
            let depth = session.localGraphSettings.localDepth
            let data = session.graphData
            let settings = session.localGraphSettings
            local = await Task.detached(priority: .userInitiated) {
                GraphFilter.local(of: id, depth: depth, data: data, settings: settings)
            }.value
        }
    }

    /// What the neighbourhood is computed from. The graph's read counter says
    /// "it was read again": a link changed to another note leaves the node and
    /// edge counts as they were.
    private var localKey: String {
        let s = session.localGraphSettings
        return "\(expanded)|\(noteID)|\(s.localDepth)|\(s.showPatients)|\(s.showEvents)"
            + "|\(session.graphGeneration)"
    }

    private var neighbours: some View {
        let others = local.nodes.filter { $0.id != nodeID }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(others.prefix(Self.listLimit), id: \.id) { node in
                Button {
                    Task { await session.jumpToGraphNode(node) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(node.kind))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(node.kind == .patient ? DisplayCopy.patient(node.label) : DisplayCopy.title(node.label))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if others.count > Self.listLimit {
                Text("+\(others.count - Self.listLimit) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private static func symbol(_ kind: LinkingService.GraphNode.Kind) -> String {
        switch kind {
        case .note: return "doc.text"
        case .patient: return "person.fill"
        case .event: return "calendar"
        }
    }
}
