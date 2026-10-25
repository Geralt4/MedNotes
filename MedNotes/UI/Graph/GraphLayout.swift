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

    /// Positions in the unit square, aspect kept, with a small margin.
    static func compute(nodes: [Node], edges: [Edge], iterations: Int? = nil) -> [String: CGPoint] {
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

        // Ideal distance 1; the start square gives each node about that much room.
        let side = (Double(n)).squareRoot() * 1.2
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        for (i, node) in nodes.enumerated() {
            let h = hash(node.id)
            x[i] = Double(h & 0xFFFF) / 65535 * side - side / 2
            y[i] = Double((h >> 16) & 0xFFFF) / 65535 * side - side / 2
        }

        let steps = iterations ?? (n > 1500 ? 100 : 300)
        let cell = 2.0              // repulsion reaches two ideal distances
        let gravity = 0.03
        var temperature = side / 8
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
                                    fx += ex / d2
                                    fy += ey / d2
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
                    // (d² / k) / d with k = 1: the unit vector times d².
                    dx[a] -= ex * d; dy[a] -= ey * d
                    dx[b] += ex * d; dy[b] += ey * d
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
