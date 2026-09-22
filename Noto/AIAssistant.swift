import Foundation
import PDFKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// Answers questions / summarizes / outlines the open document using Apple's on-device model (FoundationModels,
// iOS 26+) — no external API, no network, no per-use cost. Below iOS 26, or when Apple Intelligence isn't
// enabled/ready on the device, this reports why instead, and AIAssistantView shows that in place of the chat.
enum AIAvailability {
    case available
    case unavailable(reason: String)

    static var current: AIAvailability {
        guard #available(iOS 26.0, *) else { return .unavailable(reason: "이 기능은 iOS 26 이상이 필요합니다.") }
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "이 기기는 온디바이스 AI를 지원하지 않습니다.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "설정에서 Apple Intelligence를 켜주세요.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "AI 모델을 준비하는 중입니다. 잠시 후 다시 시도해주세요.")
        case .unavailable:
            return .unavailable(reason: "지금은 AI 기능을 사용할 수 없습니다.")
        }
        #else
        return .unavailable(reason: "이 빌드에서는 AI 기능을 사용할 수 없습니다.")
        #endif
    }
}

// Plain text per page, built once per document open. PDFKit already extracts this (`page.string`) — no need to
// redo the character-bounds work used for the highlighter's text-snap.
struct DocumentTextIndex {
    let pages: [String] // page i's text at index i; "" if none/unreadable

    init(pages: [String]) {
        self.pages = pages
    }

    init(document: PDFDocument) {
        pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    // Naive keyword-overlap ranking: no embeddings, no extra frameworks — good enough to point the on-device
    // model's limited context window at the pages actually relevant to the question.
    func relevantPages(to query: String, limit: Int = 6) -> [Int] {
        let terms = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        guard !terms.isEmpty else { return Array(pages.indices.prefix(limit)) }
        let scored = pages.indices.map { index -> (Int, Int) in
            let text = pages[index].lowercased()
            let score = terms.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            return (index, score)
        }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        if hits.isEmpty { return Array(pages.indices.prefix(limit)) } // fall back to the start of the document
        return hits.prefix(limit).map(\.0).sorted()
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum AIAssistant {
    static func answer(question: String, index: DocumentTextIndex) async throws -> String {
        let pages = index.relevantPages(to: question)
        let excerpt = pages.map { "[p.\($0 + 1)]\n\(index.pages[$0].prefix(1200))" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            너는 사용자가 보고 있는 PDF 문서 내용만 근거로 답하는 도우미야. 아래는 문서에서 발췌한 페이지들이다.
            답변은 한국어로 간결하게 하고, 근거로 쓴 페이지 번호를 문장 끝에 (p.N) 형식으로 표시해.
            발췌에 없는 내용은 추측하지 말고 모른다고 말해.
            """)
        let response = try await session.respond(to: "\(excerpt)\n\n질문: \(question)")
        return response.content
    }

    // Walks pages in order, taking as much of each as fits a fixed character budget — keeps the whole document
    // representable without blowing past the on-device model's context window, at the cost of skipping the tail
    // of a very long document (mentioned to the model so it can say so in the summary).
    static func summarize(index: DocumentTextIndex, pageRange: Range<Int>? = nil) async throws -> String {
        let pages = pageRange.map(Array.init) ?? Array(index.pages.indices)
        var budget = 8000
        var parts: [String] = []
        for page in pages {
            guard budget > 0 else { break }
            let text = String(index.pages[page].prefix(budget))
            guard !text.isEmpty else { continue }
            parts.append("[p.\(page + 1)] \(text)")
            budget -= text.count
        }
        let session = LanguageModelSession(instructions: """
            문서 내용을 한국어로 간결하게 요약해. 핵심만 불릿으로 정리해. 문서가 길어 일부만 봤다면 그렇다고 말해.
            """)
        let response = try await session.respond(to: parts.joined(separator: "\n\n"))
        return response.content
    }

    static func outline(index: DocumentTextIndex) async throws -> [(title: String, page: Int)] {
        let cap = min(30, index.pages.count) // keeps the prompt bounded on very long documents
        let excerpt = (0..<cap).map { "[p.\($0 + 1)] \(index.pages[$0].prefix(300))" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            아래는 문서의 페이지별 내용이다. 목차를 만들어줘. 한 줄에 하나씩 "제목 — p.N" 형식으로만 출력하고 다른 말은 하지 마.
            """)
        let response = try await session.respond(to: excerpt)
        return OutlineParsing.parse(response.content)
    }
}
#endif
