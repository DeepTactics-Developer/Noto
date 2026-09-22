import Foundation

enum OutlineParsing {
    // Parses "제목 — p.3" / "제목 - p.3" style lines (as instructed of the AI) into (title, zero-based page) pairs.
    // Kept separate from the model call itself so it's testable without any FoundationModels dependency.
    static func parse(_ text: String) -> [(title: String, page: Int)] {
        text.split(separator: "\n").compactMap { line -> (title: String, page: Int)? in
            guard let range = line.range(of: "— p.") ?? line.range(of: "- p.") ?? line.range(of: "-p.") else { return nil }
            let title = line[line.startIndex..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let pageText = line[range.upperBound...].trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
            guard let page = Int(pageText), !title.isEmpty else { return nil }
            return (title, page - 1)
        }
    }
}
