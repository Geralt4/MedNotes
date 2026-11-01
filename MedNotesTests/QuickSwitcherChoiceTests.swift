import XCTest
@testable import MedNotes

/// What a choice in the quick switcher (⌘O) opens. The view only turns a click
/// or Enter into a `SwitcherChoice`; which record it is, is decided here.
@MainActor
final class QuickSwitcherChoiceTests: XCTestCase {
    private static let defaultsName = "MedNotesTests.QuickSwitcherChoice"
    private var roots: [DataRoot] = []

    override func setUp() {
        TestDefaults.clear(Self.defaultsName)
    }

    override func tearDown() {
        TestDefaults.clear(Self.defaultsName)
        for root in roots { try? FileManager.default.removeItem(at: root.rootURL) }
        roots.removeAll()
    }

    private func makeSession() async throws -> AppSession {
        let root = try DataRoot.temporary()
        roots.append(root)
        let session = AppSession.testSession(
            dataRoot: root, defaults: TestDefaults.suite(Self.defaultsName))
        addTeardownBlock { @MainActor in await session.lockNow(reason: "teardown") }
        let deadline = Date().addingTimeInterval(20)
        while !session.isReady, session.initError == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(session.isReady, "session did not become ready")
        return session
    }

    private func patientHit(_ title: String) -> AppSession.SwitcherHit {
        AppSession.SwitcherHit(id: UUID(), kind: .patient, title: title, subtitle: "Patient")
    }

    func testAClickOpensTheResultTheRowShowedEvenAfterTheResultsAreReplaced() {
        let (alpha, beta) = (patientHit("Alpha"), patientHit("Beta"))
        let (gamma, delta) = (patientHit("Gamma"), patientHit("Delta"))
        // Alpha and Beta were drawn; Gamma and Delta have since replaced them.
        let current = [gamma, delta]
        XCTAssertEqual(AppSession.SwitcherChoice.clicked(position: 0, hit: alpha).resolve(in: current), alpha)
        XCTAssertEqual(AppSession.SwitcherChoice.clicked(position: 1, hit: beta).resolve(in: current), beta)
        // And not for a position that no longer exists at all.
        XCTAssertEqual(AppSession.SwitcherChoice.clicked(position: 5, hit: beta).resolve(in: []), beta)
    }

    func testEnterOpensTheHighlightedResultOfTheCurrentList() {
        let (gamma, delta) = (patientHit("Gamma"), patientHit("Delta"))
        XCTAssertEqual(AppSession.SwitcherChoice.highlighted(position: 1).resolve(in: [gamma, delta]), delta)
        XCTAssertNil(AppSession.SwitcherChoice.highlighted(position: 2).resolve(in: [gamma, delta]),
                     "past the end: Enter does nothing")
        XCTAssertNil(AppSession.SwitcherChoice.highlighted(position: -1).resolve(in: [gamma, delta]))
        XCTAssertNil(AppSession.SwitcherChoice.highlighted(position: 0).resolve(in: []))
    }

    /// The whole action below the view: the results are replaced after the row
    /// was drawn, then the row is clicked.
    func testChoosingAClickedRowRevealsThatRecordInTheSession() async throws {
        let session = try await makeSession()
        let (alpha, beta) = (patientHit("Alpha"), patientHit("Beta"))
        session.switcherResults = [alpha, beta]
        // A newer search lands before the click is handled.
        session.switcherResults = [patientHit("Gamma"), patientHit("Delta")]

        await session.choose(.clicked(position: 0, hit: alpha))?.value

        XCTAssertEqual(session.selectedPatientId, alpha.id)
        XCTAssertEqual(session.selectedModule, .patients)
    }

    /// Enter is decided when it is pressed, from the results shown then: a
    /// newer list published before the opening task runs must not change it.
    func testEnterOpensTheResultHighlightedWhenItWasPressedEvenIfTheResultsChangeBeforeTheOpenRuns() async throws {
        let session = try await makeSession()
        let (alpha, gamma) = (patientHit("Alpha"), patientHit("Gamma"))
        session.switcherResults = [alpha, patientHit("Beta")]

        let task = session.choose(.highlighted(position: 0))
        session.switcherResults = [gamma, patientHit("Delta")]   // lands before the task runs
        await task?.value

        XCTAssertEqual(session.selectedPatientId, alpha.id)
    }

    /// A click still holds its result after a lock emptied the list; it must
    /// open nothing, and must not reset the filters under the curtain (a
    /// reveal sets them before it checks the session).
    func testAChoiceMadeAfterTheSessionLockedOpensNothing() async throws {
        let session = try await makeSession()
        let todo = AppSession.SwitcherHit(id: UUID(), kind: .todo, title: "Chase labs", subtitle: "Todo")
        await session.lockNow(reason: "idle")
        session.todoFilter = .completed

        let task = session.choose(.clicked(position: 0, hit: todo))

        XCTAssertNil(task)
        XCTAssertEqual(session.todoFilter, .completed, "a reveal would have reset the filter")
        XCTAssertNil(session.selectedTodoId)
    }

    func testChoosingAHighlightPastTheEndOpensNothing() async throws {
        let session = try await makeSession()
        session.switcherResults = [patientHit("Gamma")]
        let task = session.choose(.highlighted(position: 3))
        XCTAssertNil(task, "nothing to open past the end")
        await task?.value
        XCTAssertNil(session.selectedPatientId)
    }
}
