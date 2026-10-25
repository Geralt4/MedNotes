import SwiftUI

/// Obsidian-style graph: a deterministic force-directed layout over the
/// `note_links` + event–patient edges, rendered on Canvas. Clicking a node
/// jumps to it in the matching module.
struct GraphView: View {
    @EnvironmentObject private var session: AppSession
    @State private var viewport = GraphViewport()

    var body: some View {
        Group {
            if session.graphData.nodes.isEmpty {
                EmptyStateView(
                    title: "The graph is empty",
                    systemImage: "arrow.triangle.branch",
                    description: "Type [[ somewhere ]] inside a note to create links, and they will show up here.")
            } else {
                GraphCanvas(graph: session.graphData, viewport: $viewport) { node in
                    Task { await session.jumpToGraphNode(node) }
                }
                .task { await session.loadGraph() }
            }
        }
        .softTopEdge()
        .navigationTitle("Graph")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    viewport.zoom(by: 1 / 1.4)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .keyboardShortcut("-")
                .help("Zoom Out (⌘−)")
                .accessibilityLabel("Zoom Out")
                Button {
                    viewport.zoom(by: 1.4)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .keyboardShortcut("=")
                .help("Zoom In (⌘+)")
                .accessibilityLabel("Zoom In")
                Button {
                    viewport = GraphViewport()
                } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .keyboardShortcut("0")
                .help("Fit Graph (⌘0)")
                .accessibilityLabel("Fit Graph")
            }
            ToolbarSpacerCompat()
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

/// Zoom and pan over the graph, around the centre of the view.
struct GraphViewport: Equatable {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let scales: ClosedRange<CGFloat> = 0.3...4

    /// Zooms keeping the point at `anchor` where it is; `anchor` is
    /// measured from the view's centre, so `.zero` zooms about the centre.
    mutating func zoom(by factor: CGFloat, about anchor: CGSize = .zero) {
        let next = min(Self.scales.upperBound, max(Self.scales.lowerBound, scale * factor))
        let ratio = next / scale
        offset = CGSize(width: anchor.width - (anchor.width - offset.width) * ratio,
                        height: anchor.height - (anchor.height - offset.height) * ratio)
        scale = next
    }
}

/// The graph drawn in one `Canvas`: a view per node does not survive a
/// practice's thousands of records. The layout (`GraphLayout`) is computed
/// off the main actor once per graph. Hovering a node brings it and its links
/// forward; patients are always labelled, the rest when hovered or zoomed in.
/// Decorative for assistive technology: the middle column lists every node.
struct GraphCanvas: View {
    let graph: LinkingService.GraphData
    @Binding var viewport: GraphViewport
    var onOpen: (LinkingService.GraphNode) -> Void

    @State private var positions: [String: CGPoint]
    /// The `layoutKey` the positions were computed for.
    @State private var positionsKey: Int?
    /// Changes when the nodes or links do. Computed once: `graph` is fixed
    /// for this view, and the body re-runs on every hover.
    private let layoutKey: Int
    @State private var hovered: String?
    @State private var dragStart: CGSize?
    @State private var magnifyStart: CGFloat?

    /// Labels for every node from this zoom on.
    private static let labelAllScale: CGFloat = 1.8

    /// `layout` skips the first asynchronous pass, for offscreen renders that
    /// snapshot before it would finish.
    init(graph: LinkingService.GraphData, viewport: Binding<GraphViewport>,
         layout: [String: CGPoint] = [:], onOpen: @escaping (LinkingService.GraphNode) -> Void = { _ in }) {
        self.graph = graph
        self._viewport = viewport
        self._positions = State(initialValue: layout)
        let key = Self.key(for: graph)
        self.layoutKey = key
        self._positionsKey = State(initialValue: layout.isEmpty ? nil : key)
        self.onOpen = onOpen
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let nodesByID = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let focus = hovered.map { GraphLayout.neighbours(of: $0, edges: graph.edges).union([$0]) }
            Canvas { context, _ in
                draw(in: &context, size: size, nodesByID: nodesByID, focus: focus)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = node(at: point, size: size)
                case .ended: hovered = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                if let id = node(at: point, size: size), let node = nodesByID[id] { onOpen(node) }
            }
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let start = dragStart ?? viewport.offset
                    dragStart = start
                    viewport.offset = CGSize(width: start.width + value.translation.width,
                                             height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = magnifyStart ?? viewport.scale
                    magnifyStart = start
                    // About the pinch, not the middle of the view.
                    let anchor = CGSize(width: value.startLocation.x - size.width / 2,
                                        height: value.startLocation.y - size.height / 2)
                    viewport.zoom(by: start * value.magnification / viewport.scale, about: anchor)
                }
                .onEnded { _ in magnifyStart = nil })
            .overlay(alignment: .bottomLeading) { hoverCaption(nodesByID: nodesByID) }
            .overlay {
                if positions.isEmpty { ProgressView() }
            }
        }
        .accessibilityHidden(true)
        // Keeps the previous layout on screen until the new one is ready.
        .task(id: layoutKey) {
            let key = layoutKey
            guard key != positionsKey else { return }
            let nodes = graph.nodes, edges = graph.edges
            let computed = await Task.detached(priority: .userInitiated) {
                GraphLayout.compute(nodes: nodes, edges: edges)
            }.value
            guard !Task.isCancelled else { return }
            positions = computed
            positionsKey = key
        }
    }

