import AppKit
import Combine
import SwiftUI
import XCTest
@testable import MedNotes

/// The graph's panel, canvas and the note's local graph, hosted off screen.
@MainActor
final class GraphViewTests: XCTestCase {
    private var roots: [DataRoot] = []
    private let host = OffscreenHost()
    private static let defaultsName = "MedNotesTests.GraphView"
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = TestDefaults.suite(Self.defaultsName)
    }

    override func tearDown() {
        host.tearDown()
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots = []
        TestDefaults.clear(Self.defaultsName)
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(dataRoot: root, defaults: defaults)
        addTeardownBlock { @MainActor in
            await session.lockNow(reason: "teardown")
        }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(session.initError)
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    private func node(_ id: String, _ kind: LinkingService.GraphNode.Kind = .note) -> LinkingService.GraphNode {
        .init(id: id, label: id, kind: kind)
    }

    private func pixels(in view: NSView, where test: (NSColor) -> Bool) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), test(c) { count += 1 }
            }
        }
        return count
    }

    // MARK: - The settings panel

    func testThePanelShowsTheFiltersAndKeepsTheOtherSectionsClosed() async throws {
        let session = try await makeSession()
        let view = host.host(GraphSettingsPanel().environmentObject(session), width: GraphSettingsPanel.width, height: 520)
        XCTAssertTrue(OffscreenHost.placeholders(under: view).contains("Search notes"))
        XCTAssertFalse(OffscreenHost.placeholders(under: view).contains("Group search"))
        XCTAssertTrue(OffscreenHost.hasInk(view))
    }

    func testGroupsCanBeAddedAndRemovedThroughTheSettings() async throws {
        let session = try await makeSession()
        session.graphSettings.groups = [GraphGroup(query: "tag:a", colorIndex: 0)]
        session.graphSettings.groups.append(GraphGroup(query: "tag:b", colorIndex: 1))
        XCTAssertEqual(session.graphSettings.groups.count, 2)
        session.graphSettings.groups.removeAll { $0.query == "tag:a" }
        XCTAssertEqual(session.graphSettings.groups.map(\.query), ["tag:b"])
    }

    // MARK: - Removing a group while typing in it

    private func pump(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The panel's "Group search" fields in reading order.
    private func groupFields(in root: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let field = view as? NSTextField, field.placeholderString == "Group search" { found.append(field) }
            pending.append(contentsOf: view.subviews.reversed())
        }
        return found
    }

    private func focus(_ field: NSTextField, in window: TypingWindow) -> Bool {
        window.makeKey()
        let focused = window.makeFirstResponder(field)
        pump(0.05)
        return focused && field.currentEditor() != nil
    }

    /// A key that reaches a group's text field just after the group was removed
    /// (typing while the minus button is pressed, a repeating key) must be
    /// dropped. The field read its group by position, past the end of the
    /// list, and the app trapped with "Index out of range".
    func testAKeyReachingARemovedGroupsFieldDoesNotCrash() async throws {
        let session = try await makeSession()
        session.graphSettings.groups = [GraphGroup(query: "", colorIndex: 0)]
        let window = try host.hostForTyping(
            GraphSettingsPanel(groupsOpen: true).environmentObject(session), width: GraphSettingsPanel.width, height: 700)
        let view = try XCTUnwrap(window.contentView)
        for round in 0..<3 {
            if session.graphSettings.groups.isEmpty {
                session.graphSettings.groups = [GraphGroup(query: "", colorIndex: 0)]
                pump(0.4)
            }
            let field = try XCTUnwrap(groupFields(in: view).first, "round \(round): the group's field")
            XCTAssertTrue(focus(field, in: window), "round \(round)")
            try window.type("a")
            XCTAssertEqual(session.graphSettings.groups.first?.query, "a",
                           "round \(round): text typed into a group is kept")
            let id = session.graphSettings.groups[0].id
            session.graphSettings.groups.removeAll { $0.id == id }
            try window.type("b")      // before SwiftUI has drawn the list again
            pump(0.3)
            XCTAssertTrue(session.graphSettings.groups.isEmpty, "round \(round): the group stays removed")
        }
    }

    /// The same key must not be written into the group that took the removed
    /// one's place in the list.
    func testTextTypedIntoARemovedGroupDoesNotLandInAnotherGroup() async throws {
        let session = try await makeSession()
        session.graphSettings.groups = [GraphGroup(query: "first", colorIndex: 0), GraphGroup(query: "second", colorIndex: 1)]
        let window = try host.hostForTyping(
            GraphSettingsPanel(groupsOpen: true).environmentObject(session), width: GraphSettingsPanel.width, height: 700)
        let view = try XCTUnwrap(window.contentView)
        for round in 0..<3 {
            if session.graphSettings.groups.count < 2 {
                session.graphSettings.groups = [GraphGroup(query: "first", colorIndex: 0), GraphGroup(query: "second", colorIndex: 1)]
                pump(0.4)
            }
            let fields = groupFields(in: view)
            XCTAssertEqual(fields.count, 2, "round \(round)")
            guard fields.count == 2 else { return }
            XCTAssertTrue(focus(fields[0], in: window), "round \(round)")
            try window.type("x")
            let removed = session.graphSettings.groups[0].id
            let kept = session.graphSettings.groups[1]
            session.graphSettings.groups.removeAll { $0.id == removed }
            try window.type("y")      // before SwiftUI has drawn the list again
            pump(0.3)
            XCTAssertEqual(session.graphSettings.groups.map(\.id), [kept.id], "round \(round)")
            XCTAssertEqual(session.graphSettings.groups.first?.query, kept.query,
                           "round \(round): the other group's text is unchanged")
        }
    }

    // MARK: - The canvas

    func testAGroupColourAndTheOpenNoteMarkAreDrawn() throws {
        let nodes = [node("n:a"), node("n:b"), node("n:c")]
        let edges = [LinkingService.GraphEdge(sourceID: "n:a", targetID: "n:b")]
        let graph = FilteredGraph(nodes: nodes, edges: edges, degree: ["n:a": 1, "n:b": 1, "n:c": 0],
                                  colorIndex: ["n:a": 0])   // palette 0 is red
        let layout = ["n:a": CGPoint(x: 0.25, y: 0.5), "n:b": CGPoint(x: 0.75, y: 0.5), "n:c": CGPoint(x: 0.5, y: 0.2)]
        func canvas(arrows: Bool) -> NSView {
            host.host(
                GraphCanvas(graph: graph, display: { var d = GraphCanvas.Display(); d.arrows = arrows; return d }(),
                            highlight: "n:b", viewport: .constant(GraphViewport()), layout: layout),
                width: 300, height: 300)
        }
        let plain = canvas(arrows: false)
        let red = pixels(in: plain) { $0.redComponent > 0.75 && $0.greenComponent < 0.45 && $0.blueComponent < 0.45 }
        XCTAssertGreaterThan(red, 20, "the group's colour should be drawn on its node")
        let withArrows = canvas(arrows: true)
        // An arrowhead adds ink along the link.
        let inkPlain = pixels(in: plain) { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 < 0.5 }
        let inkArrows = pixels(in: withArrows) { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 < 0.5 }
        XCTAssertGreaterThan(inkArrows, inkPlain, "arrowheads should add ink")
    }

    func testNodesWithMoreLinksAreDrawnBigger() throws {
        let nodes = [node("n:hub"), node("n:x"), node("n:y"), node("n:z"), node("n:w")]
        let edges = ["n:x", "n:y", "n:z", "n:w"].map { LinkingService.GraphEdge(sourceID: "n:hub", targetID: $0) }
        let layout = ["n:hub": CGPoint(x: 0.5, y: 0.5), "n:x": CGPoint(x: 0.1, y: 0.1), "n:y": CGPoint(x: 0.9, y: 0.1),
                      "n:z": CGPoint(x: 0.1, y: 0.9), "n:w": CGPoint(x: 0.9, y: 0.9)]
        func ink(sized: Bool) -> Int {
            var display = GraphCanvas.Display()
            display.sizeByDegree = sized
            let graph = FilteredGraph(nodes: nodes, edges: edges, degree: ["n:hub": 4, "n:x": 1, "n:y": 1, "n:z": 1, "n:w": 1])
            let view = host.host(GraphCanvas(graph: graph, display: display, viewport: .constant(GraphViewport()), layout: layout),
                                 width: 300, height: 300)
            return pixels(in: view) { $0.alphaComponent > 0 && abs($0.redComponent - $0.blueComponent) > 0.2 }
        }
        XCTAssertGreaterThan(ink(sized: true), ink(sized: false))
    }

    // MARK: - The graph module and the local graph

    func testTheGraphViewShowsTheCanvasAndTheNodeListNamesTheSameNodes() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        try await store.notes.save(Note(title: "Target", content: "x"))
        try await store.notes.save(Note(title: "Source", content: "see [[Target]]"))
        await session.loadGraph()
        session.graphPanelShown = true
        let view = host.host(GraphView().environmentObject(session), width: 900, height: 520)
        try await wait(until: { OffscreenHost.placeholders(under: view).contains("Search notes") })
        XCTAssertTrue(OffscreenHost.hasInk(view))
        XCTAssertEqual(session.filteredGraph.nodes.map(\.label).sorted(), ["Source", "Target"])

        session.graphPanelShown = false
        try await wait(until: { !OffscreenHost.placeholders(under: view).contains("Search notes") })
    }

    func testTheLocalGraphSectionIsReadOnlyWhenOpenAndFollowsTheDepth() async throws {
        let session = try await makeSession()
        let store = try XCTUnwrap(session.store)
        let a = Note(title: "A", content: "x")
        let b = Note(title: "B", content: "[[A]] and [[C]]")
        let c = Note(title: "C", content: "[[D]]")
        let d = Note(title: "D", content: "end")
        for note in [a, b, c, d] { try await store.notes.save(note) }

        // Closed: the graph is not read for it. Wait on an actual change,
        // inverted, rather than sleeping for a fixed time.
        let closed = host.host(NoteGraphSection(noteID: b.id).environmentObject(session), width: 280, height: 420)
        let changed = expectation(description: "a closed section read the graph")
        changed.isInverted = true
        let observation = session.$graphData.dropFirst().sink { _ in changed.fulfill() }
        await fulfillment(of: [changed], timeout: 0.5)
        observation.cancel()
        XCTAssertTrue(session.graphData.nodes.isEmpty, "a closed section reads nothing")
        _ = closed

        let open = host.host(NoteGraphSection(noteID: b.id, initiallyExpanded: true).environmentObject(session),
                             width: 280, height: 420)
        try await wait(until: { session.graphData.nodes.count == 4 })
        XCTAssertTrue(OffscreenHost.hasInk(open))
        let local = GraphFilter.local(of: "n:\(b.id.uuidString)", depth: 1, data: session.graphData, settings: GraphSettings())
        XCTAssertEqual(Set(local.nodes.map(\.label)), ["A", "B", "C"])
        let deeper = GraphFilter.local(of: "n:\(b.id.uuidString)", depth: 2, data: session.graphData, settings: GraphSettings())
        XCTAssertEqual(Set(deeper.nodes.map(\.label)), ["A", "B", "C", "D"])
    }

    private func wait(until condition: @escaping () -> Bool, timeout: TimeInterval = 10,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the condition was not met within \(timeout) seconds", file: file, line: line)
    }

    func testTheLayoutWorkStopsWhenItIsCancelled() {
        let nodes = (0..<400).map { node("n:\($0)") }
        let edges = (0..<399).map { LinkingService.GraphEdge(sourceID: "n:\($0)", targetID: "n:\($0 + 1)") }
        let start = Date()
        _ = GraphLayout.compute(nodes: nodes, edges: edges, cancelled: { true })
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "a cancelled layout should return at once")
    }
}
