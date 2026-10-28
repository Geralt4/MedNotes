import Foundation

/// A colour group: notes matching `query` are drawn in palette colour
/// `colorIndex`. The first group a note matches wins.
struct GraphGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var query = ""
    var colorIndex = 0

    init(id: UUID = UUID(), query: String = "", colorIndex: Int = 0) {
        self.id = id
        self.query = query
        self.colorIndex = colorIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? ""
        colorIndex = (try? c.decodeIfPresent(Int.self, forKey: .colorIndex)) ?? 0
    }

    static let paletteSize = 8
}

/// What the graph's settings panel holds. Lives in the encrypted store
/// (`app_state`), never in user defaults: filter and group queries are
/// often a patient's name.
///
/// Decoding is lenient so a settings row from a newer or older build never
/// stops the graph from opening: missing or odd values take their defaults.
struct GraphSettings: Codable, Equatable, Sendable {
    /// Same syntax as the notes search; empty shows every note.
    var query = ""
    var showPatients = true
    var showEvents = true
    /// Notes (and others) with no link at all.
    var showOrphans = true
    var arrows = false
    var sizeByDegree = true
    var forces = GraphLayout.Forces.standard
    var groups: [GraphGroup] = []
    /// How many links out from the open note the local graph reaches.
    var localDepth = 1

