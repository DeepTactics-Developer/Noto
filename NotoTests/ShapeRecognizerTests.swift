import XCTest
@testable import Noto

final class ShapeRecognizerTests: XCTestCase {
    // Smooth, repeatable "hand wobble" instead of random noise.
    private func wobble(_ i: Int, _ amplitude: CGFloat) -> CGFloat {
        sin(CGFloat(i) * 0.4) * amplitude
    }

    func testWobblyLineIsRecognizedAsLine() {
        let points = (0..<40).map { CGPoint(x: CGFloat($0) * 5, y: CGFloat($0) * 0.25 + wobble($0, 2)) }
        guard case .line(let from, let to)? = ShapeRecognizer.recognize(points) else {
            return XCTFail("expected a line")
        }
        XCTAssertEqual(from, points[0])
        XCTAssertEqual(to, points[39])
    }

    func testNearlyClosedWobblyCircleIsRecognizedAsCircle() {
        let points = (0..<60).map { i -> CGPoint in
            let t = CGFloat(i) / 60 * 2 * .pi * 0.98
            let r = 60 + wobble(i, 3)
            return CGPoint(x: 100 + r * cos(t), y: 100 + r * sin(t))
        }
        guard case .ellipse(let center, let rx, let ry, _)? = ShapeRecognizer.recognize(points) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertEqual(center.x, 100, accuracy: 6)
        XCTAssertEqual(center.y, 100, accuracy: 6)
        XCTAssertEqual(rx, 60, accuracy: 6)
        XCTAssertEqual(rx, ry, accuracy: 0.001) // close to round, so it becomes a true circle
    }

    func testFlatEllipseKeepsItsAxes() {
        let points = (0..<80).map { i -> CGPoint in
            let t = CGFloat(i) / 80 * 2 * .pi * 0.99
            return CGPoint(x: 200 + 100 * cos(t), y: 100 + 40 * sin(t))
        }
        guard case .ellipse(_, let rx, let ry, _)? = ShapeRecognizer.recognize(points) else {
            return XCTFail("expected an ellipse")
        }
        XCTAssertGreaterThan(max(rx, ry) / min(rx, ry), 2)
    }

    func testHalfCircleIsNotSnapped() {
        let points = (0..<40).map { i -> CGPoint in
            let t = CGFloat(i) / 40 * .pi
            return CGPoint(x: 100 + 60 * cos(t), y: 100 + 60 * sin(t))
        }
        XCTAssertNil(ShapeRecognizer.recognize(points))
    }

    func testWaveIsNotSnapped() {
        let points = (0..<60).map { CGPoint(x: CGFloat($0) * 5, y: 30 * sin(CGFloat($0) * 0.13)) }
        XCTAssertNil(ShapeRecognizer.recognize(points))
    }

    func testTinyScribbleIsNotSnapped() {
        let points = (0..<10).map { CGPoint(x: CGFloat($0 % 3), y: CGFloat($0 % 2)) }
        XCTAssertNil(ShapeRecognizer.recognize(points))
    }
}
