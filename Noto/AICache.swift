import Foundation

// Summary and outline are cheap to cache and safe to: both are derived purely from the PDF's own (unchanging)
// text, never from ink or user input, so the same document always produces the same request. Freeform questions
// and lasso "AI로 설명" are NOT cached here — those vary with what the user actually asks/selects each time.
private struct AICache: Codable {
    var summary: String?
    var outline: [Entry]?

    struct Entry: Codable {
        var title: String
        var page: Int
    }
}

enum AICacheStore {
    private static func url(for folder: DocumentFolder) -> URL { folder.url.appending(path: "ai-cache.json") }

    private static func load(for folder: DocumentFolder) -> AICache {
        guard let data = try? Data(contentsOf: url(for: folder)), let cache = try? JSONDecoder().decode(AICache.self, from: data) else {
            return AICache()
        }
        return cache
    }

    private static func save(_ cache: AICache, for folder: DocumentFolder) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url(for: folder), options: .atomic)
    }

    static func summary(for folder: DocumentFolder) -> String? {
        load(for: folder).summary
    }

    static func setSummary(_ summary: String, for folder: DocumentFolder) {
        var cache = load(for: folder)
        cache.summary = summary
        save(cache, for: folder)
    }

    static func outline(for folder: DocumentFolder) -> [(title: String, page: Int)]? {
        load(for: folder).outline?.map { (title: $0.title, page: $0.page) }
    }

    static func setOutline(_ items: [(title: String, page: Int)], for folder: DocumentFolder) {
        var cache = load(for: folder)
        cache.outline = items.map { AICache.Entry(title: $0.title, page: $0.page) }
        save(cache, for: folder)
    }
}
