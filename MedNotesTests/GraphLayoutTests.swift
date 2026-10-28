import CoreGraphics
import XCTest
@testable import MedNotes

/// The graph's force-directed layout: stable, bounded, clustering, and fast
/// enough for a real practice's every note, patient and event.
final class GraphLayoutTests: XCTestCase {
    private typealias Node = LinkingService.GraphNode
    private typealias Edge = LinkingService.GraphEdge

    /// `patients` hubs, each linked to `perPatient` notes, plus loose notes.
    private func clusters(patients: Int, perPatient: Int, loose: Int = 0) -> ([Node], [Edge]) {
        var nodes: [Node] = []
        var edges: [Edge] = []
        for p in 0..<patients {
            let hub = "p:\(p)"
            nodes.append(Node(id: hub, label: "Patient \(p)", kind: .patient))
            for k in 0..<perPatient {
                let note = "n:\(p)-\(k)"
                nodes.append(Node(id: note, label: "Note", kind: .note))
                edges.append(Edge(sourceID: note, targetID: hub))
            }
        }
        for l in 0..<loose { nodes.append(Node(id: "n:loose-\(l)", label: "Loose", kind: .note)) }
        return (nodes, edges)
    }

    private func distance(_ a: CGPoint?, _ b: CGPoint?) -> CGFloat {
        guard let a, let b else { return .infinity }
        return hypot(a.x - b.x, a.y - b.y)
    }

    func testSameInputGivesTheSameLayout() {
        let (nodes, edges) = clusters(patients: 5, perPatient: 4, loose: 6)
        XCTAssertEqual(GraphLayout.compute(nodes: nodes, edges: edges),
                       GraphLayout.compute(nodes: nodes, edges: edges))
    }

    /// The layout as it was before the force sliders, computed with that
    /// version of the algorithm: the default forces must give exactly this.
    func testDefaultForcesGiveTheLayoutThatWasThereBefore() {
        let ids = (0..<12).map { "n:\($0)" }
        let nodes = ids.map { Node(id: $0, label: $0, kind: .note) }
        var edges = (0..<11).map { Edge(sourceID: ids[$0], targetID: ids[$0 + 1]) }
        edges.append(Edge(sourceID: ids[0], targetID: ids[5]))
        edges.append(Edge(sourceID: ids[3], targetID: ids[9]))
        let expected: [(Double, Double)] = [
            (0.52598634517795384, 0.67438255321906992), (0.50464272111216957, 0.9530954039937074),
            (0.75299913677266428, 0.92579963995865455), (0.71250063335642877, 0.63909644546616584),
            (0.95999999999999996, 0.50647762083562919), (0.73634284553310625, 0.39989518709366312),
            (0.67982047594647033, 0.13460862139605032), (0.43072315650770709, 0.046904596006292654),
            (0.27149506678610158, 0.24790304280089634), (0.34655966770569319, 0.51114868140071923),
            (0.084525680296254985, 0.64926772107916975), (0.03999999999999998, 0.87226908436383321)
        ]
        for forces in [GraphLayout.Forces.standard, GraphLayout.Forces()] {
            let positions = GraphLayout.compute(nodes: nodes, edges: edges, forces: forces)
            for (i, id) in ids.enumerated() {
                let p = positions[id]
                XCTAssertEqual(Double(p?.x ?? .nan), expected[i].0, accuracy: 1e-12, id)
                XCTAssertEqual(Double(p?.y ?? .nan), expected[i].1, accuracy: 1e-12, id)
            }
        }
    }

    private func meanLinkedDistance(_ positions: [String: CGPoint], _ edges: [Edge]) -> CGFloat {
        let all = edges.map { distance(positions[$0.sourceID], positions[$0.targetID]) }
        return all.reduce(0, +) / CGFloat(all.count)
    }

    private func meanPairDistance(_ positions: [String: CGPoint]) -> CGFloat {
        let points = Array(positions.values)
        var total: CGFloat = 0, count: CGFloat = 0
        for i in points.indices { for j in points.indices where j > i { total += distance(points[i], points[j]); count += 1 } }
        return total / count
    }

