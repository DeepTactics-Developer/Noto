import XCTest
@testable import Noto

final class AIAssistantTests: XCTestCase {
    func testOutlineParsingExtractsTitleAndZeroBasedPage() {
        let text = "서론 — p.1\n방법론 — p.4\n결론 - p.10\n이 줄은 무시됨"
        let items = OutlineParsing.parse(text)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, "서론")
        XCTAssertEqual(items[0].page, 0)
        XCTAssertEqual(items[1].title, "방법론")
        XCTAssertEqual(items[1].page, 3)
        XCTAssertEqual(items[2].title, "결론")
        XCTAssertEqual(items[2].page, 9)
    }

    func testRelevantPagesRanksByKeywordOverlap() {
        let index = DocumentTextIndex(pages: [
            "고양이에 대한 내용입니다",
            "강아지와 고양이 둘 다 나옵니다 강아지",
            "날씨 이야기입니다",
        ])
        XCTAssertEqual(index.relevantPages(to: "강아지", limit: 2), [1])
    }

    func testRelevantPagesFallsBackToDocumentStartWhenNoKeywordMatches() {
        let index = DocumentTextIndex(pages: ["가", "나", "다", "라"])
        XCTAssertEqual(index.relevantPages(to: "없는단어", limit: 2), [0, 1])
    }

    private struct StubError: LocalizedError {
        var errorDescription: String?
    }

    // Matched against the real strings FoundationModels has been observed to produce on a device.
    func testFriendlyErrorMessageRecognizesKnownFailures() {
        XCTAssertTrue(AIErrorMessage.friendly(for: StubError(errorDescription: "Exceeded model context window size")).contains("너무 길어"))
        XCTAssertTrue(AIErrorMessage.friendly(for: StubError(errorDescription: "Detected content likely to be unsafe")).contains("처리할 수 없다"))
        let other = StubError(errorDescription: "Some other failure")
        XCTAssertEqual(AIErrorMessage.friendly(for: other), "Some other failure") // unrecognized: pass the raw message through
    }

    func testIsContextWindowErrorOnlyMatchesThatFailure() {
        XCTAssertTrue(AIErrorMessage.isContextWindowError(StubError(errorDescription: "Exceeded model context window size")))
        XCTAssertFalse(AIErrorMessage.isContextWindowError(StubError(errorDescription: "Detected content likely to be unsafe")))
    }
}
