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

        var index: [String: Int] = [:]
        index.reserveCapacity(n)
        for (i, node) in nodes.enumerated() { index[node.id] = i }
        var seen = Set<Int>()
        var springs: [(Int, Int)] = []
        for edge in edges {
            guard let a = index[edge.sourceID], let b = index[edge.targetID], a != b else { continue }
            let key = min(a, b) * n + max(a, b)
            if seen.insert(key).inserted { springs.append((a, b)) }
        }

        // The ideal distance k; the start square gives each node about that much room.
        let k = forces.linkDistance
        let side = (Double(n)).squareRoot() * 1.2 * k
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        var warm = false
        for (i, node) in nodes.enumerated() {
            if let p = initial?[node.id], p.x.isFinite, p.y.isFinite {
                x[i] = (Double(p.x) - 0.5) * side
                y[i] = (Double(p.y) - 0.5) * side
                warm = true
                continue
            }
            let h = hash(node.id)
            x[i] = Double(h & 0xFFFF) / 65535 * side - side / 2
            y[i] = Double((h >> 16) & 0xFFFF) / 65535 * side - side / 2
        }

        let steps = iterations ?? (warm ? 120 : (n > 1500 ? 100 : 300))
        let cell = 2.0 * k          // repulsion reaches two ideal distances
        let gravity = forces.center
        let repulsion = forces.repel * k * k
        let pull = forces.linkStrength / k
        var temperature = warm ? side / 24 : side / 8
        let cooling = temperature / Double(steps + 1)
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        var cellOf = [Int](repeating: 0, count: n)
        var order = [Int](repeating: 0, count: n)
        var start: [Int] = []

        // The inner loops run on buffer pointers: with thousands of nodes,
        // array bounds and uniqueness checks dominated a Debug build.
        x.withUnsafeMutableBufferPointer { x in
        y.withUnsafeMutableBufferPointer { y in
        dx.withUnsafeMutableBufferPointer { dx in
        dy.withUnsafeMutableBufferPointer { dy in
        cellOf.withUnsafeMutableBufferPointer { cellOf in
        order.withUnsafeMutableBufferPointer { order in
            for _ in 0..<steps {
                // A caller that no longer wants the result stops the work; what
                // is returned then is half-settled and is thrown away.
                if let cancelled, cancelled() { break }
                // Bucket nodes into grid cells (counting sort, no dictionaries).
                var minX = x[0], maxX = x[0], minY = y[0], maxY = y[0]
                for i in 0..<n {
                    dx[i] = 0; dy[i] = 0
                    minX = min(minX, x[i]); maxX = max(maxX, x[i])
                    minY = min(minY, y[i]); maxY = max(maxY, y[i])
                }
                let columns = min(512, Int((maxX - minX) / cell) + 1)
                let rows = min(512, Int((maxY - minY) / cell) + 1)
                let cells = columns * rows
                if start.count < cells + 1 { start = [Int](repeating: 0, count: cells + 1) }
                start.withUnsafeMutableBufferPointer { start in
                    for c in 0...cells { start[c] = 0 }
                    for i in 0..<n {
                        let cx = min(columns - 1, Int((x[i] - minX) / cell))
                        let cy = min(rows - 1, Int((y[i] - minY) / cell))
                        cellOf[i] = cy * columns + cx
                        start[cellOf[i] + 1] += 1
                    }
                    for c in 0..<cells { start[c + 1] += start[c] }
                    // Place each node in its cell's slots; `start` is restored
                    // by walking the cells back afterwards.
                    for i in 0..<n {
                        order[start[cellOf[i]]] = i
                        start[cellOf[i]] += 1
                    }
                    var c = cells
                    while c > 0 { start[c] = start[c - 1]; c -= 1 }
                    start[0] = 0

                    // Repulsion k²/d from nodes in this and the neighbouring cells.
                    let reach = cell * cell
                    for i in 0..<n {
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
                                    if d2 < 1e-9 {
                                        // Coincident: nudge apart along a fixed direction.
                                        ex = i < j ? -0.01 : 0.01; ey = 0.01; d2 = 2e-4
                                    }
                                    if d2 >= reach { continue }
                                    fx += ex / d2 * repulsion
                                    fy += ey / d2 * repulsion
                                }
                            }
                        }
                        dx[i] += fx
                        dy[i] += fy
                    }
                }

                // Springs d²/k along links, and a weak pull to the centre.
                for (a, b) in springs {
                    let ex = x[a] - x[b], ey = y[a] - y[b]
                    let d = (ex * ex + ey * ey).squareRoot()
                    if d < 1e-9 { continue }
                    // (d² / k) / d: the unit vector times d², scaled by the strength.
                    dx[a] -= ex * d * pull; dy[a] -= ey * d * pull
                    dx[b] += ex * d * pull; dy[b] += ey * d * pull
                }

                // Move, capped by the temperature, which cools each step.
                for i in 0..<n {
                    let fx = dx[i] - x[i] * gravity, fy = dy[i] - y[i] * gravity
                    let d = (fx * fx + fy * fy).squareRoot()
                    if d < 1e-9 { continue }
                    let step = min(d, temperature)
                    x[i] += fx / d * step
                    y[i] += fy / d * step
                }
                temperature = max(0.01, temperature - cooling)
            }
        }}}}}}

        // Into the unit square, centred, aspect kept.
        let minX = x.min()!, maxX = x.max()!, minY = y.min()!, maxY = y.max()!
        let span = max(maxX - minX, maxY - minY, 1e-9)
        let margin = 0.04
        let scale = (1 - 2 * margin) / span
        let offsetX = (1 - (maxX - minX) * scale) / 2
        let offsetY = (1 - (maxY - minY) * scale) / 2
        var positions: [String: CGPoint] = [:]
        positions.reserveCapacity(n)
        for (i, node) in nodes.enumerated() {
            positions[node.id] = CGPoint(x: offsetX + (x[i] - minX) * scale,
                                         y: offsetY + (y[i] - minY) * scale)
        }
        return positions
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
