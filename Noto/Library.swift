import Foundation
import PDFKit
import SwiftUI

// One folder per document in the app's Documents directory:
//   source.pdf, meta.json (title/subject/favorite), p<index>.ink (one InkPageFile per page, page coordinates)
// Older documents may only have title.txt; DocumentMeta reads that as a fallback and replaces it on first save.
struct DocumentFolder: Identifiable, Hashable {
    let url: URL
    let title: String
    let modified: Date
    let pageCount: Int
    let subjectID: UUID?
    let favorite: Bool

    var id: String { url.lastPathComponent }
    var pdfURL: URL { url.appending(path: "source.pdf") }
    func inkURL(page: Int) -> URL { url.appending(path: "p\(page).ink") }
}

struct NotAPDF: LocalizedError {
    var errorDescription: String? { "파일이 올바른 PDF가 아니거나 암호가 걸려 있습니다." }
}

extension PDFDocument {
    // Every page as a CGPDFPage, or nil for locked, empty or partly unreadable files.
    var cgPages: [CGPDFPage]? {
        guard !isLocked, pageCount > 0 else { return nil }
        let pages = (0..<pageCount).compactMap { page(at: $0)?.pageRef }
        return pages.count == pageCount ? pages : nil
    }
}

struct DocumentMeta: Codable {
    var title: String
    var subjectID: UUID?
    var favorite: Bool = false
    var bookmarkedPages: Set<Int> = []

    init(title: String, subjectID: UUID? = nil, favorite: Bool = false, bookmarkedPages: Set<Int> = []) {
        self.title = title
        self.subjectID = subjectID
        self.favorite = favorite
        self.bookmarkedPages = bookmarkedPages
    }

    // Custom decode so a meta.json saved by an older build of the app (missing a field added since) still opens,
    // the same way the fallback to title.txt below handles files from before meta.json existed at all.
    private enum CodingKeys: String, CodingKey { case title, subjectID, favorite, bookmarkedPages }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        subjectID = try container.decodeIfPresent(UUID.self, forKey: .subjectID)
        favorite = try container.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        bookmarkedPages = try container.decodeIfPresent(Set<Int>.self, forKey: .bookmarkedPages) ?? []
    }

    static func load(from folder: URL) -> DocumentMeta {
        let metaURL = folder.appending(path: "meta.json")
        if let data = try? Data(contentsOf: metaURL), let meta = try? JSONDecoder().decode(DocumentMeta.self, from: data) {
            return meta
        }
        // Documents created before meta.json existed only have this.
        let title = (try? String(contentsOf: folder.appending(path: "title.txt"), encoding: .utf8)) ?? "제목 없음"
        return DocumentMeta(title: title)
    }

    func save(to folder: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: folder.appending(path: "meta.json"), options: .atomic)
        try? FileManager.default.removeItem(at: folder.appending(path: "title.txt")) // superseded, if it was there
    }
}

struct Subject: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var colorIndex: Int

    static let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal]
    var color: Color { Subject.palette[colorIndex % Subject.palette.count] }
}

// Subjects (課目) are library-wide, stored once alongside the documents.
enum SubjectStore {
    static var root: URL = .documentsDirectory // overridden by tests
    private static var url: URL { root.appending(path: "subjects.json") }

    static func all() -> [Subject] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Subject].self, from: data) else { return [] }
        return list
    }

    private static func save(_ subjects: [Subject]) {
        guard let data = try? JSONEncoder().encode(subjects) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func add(name: String) -> Subject {
        var list = all()
        let subject = Subject(name: name, colorIndex: list.count)
        list.append(subject)
        save(list)
        return subject
    }

    static func delete(_ id: UUID) {
        save(all().filter { $0.id != id })
        for doc in Library.all() where doc.subjectID == id {
            Library.setSubject(nil, for: doc)
        }
    }
}

enum Library {
    static var root: URL = .documentsDirectory // overridden by tests

    static func all() -> [DocumentFolder] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url -> DocumentFolder? in
            let pdfURL = url.appending(path: "source.pdf")
            guard fm.fileExists(atPath: pdfURL.path) else { return nil }
            let meta = DocumentMeta.load(from: url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let pageCount = CGPDFDocument(pdfURL as CFURL)?.numberOfPages ?? 0
            return DocumentFolder(url: url, title: meta.title, modified: modified, pageCount: pageCount,
                                  subjectID: meta.subjectID, favorite: meta.favorite)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func importPDF(from source: URL) throws -> DocumentFolder {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let title = source.deletingPathExtension().lastPathComponent
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let pdf = folder.appending(path: "source.pdf")
            try fm.copyItem(at: source, to: pdf)
            guard let pages = PDFDocument(url: pdf)?.cgPages else { throw NotAPDF() }
            try DocumentMeta(title: title).save(to: folder)
            return DocumentFolder(url: folder, title: title, modified: .now, pageCount: pages.count, subjectID: nil, favorite: false)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    static func createBlank(title: String = "새 노트") throws -> DocumentFolder {
        let fm = FileManager.default
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter, in points
            let data = UIGraphicsPDFRenderer(bounds: pageRect).pdfData { ctx in
                ctx.beginPage()
                UIColor.white.setFill()
                ctx.fill(pageRect)
            }
            try data.write(to: folder.appending(path: "source.pdf"))
            try DocumentMeta(title: title).save(to: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return DocumentFolder(url: folder, title: title, modified: .now, pageCount: 1, subjectID: nil, favorite: false)
    }

    static func delete(_ document: DocumentFolder) {
        try? FileManager.default.removeItem(at: document.url)
    }

    static func setFavorite(_ favorite: Bool, for document: DocumentFolder) {
        var meta = DocumentMeta.load(from: document.url)
        meta.favorite = favorite
        try? meta.save(to: document.url)
    }

    static func setSubject(_ subjectID: UUID?, for document: DocumentFolder) {
        var meta = DocumentMeta.load(from: document.url)
        meta.subjectID = subjectID
        try? meta.save(to: document.url)
    }

    static func bookmarkedPages(for document: DocumentFolder) -> Set<Int> {
        DocumentMeta.load(from: document.url).bookmarkedPages
    }

    static func toggleBookmark(_ page: Int, for document: DocumentFolder) {
        var meta = DocumentMeta.load(from: document.url)
        if meta.bookmarkedPages.contains(page) { meta.bookmarkedPages.remove(page) } else { meta.bookmarkedPages.insert(page) }
        try? meta.save(to: document.url)
    }
}
