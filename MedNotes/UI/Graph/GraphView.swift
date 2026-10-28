import SwiftUI

/// Obsidian-style graph: a deterministic force-directed layout over the
/// resolved `wikilinks` + event–patient edges, rendered on Canvas. Clicking a
/// node jumps to it in the matching module. A settings panel on the right
/// filters, colours and re-shapes the picture.
struct GraphView: View {
    @EnvironmentObject private var session: AppSession
    @State private var viewport = GraphViewport()

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if session.graphData.nodes.isEmpty {
                    EmptyStateView(
                        title: "The graph is empty",
                        systemImage: "arrow.triangle.branch",
                        description: "Type [[ somewhere ]] inside a note to create links, and they will show up here.")
                } else if session.filteredGraph.nodes.isEmpty {
                    EmptyStateView(
                        title: "Nothing matches",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: "Change the filters to show more of the graph.")
                } else {
                    GraphCanvas(
                        graph: session.filteredGraph,
                        display: GraphCanvas.Display(settings: session.graphSettings),
                        viewport: $viewport
                    ) { node in
                        Task { await session.jumpToGraphNode(node) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if session.graphPanelShown {
                Divider()
                GraphSettingsPanel()
                    .frame(width: GraphSettingsPanel.width)
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
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await session.loadGraph() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh graph")
                Button {
                    session.graphPanelShown.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help(session.graphPanelShown ? "Hide Graph Settings" : "Show Graph Settings")
                .accessibilityLabel(session.graphPanelShown ? "Hide Graph Settings" : "Show Graph Settings")
            }
        }
        .task(id: session.noteEpoch + session.eventEpoch + session.patientEpoch) {
            await session.loadGraph()
        }
    }
}

/// The scrollable middle column: node list grouped by kind for keyboard and
/// screen-reader users; the canvas is decorative navigation. It lists what
/// the settings leave, the same nodes the canvas draws.
struct GraphNodeListView: View {
    @EnvironmentObject private var session: AppSession

    private var groups: [(kind: LinkingService.GraphNode.Kind, nodes: [LinkingService.GraphNode])] {
        let grouped = Dictionary(grouping: session.filteredGraph.nodes, by: \.kind)
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
            } else if session.filteredGraph.nodes.isEmpty {
                EmptyStateView(
                    title: "Nothing matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: "Change the filters to show more of the graph.")
            }
        }
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
    /// How the settings change the drawing; the forces also shape the layout.
    struct Display: Equatable {
        var arrows = false
        var sizeByDegree = true
        var forces = GraphLayout.Forces.standard

        init() {}
        init(settings: GraphSettings) {
            arrows = settings.arrows
            sizeByDegree = settings.sizeByDegree
            forces = settings.forces
        }
    }

    let graph: FilteredGraph
    var display = Display()
    /// The node to ring (the open note of a local graph).
    var highlight: String?
    /// Dragging pans. Off for a small embedded graph, where the drag belongs
    /// to the scroll view around it.
    var allowsPan = true
    @Binding var viewport: GraphViewport
    var onOpen: (LinkingService.GraphNode) -> Void

    @State private var positions: [String: CGPoint]
    /// The `layoutKey` the positions were computed for.
    @State private var positionsKey: Int?
    /// Changes when the nodes, links or forces do. Computed once: `graph` is
    /// fixed for this view, and the body re-runs on every hover.
    private let layoutKey: Int
    @State private var hovered: String?
    @State private var dragStart: CGSize?
    @State private var magnifyStart: CGFloat?

    /// Labels for every node from this zoom on.
    private static let labelAllScale: CGFloat = 1.8
    /// How long the forces must stay still before the layout is redone.
    private static let relayoutDelay: UInt64 = 250_000_000

    /// `layout` skips the first asynchronous pass, for offscreen renders that
    /// snapshot before it would finish.
    init(graph: FilteredGraph, display: Display = Display(), highlight: String? = nil,
         allowsPan: Bool = true, viewport: Binding<GraphViewport>,
         layout: [String: CGPoint] = [:], onOpen: @escaping (LinkingService.GraphNode) -> Void = { _ in }) {
        self.graph = graph
        self.display = display
        self.highlight = highlight
        self.allowsPan = allowsPan
        self._viewport = viewport
        self._positions = State(initialValue: layout)
        let key = Self.key(for: graph, forces: display.forces)
        self.layoutKey = key
        self._positionsKey = State(initialValue: layout.isEmpty ? nil : key)
        self.onOpen = onOpen
    }

    /// The whole graph, nothing filtered.
    init(graph: LinkingService.GraphData, viewport: Binding<GraphViewport>,
         layout: [String: CGPoint] = [:], onOpen: @escaping (LinkingService.GraphNode) -> Void = { _ in }) {
        self.init(graph: FilteredGraph(nodes: graph.nodes, edges: graph.edges),
                  viewport: viewport, layout: layout, onOpen: onOpen)
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
                    guard allowsPan else { return }
                    let start = dragStart ?? viewport.offset
                    dragStart = start
                    viewport.offset = CGSize(width: start.width + value.translation.width,
                                             height: start.height + value.translation.height)
                }
                .onEnded { _ in dragStart = nil },
                including: allowsPan ? .all : .subviews)
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
            // Changing a slider changes the key at every tick; only the last
            // one gets a layout. The wait comes before the work starts, since
            // work already running is only stopped at its next step.
            let warm = !positions.isEmpty
            if warm {
                try? await Task.sleep(nanoseconds: Self.relayoutDelay)
                guard !Task.isCancelled else { return }
            }
            let nodes = graph.nodes, edges = graph.edges, forces = display.forces
            let initial = warm ? positions : nil
            let cancellation = LayoutCancellation()
            let computed = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    GraphLayout.compute(nodes: nodes, edges: edges, forces: forces, initial: initial,
                                        cancelled: { cancellation.isCancelled })
                }.value
            } onCancel: {
                cancellation.cancel()
            }
            guard !Task.isCancelled else { return }
            positions = computed
            positionsKey = key
        }
    }

    /// Labels alone do not move anything, so only ids, links and forces count.
    private static func key(for graph: FilteredGraph, forces: GraphLayout.Forces) -> Int {
        var hasher = Hasher()
        for node in graph.nodes { hasher.combine(node.id) }
        for edge in graph.edges { hasher.combine(edge.sourceID); hasher.combine(edge.targetID) }
        hasher.combine(forces.center); hasher.combine(forces.repel)
        hasher.combine(forces.linkStrength); hasher.combine(forces.linkDistance)
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
        if display.arrows { drawArrowheads(in: &context, size: size, nodesByID: nodesByID, focus: focus) }

        let labelAll = viewport.scale >= Self.labelAllScale
        var labels: [(priority: Int, node: LinkingService.GraphNode, anchor: CGPoint)] = []
        for node in graph.nodes {
            guard let unit = positions[node.id] else { continue }
            let point = project(unit, size: size)
            guard point.x > -40, point.y > -40, point.x < size.width + 40, point.y < size.height + 40 else { continue }
            let dimmed = focus.map { !$0.contains(node.id) } ?? false
            let radius = radius(of: node)
            let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            let color = color(of: node)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(dimmed ? 0.2 : 1)))
            if node.id == hovered {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                               with: .color(color.opacity(0.5)), lineWidth: 2)
            }
            if node.id == highlight {
                context.stroke(Path(ellipseIn: rect.insetBy(dx: -4, dy: -4)),
                               with: .color(.primary.opacity(0.7)), lineWidth: 1.5)
            }
            let inFocus = focus?.contains(node.id) ?? false
            let isOpen = node.id == highlight
            guard !dimmed, node.kind == .patient || labelAll || inFocus || isOpen else { continue }
            let priority = node.id == hovered ? 0 : isOpen ? 1 : inFocus ? 1 : node.kind == .patient ? 2 : 3
            labels.append((priority, node, CGPoint(x: point.x, y: point.y + radius + 3)))
        }
        drawLabels(labels, in: &context)
    }

    /// Nodes with more links are bigger, up to a limit.
    private func radius(of node: LinkingService.GraphNode) -> CGFloat {
        let base: CGFloat = node.kind == .patient ? 9 : 6
        guard display.sizeByDegree else { return base }
        return base + min(8, CGFloat(graph.degree[node.id] ?? 0).squareRoot() * 1.2)
    }

    private func color(of node: LinkingService.GraphNode) -> Color {
        if let index = graph.colorIndex[node.id] { return GraphPalette.color(index) }
        return Self.tint(node.kind)
    }

    /// A small triangle on the target end of each link, which runs from the
    /// note that holds the link to what it points at.
    private func drawArrowheads(in context: inout GraphicsContext, size: CGSize,
                                nodesByID: [String: LinkingService.GraphNode], focus: Set<String>?) {
        var heads = Path()
        for edge in graph.edges {
            guard let a = positions[edge.sourceID], let b = positions[edge.targetID],
                  let target = nodesByID[edge.targetID] else { continue }
            let from = project(a, size: size), to = project(b, size: size)
            let dx = to.x - from.x, dy = to.y - from.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 14 else { continue }
            let ux = dx / length, uy = dy / length
            let tip = CGPoint(x: to.x - ux * (radius(of: target) + 1), y: to.y - uy * (radius(of: target) + 1))
            let left = CGPoint(x: tip.x - ux * 7 - uy * 3.5, y: tip.y - uy * 7 + ux * 3.5)
            let right = CGPoint(x: tip.x - ux * 7 + uy * 3.5, y: tip.y - uy * 7 - ux * 3.5)
            heads.move(to: tip); heads.addLine(to: left); heads.addLine(to: right); heads.closeSubpath()
        }
        context.fill(heads, with: .color(.primary.opacity(focus == nil ? 0.45 : 0.1)))
    }

    /// Labels in priority order (the hovered node, its neighbours, patients,
    /// the rest), each skipped if it would overlap one already drawn: on a
    /// dense patch the most relevant names stay readable instead of piling
    /// up. The hovered node's label sits on a backing so it always reads.
    private func drawLabels(_ labels: [(priority: Int, node: LinkingService.GraphNode, anchor: CGPoint)],
                            in context: inout GraphicsContext) {
        var placed: [CGRect] = []
        for label in labels.sorted(by: { $0.priority < $1.priority }) {
            let isHovered = label.priority == 0
            let text = context.resolve(Text(Self.shortName(label.node))
                .font(.caption2.weight(isHovered ? .semibold : .regular))
                .foregroundStyle(isHovered ? .primary : .secondary))
            let size = text.measure(in: CGSize(width: 200, height: 40))
            let frame = CGRect(x: label.anchor.x - size.width / 2, y: label.anchor.y,
                               width: size.width, height: size.height)
            let padded = frame.insetBy(dx: -3, dy: -1)
            guard !placed.contains(where: { $0.intersects(padded) }) else { continue }
            placed.append(padded)
            if isHovered {
                context.fill(Path(roundedRect: padded.insetBy(dx: -2, dy: -1), cornerRadius: 5),
                             with: .style(.background.opacity(0.9)))
            }
            context.draw(text, at: label.anchor, anchor: .top)
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

/// The eight colours a group can take.
enum GraphPalette {
    private static let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemTeal, .systemBlue, .systemPurple, .systemPink
    ]

    static func color(_ index: Int) -> Color {
        Color(nsColor: colors[min(max(0, index), colors.count - 1)])
    }
}

/// Tells a layout running off the main actor that nobody wants it any more.
final class LayoutCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
