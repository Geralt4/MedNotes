import CoreGraphics
import XCTest
@testable import MedNotes

/// The graph's zoom and pan maths: layout space (the unit square) to view
/// points and back.
final class GraphViewportTests: XCTestCase {
    /// A small deterministic generator, so a failure repeats.
    private struct Lcg {
        var state: UInt64 = 2024
        mutating func next(in range: ClosedRange<Double>) -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) / Double(1 << 53)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }

    private func randomViewport(_ rng: inout Lcg) -> GraphViewport {
        var viewport = GraphViewport()
        viewport.scale = CGFloat(rng.next(in: Double(GraphViewport.scales.lowerBound)...Double(GraphViewport.scales.upperBound)))
        viewport.offset = CGSize(width: rng.next(in: -300...300), height: rng.next(in: -300...300))
        return viewport
    }

    /// The formulas the canvas used before they moved here, written out again.
    private func referenceViewPoint(_ unit: CGPoint, _ size: CGSize, _ viewport: GraphViewport) -> CGPoint {
        let fit = min(size.width, size.height)
        let x = (unit.x - 0.5) * fit * viewport.scale + size.width / 2 + viewport.offset.width
        let y = (unit.y - 0.5) * fit * viewport.scale + size.height / 2 + viewport.offset.height
        return CGPoint(x: x, y: y)
    }

    private func referenceUnitPoint(_ point: CGPoint, _ size: CGSize, _ viewport: GraphViewport) -> CGPoint? {
        let span = min(size.width, size.height) * viewport.scale
        guard span > 0 else { return nil }
        return CGPoint(x: (point.x - size.width / 2 - viewport.offset.width) / span + 0.5,
                       y: (point.y - size.height / 2 - viewport.offset.height) / span + 0.5)
    }

    func testViewPointMatchesTheFormulaTheCanvasUsed() {
        var rng = Lcg()
        for _ in 0..<300 {
            let viewport = randomViewport(&rng)
            let size = CGSize(width: rng.next(in: 50...1200), height: rng.next(in: 50...900))
            let unit = CGPoint(x: rng.next(in: -0.2...1.2), y: rng.next(in: -0.2...1.2))
            XCTAssertEqual(viewport.viewPoint(for: unit, in: size), referenceViewPoint(unit, size, viewport))
        }
    }

    func testUnitPointMatchesTheFormulaHitTestingUsed() {
        var rng = Lcg()
        for _ in 0..<300 {
            let viewport = randomViewport(&rng)
            let size = CGSize(width: rng.next(in: 50...1200), height: rng.next(in: 50...900))
            let point = CGPoint(x: rng.next(in: -100...1300), y: rng.next(in: -100...1000))
            XCTAssertEqual(viewport.unitPoint(for: point, in: size), referenceUnitPoint(point, size, viewport))
            XCTAssertEqual(viewport.span(in: size), min(size.width, size.height) * viewport.scale)
        }
    }

    func testUnitPointUndoesViewPoint() throws {
        var rng = Lcg()
        for _ in 0..<100 {
            let viewport = randomViewport(&rng)
            let size = CGSize(width: rng.next(in: 50...1200), height: rng.next(in: 50...900))
            let unit = CGPoint(x: rng.next(in: 0...1), y: rng.next(in: 0...1))
            let back = try XCTUnwrap(viewport.unitPoint(for: viewport.viewPoint(for: unit, in: size), in: size))
            XCTAssertEqual(back.x, unit.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, unit.y, accuracy: 1e-9)
        }
    }

    func testTheCentreOfTheLayoutSitsInTheMiddleOfTheViewUntilItIsPanned() {
        let size = CGSize(width: 400, height: 300)
        var viewport = GraphViewport()
        XCTAssertEqual(viewport.viewPoint(for: CGPoint(x: 0.5, y: 0.5), in: size), CGPoint(x: 200, y: 150))
        viewport.offset = CGSize(width: 30, height: -10)
        XCTAssertEqual(viewport.viewPoint(for: CGPoint(x: 0.5, y: 0.5), in: size), CGPoint(x: 230, y: 140))
    }

    func testAViewWithNoSizeMapsNothing() {
        let viewport = GraphViewport()
        XCTAssertNil(viewport.unitPoint(for: CGPoint(x: 5, y: 5), in: .zero))
        XCTAssertNil(viewport.unitPoint(for: CGPoint(x: 5, y: 5), in: CGSize(width: 0, height: 300)))
    }
}
