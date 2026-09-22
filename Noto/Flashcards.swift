import Foundation

struct Flashcard: Codable, Identifiable {
    let id: UUID
    var front: String
    var back: String
    var createdAt: Date
    var timesStudied: Int = 0
    var timesKnown: Int = 0

    init(id: UUID = UUID(), front: String, back: String, createdAt: Date = .now, timesStudied: Int = 0, timesKnown: Int = 0) {
        self.id = id
        self.front = front
        self.back = back
        self.createdAt = createdAt
        self.timesStudied = timesStudied
        self.timesKnown = timesKnown
    }

    // nil until studied at least once, so the deck list can show "—" instead of a misleading 0%.
    var accuracy: Double? { timesStudied > 0 ? Double(timesKnown) / Double(timesStudied) : nil }

    // Custom decode so a deck saved before accuracy tracking existed still loads (missing fields default to 0),
    // the same pattern InkStroke uses for its own added-later `pressure` field.
    private enum CodingKeys: String, CodingKey { case id, front, back, createdAt, timesStudied, timesKnown }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        front = try container.decode(String.self, forKey: .front)
        back = try container.decode(String.self, forKey: .back)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        timesStudied = try container.decodeIfPresent(Int.self, forKey: .timesStudied) ?? 0
        timesKnown = try container.decodeIfPresent(Int.self, forKey: .timesKnown) ?? 0
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
