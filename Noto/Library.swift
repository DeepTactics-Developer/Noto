import Foundation
import PDFKit

// One folder per document in the app's Documents directory:
//   source.pdf, title.txt, p<index>.ink (one InkPageFile per page, strokes in page coordinates)
struct DocumentFolder: Identifiable, Hashable {
    let url: URL
    let title: String
    let modified: Date

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

enum Library {
    static func all() -> [DocumentFolder] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil)) ?? []
        return items.compactMap { url -> DocumentFolder? in
            guard fm.fileExists(atPath: url.appending(path: "source.pdf").path) else { return nil }
            let title = (try? String(contentsOf: url.appending(path: "title.txt"), encoding: .utf8)) ?? "제목 없음"
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return DocumentFolder(url: url, title: title, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    static func importPDF(from source: URL) throws -> DocumentFolder {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let fm = FileManager.default
        let folder = URL.documentsDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let title = source.deletingPathExtension().lastPathComponent
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let pdf = folder.appending(path: "source.pdf")
            try fm.copyItem(at: source, to: pdf)
            guard PDFDocument(url: pdf)?.cgPages != nil else { throw NotAPDF() }
            try title.write(to: folder.appending(path: "title.txt"), atomically: true, encoding: .utf8)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return DocumentFolder(url: folder, title: title, modified: .now)
    }

    static func delete(_ document: DocumentFolder) {
        try? FileManager.default.removeItem(at: document.url)
    }
}