    func testTheForcesChangeTheShapeInTheWayTheirNamesSay() {
        let (nodes, edges) = clusters(patients: 4, perPatient: 5, loose: 6)
        let base = GraphLayout.compute(nodes: nodes, edges: edges)

        var strongCentre = GraphLayout.Forces()
        strongCentre.center = 0.2
        let tight = GraphLayout.compute(nodes: nodes, edges: edges, forces: strongCentre)
        var noCentre = GraphLayout.Forces()
        noCentre.center = 0
        let loose = GraphLayout.compute(nodes: nodes, edges: edges, forces: noCentre)
        // The unit square is rescaled to the span, so compare the loose nodes' spread
        // relative to the linked ones: a stronger centre pulls the loose ones in.
        func spread(_ p: [String: CGPoint]) -> CGFloat { meanPairDistance(p) / max(meanLinkedDistance(p, edges), 1e-9) }
        XCTAssertLessThan(spread(tight), spread(loose))

        var weakLinks = GraphLayout.Forces()
        weakLinks.linkStrength = 0.2
        var strongLinks = GraphLayout.Forces()
        strongLinks.linkStrength = 4
        func cohesion(_ forces: GraphLayout.Forces) -> CGFloat {
            let p = GraphLayout.compute(nodes: nodes, edges: edges, forces: forces)
            return meanLinkedDistance(p, edges) / meanPairDistance(p)
        }
        XCTAssertLessThan(cohesion(strongLinks), cohesion(weakLinks),
                          "stronger links hold linked nodes closer, relative to everything else")
        XCTAssertNotEqual(base, tight)
    }

    func testForcesAreClampedAndNonNumbersFallBack() {
        var wild = GraphLayout.Forces(center: .nan, repel: 1_000, linkStrength: -5, linkDistance: .infinity)
        wild = wild.clamped
        XCTAssertEqual(wild.center, GraphLayout.Forces.standard.center)
        XCTAssertEqual(wild.repel, GraphLayout.Forces.repelRange.upperBound)
        XCTAssertEqual(wild.linkStrength, GraphLayout.Forces.linkStrengthRange.lowerBound)
        XCTAssertEqual(wild.linkDistance, GraphLayout.Forces.standard.linkDistance)
        let (nodes, edges) = clusters(patients: 3, perPatient: 3)
        let positions = GraphLayout.compute(nodes: nodes, edges: edges, forces: wild)
        for p in positions.values { XCTAssertTrue(p.x.isFinite && p.y.isFinite) }
    }

    func testAWarmStartKeepsNodesNearWhereTheyWere() {
        let (nodes, edges) = clusters(patients: 5, perPatient: 4, loose: 5)
        let first = GraphLayout.compute(nodes: nodes, edges: edges)
        var changed = GraphLayout.Forces()
        changed.repel = 1.5
        let warm = GraphLayout.compute(nodes: nodes, edges: edges, forces: changed, initial: first)
        let cold = GraphLayout.compute(nodes: nodes, edges: edges, forces: changed)
        func drift(_ a: [String: CGPoint]) -> CGFloat {
            nodes.map { distance(a[$0.id], first[$0.id]) }.reduce(0, +) / CGFloat(nodes.count)
        }
        XCTAssertLessThan(drift(warm), drift(cold), "warm \(drift(warm)), cold \(drift(cold))")
        // Deterministic, and nodes the earlier layout did not know still get a place.
        XCTAssertEqual(warm, GraphLayout.compute(nodes: nodes, edges: edges, forces: changed, initial: first))
        let fewer = Array(nodes.dropLast(3))
        let partial = GraphLayout.compute(nodes: nodes, edges: edges, initial: GraphLayout.compute(nodes: fewer, edges: []))
        XCTAssertEqual(partial.count, nodes.count)
        for p in partial.values { XCTAssertTrue(p.x.isFinite && p.y.isFinite) }
    }

