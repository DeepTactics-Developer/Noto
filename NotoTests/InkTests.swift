import XCTest
@testable import Noto

final class InkTests: XCTestCase {
    private func stroke(_ points: [(Float, Float)], width: Float = 2) -> InkStroke {
        InkStroke(kind: .pen, color: [0, 0, 0, 1], width: width,
                  points: points.enumerated().map { InkPoint(x: $1.0, y: $1.1, force: 0.5, time: Float($0) * 0.01) })
    }

    // Losing notes is the worst thing this app can do, so the file format gets a round-trip check.
    func testPageFileRoundTrip() throws {
        let original = InkStroke(kind: .highlighter, color: [0.1, 0.2, 0.3, 0.4], width: 7.5, pressure: 0.6,
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
        XCTAssertEqual(back.pressure, 0.6)
        XCTAssertEqual(back.points, original.points)
        XCTAssertEqual(back.bounds, original.bounds)
    }

    // Files written before pressure existed have no such key and must still open.
    func testFileWithoutPressureKeyStillOpens() throws {
        let old: [String: Any] = [
            "version": 1,
            "strokes": [["id": UUID().uuidString, "kind": 0, "color": [0, 0, 0, 1], "width": 2, "pts": [1, 2, 0.5, 0, 3, 4, 0.5, 0.25]]], // values a Float holds exactly, as the app's own files do
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        let decoded = try PropertyListDecoder().decode(InkPageFile.self, from: data)
        XCTAssertEqual(decoded.strokes[0].pressure, 0)
        XCTAssertEqual(decoded.strokes[0].points.count, 2)
    }

    func testPartialEraseSplitsAStrokeInTwo() throws {
        let line = stroke([(0, 0), (100, 0)]) // width 2, so a radius 5 eraser removes 44...56
        let pieces = try XCTUnwrap(InkGeometry.cut(line, around: CGPoint(x: 50, y: 0), radius: 5))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(try XCTUnwrap(pieces[0].points.last).x, 44, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(pieces[1].points.first).x, 56, accuracy: 0.01)
        XCTAssertNotEqual(pieces[0].id, line.id)
    }

    func testPartialEraseIgnoresAStrokeOutOfReach() {
        XCTAssertNil(InkGeometry.cut(stroke([(0, 0), (100, 0)]), around: CGPoint(x: 50, y: 30), radius: 5))
    }

    func testPartialEraseCanRemoveAWholeShortStroke() throws {
        let pieces = try XCTUnwrap(InkGeometry.cut(stroke([(0, 0), (4, 0)]), around: CGPoint(x: 2, y: 0), radius: 10))
        XCTAssertTrue(pieces.isEmpty)
    }

    func testPartialEraseKeepsPressureAndCutsBetweenFarApartSamples() throws {
        let sparse = InkStroke(kind: .pen, color: [0, 0, 0, 1], width: 2, pressure: 0.7,
                               points: [InkPoint(x: 0, y: 0, force: 0.2, time: 0), InkPoint(x: 200, y: 0, force: 0.8, time: 1)])
        let pieces = try XCTUnwrap(InkGeometry.cut(sparse, around: CGPoint(x: 100, y: 0), radius: 5)) // no sample near the eraser
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].pressure, 0.7)
    }

    // Normalized force in ordinary writing is roughly 0.05...0.4 of the pencil's maximum; the width has to
    // visibly follow that whole range, or the pressure setting looks like it does nothing.
    func testWidthFollowsTheForceOfOrdinaryWriting() {
        let light = InkGeometry.widthFactor(force: 0.05, pressure: 0.6)
        let medium = InkGeometry.widthFactor(force: 0.16, pressure: 0.6)
        let firm = InkGeometry.widthFactor(force: 0.4, pressure: 0.6)
        XCTAssertLessThan(light, medium)
        XCTAssertLessThan(medium, firm)
        XCTAssertGreaterThan(firm / light, 2) // at least twice as wide when pressing firmly
        XCTAssertEqual(medium, 1, accuracy: 0.15) // a medium touch stays near the base width
        XCTAssertEqual(InkGeometry.widthFactor(force: 0.4, pressure: 0), 1 + 0 * 2 * (1 - 0.4)) // no sensitivity: unchanged
        XCTAssertGreaterThanOrEqual(InkGeometry.widthFactor(force: 0, pressure: 1), 0.25) // never vanishes
    }

