import XCTest
@testable import MedNotes

final class GraphFilterTests: XCTestCase {
    private typealias Node = LinkingService.GraphNode
    private typealias Edge = LinkingService.GraphEdge

    private func note(_ id: String) -> Node { Node(id: "n:\(id)", label: id, kind: .note) }
    private func patient(_ id: String) -> Node { Node(id: "p:\(id)", label: id, kind: .patient) }
    private func event(_ id: String) -> Node { Node(id: "e:\(id)", label: id, kind: .event) }
    private func edge(_ a: String, _ b: String) -> Edge { Edge(sourceID: a, targetID: b) }

    /// A - B - C - D chain, a patient P tied to B and E, an event V on P, a loose note L.
    private var data: LinkingService.GraphData {
        LinkingService.GraphData(
            nodes: [note("A"), note("B"), note("C"), note("D"), note("E"), note("L"), patient("P"), event("V")],
            edges: [edge("n:A", "n:B"), edge("n:B", "n:C"), edge("n:C", "n:D"),
                    edge("n:B", "p:P"), edge("n:E", "p:P"), edge("e:V", "p:P")])
    }

    private func ids(_ graph: FilteredGraph) -> Set<String> { Set(graph.nodes.map(\.id)) }

    func testWithNoSettingsEverythingIsShown() {
        let graph = GraphFilter.apply(data, settings: GraphSettings())
        XCTAssertEqual(graph.nodes.count, 8)
        XCTAssertEqual(graph.edges.count, 6)
        XCTAssertEqual(graph.degree["n:B"], 3)
        XCTAssertEqual(graph.degree["n:L"], 0)
    }

    func testPatientsAndEventsCanBeHidden() {
        var settings = GraphSettings()
        settings.showPatients = false
        let noPatients = GraphFilter.apply(data, settings: settings)
        XCTAssertFalse(ids(noPatients).contains("p:P"))
        XCTAssertEqual(noPatients.edges.count, 3, "edges to a hidden node go with it")

        settings.showPatients = true
        settings.showEvents = false
        XCTAssertFalse(ids(GraphFilter.apply(data, settings: settings)).contains("e:V"))
    }

    func testOrphansCanBeHidden() {
        var settings = GraphSettings()
        settings.showOrphans = false
        let graph = GraphFilter.apply(data, settings: settings)
        XCTAssertFalse(ids(graph).contains("n:L"))
        XCTAssertTrue(ids(graph).contains("n:A"))
    }

    func testAQueryKeepsMatchingNotesAndOnlyThePatientsAndEventsTiedToThem() {
        let graph = GraphFilter.apply(data, settings: GraphSettings(), matching: ["n:A", "n:E"])
        XCTAssertEqual(ids(graph), ["n:A", "n:E", "p:P", "e:V"], "P through E, V through P")
        XCTAssertEqual(graph.edges.count, 2)

        let none = GraphFilter.apply(data, settings: GraphSettings(), matching: ["n:A"])
        XCTAssertEqual(ids(none), ["n:A"], "P is not tied to A")

        var settings = GraphSettings()
        settings.showPatients = false
        let hidden = GraphFilter.apply(data, settings: settings, matching: ["n:A", "n:E"])
        XCTAssertEqual(ids(hidden), ["n:A", "n:E"], "an event hangs on its patient, so it goes too")
    }

    func testTheFirstMatchingGroupColoursANote() {
        var settings = GraphSettings()
        let first = GraphGroup(query: "x", colorIndex: 2)
        let second = GraphGroup(query: "y", colorIndex: 5)
        settings.groups = [first, second]
        let graph = GraphFilter.apply(
            data, settings: settings,
            groupMatches: [first.id: ["n:A"], second.id: ["n:A", "n:B", "p:P"]])
        XCTAssertEqual(graph.colorIndex["n:A"], 2, "first group wins")
        XCTAssertEqual(graph.colorIndex["n:B"], 5)
        XCTAssertNil(graph.colorIndex["p:P"], "groups colour notes")
        XCTAssertNil(graph.colorIndex["n:C"])
    }

    func testNeighbourhoodByDepthReadsLinksBothWays() {
        let edges = data.edges
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:C", depth: 1, edges: edges), ["n:C", "n:B", "n:D"])
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:C", depth: 2, edges: edges), ["n:C", "n:B", "n:D", "n:A", "p:P"])
        XCTAssertEqual(
            GraphFilter.neighbourhood(of: "n:C", depth: 3, edges: edges),
            ["n:C", "n:B", "n:D", "n:A", "p:P", "n:E", "e:V"])
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:L", depth: 3, edges: edges), ["n:L"])
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:C", depth: 0, edges: edges), ["n:C"])
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:C", depth: 99, edges: edges).count, 7, "depth is capped, not unbounded")
    }

    func testCyclesDoNotLoop() {
        let ring = [edge("n:A", "n:B"), edge("n:B", "n:C"), edge("n:C", "n:A"), edge("n:A", "n:A")]
        XCTAssertEqual(GraphFilter.neighbourhood(of: "n:A", depth: 3, edges: ring), ["n:A", "n:B", "n:C"])
    }

    func testAPatientBridgesTwoNotesThatDoNotLinkEachOther() {
        let local = GraphFilter.local(of: "n:B", depth: 2, data: data, settings: GraphSettings())
        XCTAssertTrue(ids(local).contains("n:E"), "B - P - E")
        XCTAssertTrue(ids(local).contains("n:D"), "B - C - D")
    }

    func testTheLocalGraphKeepsTheOpenNoteWhateverTheFiltersSay() {
        var settings = GraphSettings()
        settings.showOrphans = false
        let local = GraphFilter.local(of: "n:L", depth: 2, data: data, settings: settings)
        XCTAssertEqual(ids(local), ["n:L"], "the open note stays even with no links")

        let filtered = GraphFilter.local(
            of: "n:B", depth: 1, data: data, settings: GraphSettings(), matching: ["n:A"])
        XCTAssertEqual(ids(filtered), ["n:B", "n:A", "p:P"],
                       "only matching notes besides the open one, and the patient tied to it")
    }

    func testTheLocalGraphOfAMissingNoteIsEmpty() {
        XCTAssertEqual(GraphFilter.local(of: "n:zzz", depth: 1, data: data, settings: GraphSettings()), FilteredGraph())
    }

    func testSettingsRoundTripAndDecodeLeniently() throws {
        var settings = GraphSettings()
        settings.query = "tag:cardio"
        settings.arrows = true
        settings.forces.repel = 2
        settings.groups = [GraphGroup(query: "patient:Nikos", colorIndex: 3)]
        settings.localDepth = 2
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(GraphSettings.self, from: data), settings)

        // Missing, wrongly typed and out-of-range values take their defaults or the nearest legal one.
        let odd = Data(#"{"query": 5, "arrows": "yes", "localDepth": 99, "forces": {"repel": 1000}, "groups": [{"query": "a", "colorIndex": 99}], "future": true}"#.utf8)
        let decoded = try JSONDecoder().decode(GraphSettings.self, from: odd)
        XCTAssertEqual(decoded.query, "")
        XCTAssertFalse(decoded.arrows)
        XCTAssertEqual(decoded.localDepth, 3)
        XCTAssertEqual(decoded.forces.repel, GraphLayout.Forces.repelRange.upperBound)
        XCTAssertEqual(decoded.groups.first?.colorIndex, GraphGroup.paletteSize - 1)
        XCTAssertEqual(try JSONDecoder().decode(GraphSettings.self, from: Data("{}".utf8)), GraphSettings())
    }
}
