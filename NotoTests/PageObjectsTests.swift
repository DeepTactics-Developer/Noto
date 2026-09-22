import XCTest
@testable import Noto

final class PageObjectsTests: XCTestCase {
    func testPageObjectsFileRoundTrip() throws {
        let text = TextBox(text: "메모", frame: CGRect(x: 10, y: 20, width: 200, height: 40), fontSize: 18)
        let image = ImageBox(filename: "image_test.jpg", frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        let file = PageObjectsFile(textBoxes: [text], images: [image])

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(file)
        let decoded = try PropertyListDecoder().decode(PageObjectsFile.self, from: data)

        XCTAssertEqual(decoded.textBoxes.first?.id, text.id)
        XCTAssertEqual(decoded.textBoxes.first?.text, "메모")
        XCTAssertEqual(decoded.textBoxes.first?.frame, text.frame)
        XCTAssertEqual(decoded.textBoxes.first?.fontSize, 18)
        XCTAssertEqual(decoded.images.first?.filename, "image_test.jpg")
        XCTAssertEqual(decoded.images.first?.frame, image.frame)
    }

    func testEmptyFileRoundTrip() throws {
        let data = try PropertyListEncoder().encode(PageObjectsFile())
        let decoded = try PropertyListDecoder().decode(PageObjectsFile.self, from: data)
        XCTAssertTrue(decoded.textBoxes.isEmpty)
        XCTAssertTrue(decoded.images.isEmpty)
    }
}
