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