    func testPositionsAreFiniteAndInsideTheUnitSquare() {
        let (nodes, edges) = clusters(patients: 8, perPatient: 5, loose: 20)
        let positions = GraphLayout.compute(nodes: nodes, edges: edges)
        XCTAssertEqual(positions.count, nodes.count)
        for p in positions.values {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
            XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y), "\(p)")
        }
    }

    func testLinkedNodesEndUpCloserThanStrangers() {
        let (nodes, edges) = clusters(patients: 6, perPatient: 5)
        let positions = GraphLayout.compute(nodes: nodes, edges: edges)
        let linked = edges.map { distance(positions[$0.sourceID], positions[$0.targetID]) }
        // A note against another patient's hub.
        let strangers = (0..<6).map { p in distance(positions["n:\(p)-0"], positions["p:\((p + 3) % 6)"]) }
        let mean: ([CGFloat]) -> CGFloat = { $0.reduce(0, +) / CGFloat($0.count) }
        XCTAssertLessThan(mean(linked) * 2, mean(strangers), "clusters did not form")
    }

    func testEdgeCases() {
        XCTAssertTrue(GraphLayout.compute(nodes: [], edges: []).isEmpty)
        let one = Node(id: "p:only", label: "Only", kind: .patient)
        XCTAssertEqual(GraphLayout.compute(nodes: [one], edges: []), ["p:only": CGPoint(x: 0.5, y: 0.5)])
        // Edges to unknown ids and self-links are ignored, not crashed on.
        let positions = GraphLayout.compute(nodes: [one, Node(id: "n:a", label: "A", kind: .note)],
                                            edges: [Edge(sourceID: "n:a", targetID: "p:gone"),
                                                    Edge(sourceID: "n:a", targetID: "n:a")])
        XCTAssertEqual(positions.count, 2)
    }

    func testNearestAndNeighbours() {
        let positions = ["a": CGPoint(x: 0, y: 0), "b": CGPoint(x: 10, y: 0)]
        XCTAssertEqual(GraphLayout.nearest(to: CGPoint(x: 8, y: 1), in: positions, within: 5), "b")
        XCTAssertNil(GraphLayout.nearest(to: CGPoint(x: 5, y: 20), in: positions, within: 5))
        let edges = [Edge(sourceID: "a", targetID: "b"), Edge(sourceID: "c", targetID: "a")]
        XCTAssertEqual(GraphLayout.neighbours(of: "a", edges: edges), ["b", "c"])
    }

    /// Zooming about a point keeps the graph position under it in place.
    @MainActor
    func testZoomKeepsTheAnchorStill() {
        var viewport = GraphViewport(scale: 1.2, offset: CGSize(width: 30, height: -10))
        let anchor = CGSize(width: 120, height: 80)
        let before = CGPoint(x: (anchor.width - viewport.offset.width) / viewport.scale,
                             y: (anchor.height - viewport.offset.height) / viewport.scale)
        viewport.zoom(by: 1.5, about: anchor)
        XCTAssertEqual(viewport.scale, 1.8, accuracy: 1e-9)
        XCTAssertEqual((anchor.width - viewport.offset.width) / viewport.scale, before.x, accuracy: 1e-9)
        XCTAssertEqual((anchor.height - viewport.offset.height) / viewport.scale, before.y, accuracy: 1e-9)
        viewport.zoom(by: 100)
        XCTAssertEqual(viewport.scale, GraphViewport.scales.upperBound, "zoom is clamped")
    }

    /// About a real practice: 400 patients with notes and events, plus loose notes.
    func testLargeGraphLaysOutQuickly() {
        let (nodes, edges) = clusters(patients: 400, perPatient: 5, loose: 600)
        XCTAssertGreaterThanOrEqual(nodes.count, 3000)
        let start = Date()
        let positions = GraphLayout.compute(nodes: nodes, edges: edges)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(positions.count, nodes.count)
        XCTAssertLessThan(elapsed, 2, "laying out \(nodes.count) nodes took \(elapsed) s")
    }
}