    func testNoPressureGivesOneRun() {
        let points = (0..<20).map { InkPoint(x: Float($0), y: 0, force: Float($0) / 20, time: 0) }
        XCTAssertEqual(InkGeometry.runs(of: points, width: 4, pressure: 0).count, 1)
    }

    func testRisingPressureGivesWideningRunsThatShareTheirJoints() {
        let points = (0..<60).map { InkPoint(x: Float($0) * 2, y: 0, force: 0.1 + Float($0) / 60 * 0.8, time: Float($0) * 0.01) }
        let runs = InkGeometry.runs(of: points, width: 4, pressure: 0.8)
        XCTAssertGreaterThan(runs.count, 1)
        XCTAssertEqual(runs.map(\.width), runs.map(\.width).sorted()) // wider as the pen presses harder
        for (a, b) in zip(runs, runs.dropFirst()) { XCTAssertEqual(a.points.last, b.points.first) }
        XCTAssertEqual(runs.first?.points.first, points.first)
        XCTAssertEqual(runs.last?.points.last, points.last)
    }

    func testLassoPicksStrokesMostlyInsideTheLoop() {
        let loop = CGMutablePath()
        loop.addRect(CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(InkGeometry.isSelected(stroke([(10, 10), (20, 20), (30, 30)]), by: loop))
        XCTAssertFalse(InkGeometry.isSelected(stroke([(100, 100), (120, 120)]), by: loop))
        XCTAssertFalse(InkGeometry.isSelected(stroke([(40, 40), (60, 60), (80, 80)]), by: loop)) // one third inside
    }

    func testMovedStrokeIsANewStrokeAtTheNewPlace() {
        let original = stroke([(0, 0), (10, 5)])
        let moved = original.moved(by: CGSize(width: 3, height: -2))
        XCTAssertNotEqual(moved.id, original.id)
        XCTAssertEqual(moved.points.map(\.x), [3, 13])
        XCTAssertEqual(moved.points.map(\.y), [-2, 3])
    }

    func testTransformedScalesPointsAndWidthAroundTheOrigin() {
        let original = stroke([(0, 0), (10, 0)], width: 2)
        let scaled = original.transformed(by: CGAffineTransform(scaleX: 2, y: 2))
        XCTAssertNotEqual(scaled.id, original.id)
        XCTAssertEqual(scaled.points.map(\.x), [0, 20])
        XCTAssertEqual(scaled.width, 4)
    }

    func testTransformedRotationLeavesWidthUnchanged() {
        let original = stroke([(1, 0)], width: 3)
        let rotated = original.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
        XCTAssertEqual(rotated.points[0].x, 0, accuracy: 0.0001)
        XCTAssertEqual(rotated.points[0].y, 1, accuracy: 0.0001)
        XCTAssertEqual(rotated.width, 3)
    }

    func testClipboardPasteRecentersAroundTheGivenPointWithFreshIDs() {
        let original = stroke([(0, 0), (10, 10)])
        InkClipboard.copy([original])
        let pasted = InkClipboard.pasteStrokes(centeredAt: CGPoint(x: 100, y: 100))
        XCTAssertEqual(pasted.count, 1)
        XCTAssertNotEqual(pasted[0].id, original.id)
        XCTAssertEqual(pasted[0].bounds.midX, 100, accuracy: 0.01)
        XCTAssertEqual(pasted[0].bounds.midY, 100, accuracy: 0.01)
    }

    func testClipboardIsEmptyUntilSomethingIsCopied() {
        InkClipboard.copy([])
        XCTAssertTrue(InkClipboard.isEmpty)
        XCTAssertTrue(InkClipboard.pasteStrokes(centeredAt: .zero).isEmpty)
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
