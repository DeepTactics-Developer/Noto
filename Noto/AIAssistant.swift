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

// Turns FoundationModels' own English error text into something a Korean-speaking user can act on. Matched by
// substring against the real strings this framework has been observed to produce (e.g. "Exceeded model context
// window size", "Detected content likely to be unsafe") rather than typed error cases, since those are the only
// form of this available without a device to confirm exact enum shapes against.
enum AIErrorMessage {
    static func friendly(for error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("unsafe") {
            return "AI가 이 내용을 처리할 수 없다고 판단했습니다. 다른 부분을 선택하거나 필기가 정확히 인식됐는지 확인해보세요."
        }
        if text.contains("context window") || text.contains("exceeded") {
            return "내용이 너무 길어 처리하지 못했습니다. 선택 범위를 줄이거나 다시 시도해보세요."
        }
        return error.localizedDescription
    }

    static func isContextWindowError(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("context window") || text.contains("exceeded")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum AIAssistant {
    static func answer(question: String, index: DocumentTextIndex) async throws -> String {
        let pages = index.relevantPages(to: question)
        let excerpt = pages.map { "[p.\($0 + 1)]\n\(index.pages[$0].prefix(900))" }.joined(separator: "\n\n")
        let session = LanguageModelSession(instructions: """
            너는 사용자가 보고 있는 PDF 문서 내용만 근거로 답하는 도우미야. 아래는 문서에서 발췌한 페이지들이다.
            답변은 한국어로 간결하게 하고, 근거로 쓴 페이지 번호를 문장 끝에 (p.N) 형식으로 표시해.
            발췌에 없는 내용은 추측하지 말고 모른다고 말해.
            """)
        let response = try await session.respond(to: "\(excerpt)\n\n질문: \(question)")
        return response.content
    }

    // For the lasso selection's own "AI로 설명" — explains exactly the given content (PDF text + recognized
    // handwriting from inside the lasso), not a document-wide search like `answer`. Capped defensively: a lasso
    // can enclose a lot of PDF text, and unlike answer()/summarize() nothing upstream already bounds this one.
    static func explainSelection(_ content: String) async throws -> String {
        let session = LanguageModelSession(instructions: """
            사용자가 문서에서 선택한 내용이야. 한국어로 간결하게 설명해줘. 선택 내용이 수식이나 개념이면 풀어서,
            문장이면 요점을, 목록이면 각 항목의 의미를 설명해.
            """)
        let response = try await session.respond(to: String(content.prefix(4000)))
        return response.content
    }

    // Walks pages in order, taking as much of each as fits a fixed character budget — keeps the whole document
    // representable without blowing past the on-device model's context window, at the cost of skipping the tail
    // of a very long document (mentioned to the model so it can say so in the summary). The real limit isn't
    // known precisely (and likely varies with how dense the document's own text is), so on an "exceeded context
    // window" error this retries with a shrinking budget rather than just failing.
    static func summarize(index: DocumentTextIndex, pageRange: Range<Int>? = nil) async throws -> String {
        let pages = pageRange.map(Array.init) ?? Array(index.pages.indices)
        var lastError: Error?
        for budget in [4000, 2000, 1000] {
            do {
                return try await summarizeAttempt(index: index, pages: pages, budget: budget)
            } catch {
                guard AIErrorMessage.isContextWindowError(error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? CancellationError()
    }

    private static func summarizeAttempt(index: DocumentTextIndex, pages: [Int], budget initialBudget: Int) async throws -> String {
        var budget = initialBudget
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
        let cap = min(20, index.pages.count) // keeps the prompt bounded on very long documents
        let excerpt = (0..<cap).map { "[p.\($0 + 1)] \(index.pages[$0].prefix(250))" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            아래는 문서의 페이지별 내용이다. 목차를 만들어줘. 한 줄에 하나씩 "제목 — p.N" 형식으로만 출력하고 다른 말은 하지 마.
            """)
        let response = try await session.respond(to: excerpt)
        return OutlineParsing.parse(response.content)
    }
}
#endif
