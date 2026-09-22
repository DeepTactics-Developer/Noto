import Foundation

struct Flashcard: Codable, Identifiable {
    let id: UUID
    var front: String
    var back: String
    var createdAt: Date

    init(id: UUID = UUID(), front: String, back: String, createdAt: Date = .now) {
        self.id = id
        self.front = front
        self.back = back
        self.createdAt = createdAt
    }
}

// One JSON list per document, same shape as RecordingStore — a deck is never big enough to need incremental saves.
enum FlashcardStore {
    private static func url(for folder: DocumentFolder) -> URL { folder.url.appending(path: "flashcards.json") }

    static func all(for folder: DocumentFolder) -> [Flashcard] {
        guard let data = try? Data(contentsOf: url(for: folder)),
              let list = try? JSONDecoder().decode([Flashcard].self, from: data) else { return [] }
        return list
    }

    static func save(_ cards: [Flashcard], for folder: DocumentFolder) {
        guard let data = try? JSONEncoder().encode(cards) else { return }
        try? data.write(to: url(for: folder), options: .atomic)
    }
}
