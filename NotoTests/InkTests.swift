import XCTest
@testable import Noto

final class InkTests: XCTestCase {
    private func stroke(_ points: [(Float, Float)], width: Float = 2) -> InkStroke {
        InkStroke(kind: .pen, color: [0, 0, 0, 1], width: width,
                  points: points.enumerated().map { InkPoint(x: $1.0, y: $1.1, force: 0.5, time: Float($0) * 0.01) })
    }

    // Losing notes is the worst thing this app can do, so the file format gets a round-trip check.
    func testPageFileRoundTrip() throws {
        let original = InkStroke(kind: .highlighter, color: [0.1, 0.2, 0.3, 0.4], width: 7.5,
                                 points: [InkPoint(x: 1, y: 2, force: 0.5, time: 0), InkPoint(x: 3, y: 4, force: 0.7, time: 0.1)])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(InkPageFile(strokes: [original, stroke([(0, 0)])]))
        let decoded = try PropertyListDecoder().decode(InkPageFile.self, from: data)
        XCTAssertEqual(decoded.strokes.count, 2)
        let back = decoded.strokes[0]
        XCTAssertEqual(back.id, original.id)
        XCTAssertEqual(back.kind, .highlighter)
        XCTAssertEqual(back.color, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(back.width, 7.5)
        XCTAssertEqual(back.points, original.points)
        XCTAssertEqual(back.bounds, original.bounds)
    }

    func testMalformedStrokeIsRejected() throws {
        let broken: [String: Any] = [
            "version": 1,
            "strokes": [["id": UUID().uuidString, "kind": 0, "color": [0, 0, 0, 1], "width": 1, "pts": [1, 2, 3]]],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: broken, format: .binary, options: 0)
        XCTAssertThrowsError(try PropertyListDecoder().decode(InkPageFile.self, from: data))
    }

    func testEraserHitTest() {
        let horizontal = stroke([(0, 0), (100, 0)])
        XCTAssertTrue(InkGeometry.hit(horizontal, at: CGPoint(x: 50, y: 5), radius: 6))
        XCTAssertFalse(InkGeometry.hit(horizontal, at: CGPoint(x: 50, y: 20), radius: 6))
        XCTAssertFalse(InkGeometry.hit(horizontal, at: CGPoint(x: 150, y: 0), radius: 6))
        XCTAssertTrue(InkGeometry.hit(stroke([(10, 10)]), at: CGPoint(x: 12, y: 10), radius: 3)) // a dot
    }
}
