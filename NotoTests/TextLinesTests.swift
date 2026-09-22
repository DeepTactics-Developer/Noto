import XCTest
@testable import Noto

final class TextLinesTests: XCTestCase {
    func testCharactersOnTheSameBaselineMergeIntoOneLine() {
        let chars = (0..<5).map { CGRect(x: CGFloat($0) * 8, y: 100, width: 7, height: 12) }
        let lines = TextLineLayout.lines(fromCharacterBounds: chars)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].minX, 0)
        XCTAssertEqual(lines[0].maxX, 4 * 8 + 7)
    }

    func testTwoLinesStayApart() {
        let line1 = (0..<4).map { CGRect(x: CGFloat($0) * 8, y: 100, width: 7, height: 12) }
        let line2 = (0..<4).map { CGRect(x: CGFloat($0) * 8, y: 80, width: 7, height: 12) } // 20pt below the first
        let lines = TextLineLayout.lines(fromCharacterBounds: line1 + line2)
        XCTAssertEqual(lines.count, 2)
    }

    func testEmptyGlyphsAreIgnored() {
        let chars = [CGRect(x: 0, y: 100, width: 0, height: 12), CGRect(x: 8, y: 100, width: 7, height: 12)]
        let lines = TextLineLayout.lines(fromCharacterBounds: chars)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].minX, 8)
    }

    func testNoCharactersGivesNoLines() {
        XCTAssertTrue(TextLineLayout.lines(fromCharacterBounds: []).isEmpty)
    }
}
