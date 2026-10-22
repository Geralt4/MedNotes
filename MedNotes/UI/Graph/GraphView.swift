import SwiftUI

/// Lightweight Obsidian-style graph: a deterministic cluster layout over the
/// `note_links` + event–patient edges, rendered on Canvas. Clicking a node
/// jumps to it in the matching module.
struct GraphView: View {
    @EnvironmentObject private var session: AppSession

    var body: some View {
        Group {
            if session.graphData.nodes.isEmpty {
                EmptyStateView(
                    title: "The graph is empty",
                    systemImage: "arrow.triangle.branch",
                    description: "Type [[ somewhere ]] inside a note to create links, and they will show up here.")
            } else {
                GraphCanvas(graph: session.graphData)
                    .task { await session.loadGraph() }
            }
        }
        .softTopEdge()
        .navigationTitle("Graph")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await session.loadGraph() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh graph")
            }
        }
        .task(id: session.noteEpoch + session.eventEpoch + session.patientEpoch) {
            await session.loadGraph()
        }
    }
}

/// The scrollable middle column: node list grouped by kind for keyboard and
/// screen-reader users; the canvas is decorative navigation.
struct GraphNodeListView: View {
    @EnvironmentObject private var session: AppSession

    private var groups: [(kind: LinkingService.GraphNode.Kind, nodes: [LinkingService.GraphNode])] {
        let grouped = Dictionary(grouping: session.graphData.nodes, by: \.kind)
        let order: [LinkingService.GraphNode.Kind] = [.note, .patient, .event]
        return order.compactMap { kind in
            guard let nodes = grouped[kind], !nodes.isEmpty else { return nil }
            return (kind, nodes)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.kind) { group in
                Section(DisplayCopy.graphGroup(group.kind)) {
                    ForEach(group.nodes, id: \.id) { node in
                        Button {
                            Task { await session.jumpToGraphNode(node) }
                        } label: {
                            Text(node.kind == .patient
                                 ? DisplayCopy.patient(node.label)
                                 : DisplayCopy.title(node.label))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .softTopEdge()
        .overlay {
            if session.graphData.nodes.isEmpty {
                EmptyStateView(
                    title: "No links yet",
                    systemImage: "arrow.triangle.branch",
                    description: "Link notes with [[double brackets]] to build the graph.")
            }
        }
        .task { await session.loadGraph() }
    }
}

private struct GraphCanvas: View {
    let graph: LinkingService.GraphData
    @State private var hovered: String?

    /// Deterministic layout: three vertical clusters (notes / patients /
    /// events), nodes evenly spaced within each column, jittered by hash so
    /// dense graphs still read as a constellation.
    private func layout(in size: CGSize) -> [String: CGPoint] {
        var positions: [String: CGPoint] = [:]
        var byKind: [LinkingService.GraphNode.Kind: [LinkingService.GraphNode]] = [:]
        for node in graph.nodes { byKind[node.kind, default: []].append(node) }
        let columns: [(kind: LinkingService.GraphNode.Kind, x: CGFloat)] = [
            (.note, 0.18), (.patient, 0.5), (.event, 0.82)
        ]
        for column in columns {
            let nodes = (byKind[column.kind] ?? []).sorted { $0.id < $1.id }
            let count = max(nodes.count, 1)
            let usableHeight = size.height - 80
            for (index, node) in nodes.enumerated() {
                let jitterX = CGFloat(abs(node.id.hashValue % 47) - 23)
                positions[node.id] = CGPoint(
                    x: size.width * column.x + jitterX,
                    y: 40 + usableHeight * (CGFloat(index) + 0.5) / CGFloat(count))
            }
        }
        return positions
    }

    var body: some View {
        GeometryReader { geo in
            let positions = layout(in: geo.size)
            ZStack {
                ForEach(Array(graph.edges.enumerated()), id: \.offset) { _, edge in
                    if let from = positions[edge.sourceID], let to = positions[edge.targetID] {
                        Path { path in
                            path.move(to: from)
                            path.addLine(to: to)
                        }
                        .stroke(Color.primary.opacity(0.16), lineWidth: 1)
                    }
                }

                ForEach(graph.nodes) { node in
                    if let point = positions[node.id] {
                        GraphNodeLabel(node: node, isHovered: hovered == node.id)
                            .position(point)
                            .onHover { hovering in
                                hovered = hovering ? node.id : nil
                            }
                            .onTapGesture {
                                Task { await jump(for: node) }
                            }
                            .help("Open \(node.kind == .patient ? DisplayCopy.patient(node.label) : DisplayCopy.title(node.label))")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @EnvironmentObject private var session: AppSession

    private func jump(for node: LinkingService.GraphNode) async -> Void {
        await session.jumpToGraphNode(node)
    }
}

private struct GraphNodeLabel: View {
    let node: LinkingService.GraphNode
    let isHovered: Bool

    /// Patients fall back to "Unnamed Patient" (not "(untitled)"), the same
    /// wording the rest of the app uses; titles fall back to "Untitled".
    private var displayName: String {
        node.kind == .patient ? DisplayCopy.patient(node.label) : DisplayCopy.title(node.label)
    }

    private var tint: Color {
        switch node.kind {
        case .note: return .accentColor
        case .patient: return Color(nsColor: .systemBlue)
        case .event: return Color(nsColor: .systemIndigo)
        }
    }

    private var symbol: String {
        switch node.kind {
        case .note: return "doc.text"
        case .patient: return "person.fill"
        case .event: return "calendar"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            IconBadge(systemImage: symbol, tint: tint)
                .controlSize(.regular)
                .shadow(color: tint.opacity(isHovered ? 0.6 : 0.2), radius: isHovered ? 8 : 3)
            Text(displayName)
                .font(.caption2.weight(isHovered ? .semibold : .regular))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 110)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .scaleEffect(isHovered ? 1.08 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
