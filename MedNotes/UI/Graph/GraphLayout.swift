import CoreGraphics
import Foundation

/// Where the graph's nodes go: a force-directed layout that pulls linked
/// records together and pushes the rest apart, so each patient reads as a
/// small cluster with its notes and events around it.
///
/// Pure and deterministic (start positions come from a stable hash of each
/// id), so a graph opens the same way every launch. The graph holds every
/// note, patient and event, thousands in a real practice, so repulsion only
/// acts between nodes in neighbouring cells of a grid rather than between
/// every pair, and the caller runs this off the main actor.
enum GraphLayout {
    typealias Node = LinkingService.GraphNode
    typealias Edge = LinkingService.GraphEdge

    /// The four sliders of the graph's Forces section. `standard` is what the
    /// layout always used; every field is a multiplier on it (the centre pull
    /// is the gravity itself), so the defaults give the same picture as before.
    struct Forces: Codable, Equatable, Sendable {
        /// Pull of every node towards the middle.
        var center = 0.03
        /// How hard unrelated nodes push each other apart.
        var repel = 1.0
        /// How hard a link pulls its two ends together.
        var linkStrength = 1.0
        /// How far linked nodes like to sit: the ideal distance.
        var linkDistance = 1.0

        static let standard = Forces()

        init(center: Double = 0.03, repel: Double = 1.0, linkStrength: Double = 1.0, linkDistance: Double = 1.0) {
            self.center = center
            self.repel = repel
            self.linkStrength = linkStrength
            self.linkDistance = linkDistance
        }

        /// A stored value that is missing or not a number takes its default.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            center = (try? c.decodeIfPresent(Double.self, forKey: .center)) ?? 0.03
            repel = (try? c.decodeIfPresent(Double.self, forKey: .repel)) ?? 1.0
            linkStrength = (try? c.decodeIfPresent(Double.self, forKey: .linkStrength)) ?? 1.0
            linkDistance = (try? c.decodeIfPresent(Double.self, forKey: .linkDistance)) ?? 1.0
        }
        static let centerRange = 0.0...0.2
        static let repelRange = 0.2...4.0
        static let linkStrengthRange = 0.2...4.0
        static let linkDistanceRange = 0.5...3.0