    static let depthRange = 1...3
    static let maxGroups = 8

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphSettings()
        query = (try? c.decodeIfPresent(String.self, forKey: .query)) ?? d.query
        showPatients = (try? c.decodeIfPresent(Bool.self, forKey: .showPatients)) ?? d.showPatients
        showEvents = (try? c.decodeIfPresent(Bool.self, forKey: .showEvents)) ?? d.showEvents
        showOrphans = (try? c.decodeIfPresent(Bool.self, forKey: .showOrphans)) ?? d.showOrphans
        arrows = (try? c.decodeIfPresent(Bool.self, forKey: .arrows)) ?? d.arrows
        sizeByDegree = (try? c.decodeIfPresent(Bool.self, forKey: .sizeByDegree)) ?? d.sizeByDegree
        forces = ((try? c.decodeIfPresent(GraphLayout.Forces.self, forKey: .forces)) ?? d.forces).clamped
        let stored = (try? c.decodeIfPresent([GraphGroup].self, forKey: .groups)) ?? []
        groups = Array(stored.prefix(Self.maxGroups)).map {
            var group = $0
            group.colorIndex = min(max(0, group.colorIndex), GraphGroup.paletteSize - 1)
            return group
        }
        let depth = (try? c.decodeIfPresent(Int.self, forKey: .localDepth)) ?? d.localDepth
        localDepth = min(max(depth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
    }

    /// The same settings with every value inside its range.
    var clamped: GraphSettings {
        var copy = self
        copy.forces = forces.clamped
        copy.localDepth = min(max(localDepth, Self.depthRange.lowerBound), Self.depthRange.upperBound)
        copy.groups = Array(groups.prefix(Self.maxGroups)).map {
            var group = $0
            group.colorIndex = min(max(0, group.colorIndex), GraphGroup.paletteSize - 1)
            return group
        }
        return copy
    }

    /// Whether anything but the layout would change what is drawn.
    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The graph after the settings are applied.
struct FilteredGraph: Equatable, Sendable {
    typealias Node = LinkingService.GraphNode
    typealias Edge = LinkingService.GraphEdge

    var nodes: [Node] = []
    var edges: [Edge] = []
    /// Distinct links per node among the nodes shown.
    var degree: [String: Int] = [:]
    /// Palette index per coloured node.
    var colorIndex: [String: Int] = [:]
}

/// Applies `GraphSettings` to the whole graph. Pure.
enum GraphFilter {
    typealias Node = LinkingService.GraphNode
    typealias Edge = LinkingService.GraphEdge

    /// - Parameters:
    ///   - matching: ids (`n:<uuid>`) of the notes the query matches; nil
    ///     when there is no query. Patients and events are shown only when
    ///     tied to a shown note.
    ///   - groupMatches: for each group, the ids of the notes it matches.
    ///   - alwaysKeep: ids shown whatever the filters say (the open note of
    ///     a local graph); the orphan filter still applies to the rest.
    static func apply(
        _ data: LinkingService.GraphData, settings: GraphSettings,
        matching: Set<String>? = nil, groupMatches: [UUID: Set<String>] = [:],
        alwaysKeep: Set<String> = []
    ) -> FilteredGraph {
        var neighbours: [String: Set<String>] = [:]
        for edge in data.edges where edge.sourceID != edge.targetID {
            neighbours[edge.sourceID, default: []].insert(edge.targetID)
            neighbours[edge.targetID, default: []].insert(edge.sourceID)
        }

        func isNote(_ id: String) -> Bool { id.hasPrefix("n:") }

        var keep = Set<String>()
        // Notes first: the query decides them.
        for node in data.nodes where node.kind == .note {
            if alwaysKeep.contains(node.id) || (matching.map { $0.contains(node.id) } ?? true) { keep.insert(node.id) }
        }
        // Then patients, which a query keeps only through a shown note.
        for node in data.nodes where node.kind == .patient {
            if alwaysKeep.contains(node.id) { keep.insert(node.id); continue }
            guard settings.showPatients else { continue }
            if matching == nil || (neighbours[node.id] ?? []).contains(where: { isNote($0) && keep.contains($0) }) {
                keep.insert(node.id)
            }
        }
        // Then events, through their patient.
        for node in data.nodes where node.kind == .event {
            if alwaysKeep.contains(node.id) { keep.insert(node.id); continue }
            guard settings.showEvents else { continue }
            if matching == nil || (neighbours[node.id] ?? []).contains(where: { keep.contains($0) && !isNote($0) }) {
                keep.insert(node.id)
            }
        }

        var edges: [Edge] = []
        var seen = Set<Edge>()
        for edge in data.edges where edge.sourceID != edge.targetID
            && keep.contains(edge.sourceID) && keep.contains(edge.targetID) {
            if seen.insert(edge).inserted { edges.append(edge) }
        }
        let degree = degrees(edges)

        var shown = data.nodes.filter { keep.contains($0.id) }
        if !settings.showOrphans {
            shown = shown.filter { degree[$0.id, default: 0] > 0 || alwaysKeep.contains($0.id) }
        }
        let shownIDs = Set(shown.map(\.id))

        var colors: [String: Int] = [:]
        for node in shown where node.kind == .note {
            for group in settings.groups where groupMatches[group.id]?.contains(node.id) == true {
                colors[node.id] = group.colorIndex
                break
            }
        }
        return FilteredGraph(
            nodes: shown, edges: edges.filter { shownIDs.contains($0.sourceID) && shownIDs.contains($0.targetID) },
            degree: shownIDs.reduce(into: [:]) { $0[$1] = degree[$1, default: 0] }, colorIndex: colors)
    }

    /// Distinct links per node, a link counted once whichever way it points.
    private static func degrees(_ edges: [Edge]) -> [String: Int] {
        var degree: [String: Int] = [:]
        var seen = Set<Edge>()
        for edge in edges {
            let key = edge.sourceID < edge.targetID ? edge : Edge(sourceID: edge.targetID, targetID: edge.sourceID)
            if seen.insert(key).inserted {
                degree[edge.sourceID, default: 0] += 1
                degree[edge.targetID, default: 0] += 1
            }
        }
        return degree
    }

    /// The ids within `depth` links of `center`, links read either way.
    static func neighbourhood(of center: String, depth: Int, edges: [Edge]) -> Set<String> {
        var adjacent: [String: [String]] = [:]
        for edge in edges where edge.sourceID != edge.targetID {
            adjacent[edge.sourceID, default: []].append(edge.targetID)
            adjacent[edge.targetID, default: []].append(edge.sourceID)
        }
        var reached: Set<String> = [center]
        var frontier: [String] = [center]
        for _ in 0..<max(0, min(depth, GraphSettings.depthRange.upperBound)) {
            var next: [String] = []
            for id in frontier {
                for other in adjacent[id] ?? [] where reached.insert(other).inserted { next.append(other) }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return reached
    }

    /// The local graph of `center`: the settings applied (the open note is
    /// always kept), then only what lies within `depth` links of it.
    static func local(
        of center: String, depth: Int, data: LinkingService.GraphData, settings: GraphSettings,
        matching: Set<String>? = nil, groupMatches: [UUID: Set<String>] = [:]
    ) -> FilteredGraph {
        guard data.nodes.contains(where: { $0.id == center }) else { return FilteredGraph() }
        let whole = apply(data, settings: settings, matching: matching, groupMatches: groupMatches, alwaysKeep: [center])
        let near = neighbourhood(of: center, depth: depth, edges: whole.edges)
        var result = FilteredGraph()
        result.nodes = whole.nodes.filter { near.contains($0.id) }
        let ids = Set(result.nodes.map(\.id))
        result.edges = whole.edges.filter { ids.contains($0.sourceID) && ids.contains($0.targetID) }
        let degree = degrees(result.edges)
        result.degree = ids.reduce(into: [:]) { $0[$1] = degree[$1, default: 0] }
        result.colorIndex = whole.colorIndex.filter { ids.contains($0.key) }
        return result
    }
}
