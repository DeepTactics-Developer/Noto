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

    // Walks each edge of a hand-drawn-ish closed polygon with a small wobble perpendicular to it, the same
    // way a real stroke would trace one.
    private func polygonPoints(_ corners: [CGPoint], perEdge: Int = 15, wobbleAmp: CGFloat = 1.5) -> [CGPoint] {
        var points: [CGPoint] = []
        let n = corners.count
        for i in 0..<n {
            let a = corners[i], b = corners[(i + 1) % n]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            let nx = len > 0 ? -dy / len : 0, ny = len > 0 ? dx / len : 0
            for k in 0..<perEdge {
                let t = CGFloat(k) / CGFloat(perEdge)
                let w = wobble(points.count, wobbleAmp)
                points.append(CGPoint(x: a.x + dx * t + nx * w, y: a.y + dy * t + ny * w))
            }
        }
        points.append(corners[0])
        return points
    }

    func testTriangleIsRecognizedAsPolygon() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 45, y: 80)]
        guard case .polygon(let result)? = ShapeRecognizer.recognize(polygonPoints(corners)) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(result.count, 3)
    }

    func testRectangleIsRecognizedAndSquaredUp() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0), CGPoint(x: 120, y: 70), CGPoint(x: 0, y: 70)]
        guard case .polygon(let result)? = ShapeRecognizer.recognize(polygonPoints(corners)) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(result.count, 4)
        // The fitted rectangle's adjacent edges come out exactly perpendicular, even though the hand-drawn
        // input only wobbled close to it.
        let v1 = CGPoint(x: result[1].x - result[0].x, y: result[1].y - result[0].y)
        let v2 = CGPoint(x: result[2].x - result[1].x, y: result[2].y - result[1].y)
        XCTAssertEqual(v1.x * v2.x + v1.y * v2.y, 0, accuracy: 0.5)
    }

    func testTiltedRectangleIsStillRecognized() {
        let angle: CGFloat = 20 * .pi / 180
        let local = [CGPoint(x: -60, y: -35), CGPoint(x: 60, y: -35), CGPoint(x: 60, y: 35), CGPoint(x: -60, y: 35)]
        let corners = local.map {
            CGPoint(x: 100 + $0.x * cos(angle) - $0.y * sin(angle), y: 100 + $0.x * sin(angle) + $0.y * cos(angle))
        }
        guard case .polygon(let result)? = ShapeRecognizer.recognize(polygonPoints(corners)) else {
            return XCTFail("expected a polygon")
        }
        XCTAssertEqual(result.count, 4)
    }
}