        /// Each value inside its range, a stored or typed value that is not a
        /// number replaced by the default.
        var clamped: Forces {
            func fit(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
                value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
            }
            return Forces(
                center: fit(center, Self.centerRange, Self.standard.center),
                repel: fit(repel, Self.repelRange, Self.standard.repel),
                linkStrength: fit(linkStrength, Self.linkStrengthRange, Self.standard.linkStrength),
                linkDistance: fit(linkDistance, Self.linkDistanceRange, Self.standard.linkDistance))
        }
    }

    /// Positions in the unit square, aspect kept, with a small margin.
    ///
    /// `initial` (unit-square positions from an earlier layout) starts the
    /// nodes it knows where they were, and cools sooner, so moving a slider
    /// or filtering nodes out keeps the picture recognisable. Without it the
    /// start is the stable hash, as ever. `cancelled` is asked once per step.
    static func compute(
        nodes: [Node], edges: [Edge], iterations: Int? = nil,
        forces: Forces = .standard, initial: [String: CGPoint]? = nil,
        cancelled: (@Sendable () -> Bool)? = nil
    ) -> [String: CGPoint] {
        let forces = forces.clamped
        let n = nodes.count
        guard n > 0 else { return [:] }
        guard n > 1 else { return [nodes[0].id: CGPoint(x: 0.5, y: 0.5)] }

        let springs = uniqueLinks(nodes: nodes, edges: edges)
        let physics = Physics(forces)
        // The start square gives each node about one ideal distance of room.
        let side = Double(n).squareRoot() * startRoom * physics.idealDistance
        let simulation = Simulation(count: n)
        let warm = simulation.place(nodes, from: initial, side: side)

        let steps = iterations ?? defaultSteps(nodeCount: n, warm: warm)
        // How far a node may move in one step; it shrinks every step.
        var temperature = warm ? side / warmTemperatureDivisor : side / freshTemperatureDivisor
        let cooling = temperature / Double(steps + 1)

        for _ in 0..<steps {
            // A caller that no longer wants the result stops the work; what
            // is returned then is half-settled and is thrown away.
            if let cancelled, cancelled() { break }
            simulation.pushApart(physics)
            simulation.pullLinked(springs, physics)
            simulation.move(physics, maxStep: temperature)
            temperature = max(minTemperature, temperature - cooling)
        }
        return simulation.unitSquarePositions(of: nodes)
    }

    // MARK: - Tuning

    /// Room each node gets in the start square, in ideal distances.
    private static let startRoom = 1.2
    /// A fresh layout takes this many steps, or `bigGraphSteps` from `bigGraphNodes` nodes on.
    private static let freshSteps = 300
    private static let bigGraphSteps = 100
    private static let bigGraphNodes = 1500
    /// A layout that starts from earlier positions needs fewer steps and a lower start temperature.
    private static let warmSteps = 120
    private static let freshTemperatureDivisor = 8.0
    private static let warmTemperatureDivisor = 24.0
    private static let minTemperature = 0.01
    /// The repulsion grid has at most this many cells along each side.
    private static let maxGridCellsPerSide = 512
    /// A distance below this is zero: no direction to push or pull in.
    private static let epsilon = 1e-9
    /// Two nodes on the same spot are nudged apart by this much, along a fixed direction.
    private static let nudge = 0.01
    private static let nudgeDistanceSquared = 2e-4
    /// Space kept free around the picture in the unit square.
    private static let margin = 0.04

    private static func defaultSteps(nodeCount: Int, warm: Bool) -> Int {
        warm ? warmSteps : (nodeCount > bigGraphNodes ? bigGraphSteps : freshSteps)
    }

    /// The ideal distance and the strengths derived from the forces.
    private struct Physics {
        /// How far linked nodes like to sit.
        let idealDistance: Double
        /// Grid cell size: repulsion reaches two ideal distances.
        let cell: Double
        let gravity: Double
        let repulsion: Double
        let pull: Double

        init(_ forces: Forces) {
            let k = forces.linkDistance
            idealDistance = k
            cell = 2.0 * k
            gravity = forces.center
            repulsion = forces.repel * k * k
            pull = forces.linkStrength / k
        }
    }

    /// Each pair of linked nodes once, as indices into `nodes`; self-links and
    /// links to nodes that are not there are dropped.
    private static func uniqueLinks(nodes: [Node], edges: [Edge]) -> [(Int, Int)] {
        let n = nodes.count
        var index: [String: Int] = [:]
        index.reserveCapacity(n)
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        var seen = Set<Int>()
        var links: [(Int, Int)] = []
        for edge in edges {
            guard let a = index[edge.sourceID], let b = index[edge.targetID], a != b else { continue }
            let key = min(a, b) * n + max(a, b)
            if seen.insert(key).inserted { links.append((a, b)) }
        }
        return links
    }

    // MARK: - One run

    /// The state of one layout run: where each node is, and how hard it is
    /// being pushed this step.
    ///
    /// Plain buffers rather than arrays: with thousands of nodes, array bounds
    /// and uniqueness checks dominated a Debug build. They are freed in `deinit`.
    private final class Simulation {
        let count: Int
        /// Position.
        let x: UnsafeMutableBufferPointer<Double>
        let y: UnsafeMutableBufferPointer<Double>
        /// Push this step.
        let dx: UnsafeMutableBufferPointer<Double>
        let dy: UnsafeMutableBufferPointer<Double>
        /// The grid cell of each node, and the nodes ordered by cell.
        let cellOf: UnsafeMutableBufferPointer<Int>
        let order: UnsafeMutableBufferPointer<Int>
        /// For each cell, where its nodes start in `order`. Grows when the picture spreads out.
        private var cellStart: [Int] = []

        init(count: Int) {
            self.count = count
            func buffer<T>(of zero: T) -> UnsafeMutableBufferPointer<T> {
                let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
                buffer.initialize(repeating: zero)
                return buffer
            }
            x = buffer(of: 0.0)
            y = buffer(of: 0.0)
            dx = buffer(of: 0.0)
            dy = buffer(of: 0.0)
            cellOf = buffer(of: 0)
            order = buffer(of: 0)
        }

        deinit {
            x.deallocate(); y.deallocate(); dx.deallocate(); dy.deallocate()
            cellOf.deallocate(); order.deallocate()
        }

        /// Puts every node where `initial` says, or, for a node it does not
        /// know, at a spot taken from the hash of its id. Returns whether any
        /// node started from `initial`.
        func place(_ nodes: [Node], from initial: [String: CGPoint]?, side: Double) -> Bool {
            var warm = false
            for (i, node) in nodes.enumerated() {
                if let p = initial?[node.id], p.x.isFinite, p.y.isFinite {
                    x[i] = (Double(p.x) - 0.5) * side
                    y[i] = (Double(p.y) - 0.5) * side
                    warm = true
                    continue
                }
                let h = GraphLayout.hash(node.id)
                x[i] = Double(h & 0xFFFF) / 65535 * side - side / 2
                y[i] = Double((h >> 16) & 0xFFFF) / 65535 * side - side / 2
            }
            return warm
        }

        /// Repulsion k²/d between nodes in the same or neighbouring grid cells.
        func pushApart(_ physics: Physics) {
            var minX = x[0], maxX = x[0], minY = y[0], maxY = y[0]
            for i in 0..<count {
                dx[i] = 0; dy[i] = 0
                minX = min(minX, x[i]); maxX = max(maxX, x[i])
                minY = min(minY, y[i]); maxY = max(maxY, y[i])
            }
            let cell = physics.cell
            let columns = min(maxGridCellsPerSide, Int((maxX - minX) / cell) + 1)
            let rows = min(maxGridCellsPerSide, Int((maxY - minY) / cell) + 1)
            let cells = columns * rows
            if cellStart.count < cells + 1 { cellStart = [Int](repeating: 0, count: cells + 1) }
            cellStart.withUnsafeMutableBufferPointer { start in
                let grid = Grid(minX: minX, minY: minY, cell: cell, columns: columns, rows: rows)
                sortIntoCells(grid, start: start)
                repel(grid, start: start, physics)
            }
        }

        /// The grid laid over the picture: cells of `cell` points, `columns` by `rows`.
        private struct Grid {
            let minX: Double
            let minY: Double
            let cell: Double
            let columns: Int
            let rows: Int
            var cells: Int { columns * rows }
        }

        /// Buckets the nodes into cells with a counting sort (no dictionaries).
        private func sortIntoCells(_ grid: Grid, start: UnsafeMutableBufferPointer<Int>) {
            let cells = grid.cells
            for c in 0...cells { start[c] = 0 }
            for i in 0..<count {
                let cx = min(grid.columns - 1, Int((x[i] - grid.minX) / grid.cell))
                let cy = min(grid.rows - 1, Int((y[i] - grid.minY) / grid.cell))
                cellOf[i] = cy * grid.columns + cx
                start[cellOf[i] + 1] += 1
            }
            for c in 0..<cells { start[c + 1] += start[c] }
            // Place each node in its cell's slots; `start` is restored
            // by walking the cells back afterwards.
            for i in 0..<count {
                order[start[cellOf[i]]] = i
                start[cellOf[i]] += 1
            }
            var c = cells
            while c > 0 { start[c] = start[c - 1]; c -= 1 }
            start[0] = 0
        }

        private func repel(_ grid: Grid, start: UnsafeMutableBufferPointer<Int>, _ physics: Physics) {
            let reach = grid.cell * grid.cell
            let columns = grid.columns, rows = grid.rows
            for i in 0..<count {
                let cx = cellOf[i] % columns, cy = cellOf[i] / columns
                let xi = x[i], yi = y[i]
                var fx = 0.0, fy = 0.0
                for ny in max(0, cy - 1)...min(rows - 1, cy + 1) {
                    for nx in max(0, cx - 1)...min(columns - 1, cx + 1) {
                        let c = ny * columns + nx
                        var slot = start[c]
                        let end = start[c + 1]
                        while slot < end {
                            let j = order[slot]
                            slot += 1
                            if j == i { continue }
                            var ex = xi - x[j], ey = yi - y[j]
                            var d2 = ex * ex + ey * ey
                            if d2 < epsilon {
                                // Coincident: nudge apart along a fixed direction.
                                ex = i < j ? -nudge : nudge; ey = nudge; d2 = nudgeDistanceSquared
                            }
                            if d2 >= reach { continue }
                            fx += ex / d2 * physics.repulsion
                            fy += ey / d2 * physics.repulsion
                        }
                    }
                }
                dx[i] += fx
                dy[i] += fy
            }
        }

        /// Springs d²/k along links.
        func pullLinked(_ links: [(Int, Int)], _ physics: Physics) {
            let pull = physics.pull
            for (a, b) in links {
                let ex = x[a] - x[b], ey = y[a] - y[b]
                let d = (ex * ex + ey * ey).squareRoot()
                if d < epsilon { continue }
                // (d² / k) / d: the unit vector times d², scaled by the strength.
                dx[a] -= ex * d * pull; dy[a] -= ey * d * pull
                dx[b] += ex * d * pull; dy[b] += ey * d * pull
            }
        }

        /// Moves every node along its push and a weak pull to the centre, by at most `maxStep`.
        func move(_ physics: Physics, maxStep: Double) {
            let gravity = physics.gravity
            for i in 0..<count {
                let fx = dx[i] - x[i] * gravity, fy = dy[i] - y[i] * gravity
                let d = (fx * fx + fy * fy).squareRoot()
                if d < epsilon { continue }
                let step = min(d, maxStep)
                x[i] += fx / d * step
                y[i] += fy / d * step
            }
        }

        /// Into the unit square, centred, aspect kept.
        func unitSquarePositions(of nodes: [Node]) -> [String: CGPoint] {
            let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
            let span = max(maxX - minX, maxY - minY, epsilon)
            let scale = (1 - 2 * margin) / span
            let offsetX = (1 - (maxX - minX) * scale) / 2
            let offsetY = (1 - (maxY - minY) * scale) / 2
            var positions: [String: CGPoint] = [:]
            positions.reserveCapacity(count)
            for (i, node) in nodes.enumerated() {
                positions[node.id] = CGPoint(x: offsetX + (x[i] - minX) * scale,
                                             y: offsetY + (y[i] - minY) * scale)
            }
            return positions
        }
    }

    /// The id nearest `point` within `radius`, all in the same space.
    static func nearest(to point: CGPoint, in positions: [String: CGPoint], within radius: CGFloat) -> String? {
        var best: (id: String, d2: CGFloat)?
        for (id, p) in positions {
            let ex = p.x - point.x, ey = p.y - point.y
            let d2 = ex * ex + ey * ey
            if d2 <= radius * radius, d2 < (best?.d2 ?? .infinity) { best = (id, d2) }
        }
        return best?.id
    }

    /// The ids linked to `id`, in either direction.
    static func neighbours(of id: String, edges: [Edge]) -> Set<String> {
        var result = Set<String>()
        for edge in edges {
            if edge.sourceID == id { result.insert(edge.targetID) }
            if edge.targetID == id { result.insert(edge.sourceID) }
        }
        result.remove(id)
        return result
    }

    /// FNV-1a: stable across launches, unlike `String.hashValue`, which is
    /// seeded per process and would move every node each time.
    static func hash(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
