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
}