    /// Labels alone do not move anything, so only ids and links count.
    private static func key(for graph: LinkingService.GraphData) -> Int {
        var hasher = Hasher()
        for node in graph.nodes { hasher.combine(node.id) }
        for edge in graph.edges { hasher.combine(edge.sourceID); hasher.combine(edge.targetID) }
        return hasher.finalize()
    }

    // MARK: - Geometry

    /// Unit-square layout to view coordinates: fitted, then zoomed about the
    /// centre and panned.
    private func project(_ unit: CGPoint, size: CGSize) -> CGPoint {
        let fit = min(size.width, size.height)
        let x = (unit.x - 0.5) * fit * viewport.scale + size.width / 2 + viewport.offset.width
        let y = (unit.y - 0.5) * fit * viewport.scale + size.height / 2 + viewport.offset.height
        return CGPoint(x: x, y: y)
    }

    /// The node within 12pt of `point`. The pointer is taken into the
    /// layout's unit space rather than every node into the view's, so a
    /// mouse move allocates nothing.
    private func node(at point: CGPoint, size: CGSize) -> String? {
        let span = min(size.width, size.height) * viewport.scale
        guard span > 0 else { return nil }
        let unit = CGPoint(x: (point.x - size.width / 2 - viewport.offset.width) / span + 0.5,
                           y: (point.y - size.height / 2 - viewport.offset.height) / span + 0.5)
        return GraphLayout.nearest(to: unit, in: positions, within: 12 / span)
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      nodesByID: [String: LinkingService.GraphNode], focus: Set<String>?) {
        guard !positions.isEmpty else { return }
        var plain = Path(), lit = Path()
        for edge in graph.edges {
            guard let a = positions[edge.sourceID], let b = positions[edge.targetID] else { continue }
            let from = project(a, size: size), to = project(b, size: size)
            if let hovered, edge.sourceID == hovered || edge.targetID == hovered {
                lit.move(to: from); lit.addLine(to: to)
            } else {
                plain.move(to: from); plain.addLine(to: to)
            }
        }
        context.stroke(plain, with: .color(.primary.opacity(focus == nil ? 0.28 : 0.06)), lineWidth: 1)
        if let hovered, let node = nodesByID[hovered] {
            context.stroke(lit, with: .color(Self.tint(node.kind).opacity(0.85)), lineWidth: 1.5)
        }

        let labelAll = viewport.scale >= Self.labelAllScale
        for node in graph.nodes {
            guard let unit = positions[node.id] else { continue }
            let point = project(unit, size: size)
            guard point.x > -40, point.y > -40, point.x < size.width + 40, point.y < size.height + 40 else { continue }
            let dimmed = focus.map { !$0.contains(node.id) } ?? false
            let radius: CGFloat = node.kind == .patient ? 9 : 6
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Self.tint(node.kind).opacity(dimmed ? 0.2 : 1)))
            if node.id == hovered {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(Self.tint(node.kind).opacity(0.5)), lineWidth: 2)
            }
            let inFocus = focus?.contains(node.id) ?? false
            guard !dimmed, node.kind == .patient || labelAll || inFocus else { continue }
            let label = Text(Self.shortName(node))
                .font(.caption2.weight(node.id == hovered ? .semibold : .regular))
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: point.x, y: point.y + radius + 3), anchor: .top)
        }
    }

    @ViewBuilder
    private func hoverCaption(nodesByID: [String: LinkingService.GraphNode]) -> some View {
        if let hovered, let node = nodesByID[hovered] {
            Label(Self.displayName(node), systemImage: Self.symbol(node.kind))
                .font(.callout)
                .padding(.horizontal, Chrome.Space.md)
                .padding(.vertical, Chrome.Space.xs + 2)
                .background(.regularMaterial, in: Capsule())
                .padding(Chrome.Space.md)
                .allowsHitTesting(false)
        }
    }

    /// Patients fall back to "Unnamed Patient" (not "(untitled)"), the same
    /// wording the rest of the app uses; titles fall back to "Untitled".
    private static func displayName(_ node: LinkingService.GraphNode) -> String {
        node.kind == .patient ? DisplayCopy.patient(node.label) : DisplayCopy.title(node.label)
    }

    private static func shortName(_ node: LinkingService.GraphNode) -> String {
        let name = displayName(node)
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }

    private static func tint(_ kind: LinkingService.GraphNode.Kind) -> Color {
        switch kind {
        case .note: return .accentColor
        case .patient: return Color(nsColor: .systemBlue)
        case .event: return Color(nsColor: .systemIndigo)
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
