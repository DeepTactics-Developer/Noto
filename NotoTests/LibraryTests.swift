import XCTest
@testable import Noto

final class LibraryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        Library.root = tempRoot
        SubjectStore.root = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        Library.root = .documentsDirectory
        SubjectStore.root = .documentsDirectory
    }

    func testMetaRoundTrip() throws {
        let folder = tempRoot.appending(path: "doc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = DocumentMeta(title: "물리학 3강")
        meta.favorite = true
        meta.subjectID = UUID()
        try meta.save(to: folder)

        let loaded = DocumentMeta.load(from: folder)
        XCTAssertEqual(loaded.title, meta.title)
        XCTAssertTrue(loaded.favorite)
        XCTAssertEqual(loaded.subjectID, meta.subjectID)
    }

    // Documents made before meta.json existed only have this file.
    func testMetaFallsBackToOldTitleFile() throws {
        let folder = tempRoot.appending(path: "doc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "옛 제목".write(to: folder.appending(path: "title.txt"), atomically: true, encoding: .utf8)

        let loaded = DocumentMeta.load(from: folder)
        XCTAssertEqual(loaded.title, "옛 제목")
        XCTAssertFalse(loaded.favorite)
        XCTAssertNil(loaded.subjectID)
    }

    func testSavingMetaRemovesTheOldTitleFile() throws {
        let folder = tempRoot.appending(path: "doc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let titleFile = folder.appending(path: "title.txt")
        try "옛 제목".write(to: titleFile, atomically: true, encoding: .utf8)

        try DocumentMeta(title: "새 제목").save(to: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: titleFile.path))
    }

    func testDeletingASubjectUnassignsItFromDocuments() throws {
        let subject = SubjectStore.add(name: "자료구조")
        let doc = try Library.createBlank(title: "노트")
        Library.setSubject(subject.id, for: doc)
        XCTAssertEqual(Library.all().first?.subjectID, subject.id)

        SubjectStore.delete(subject.id)
        XCTAssertTrue(SubjectStore.all().isEmpty)
        XCTAssertNil(Library.all().first?.subjectID)
    }

    func testFavoriteToggleIsReflectedInLibraryListing() throws {
        let doc = try Library.createBlank(title: "노트")
        XCTAssertFalse(Library.all().first?.favorite ?? true)

        Library.setFavorite(true, for: doc)
        XCTAssertTrue(Library.all().first?.favorite ?? false)
    }

    func testBookmarkToggleAddsAndRemovesAPage() throws {
        let doc = try Library.createBlank(title: "노트")
        XCTAssertTrue(Library.bookmarkedPages(for: doc).isEmpty)

        Library.toggleBookmark(2, for: doc)
        Library.toggleBookmark(5, for: doc)
        XCTAssertEqual(Library.bookmarkedPages(for: doc), [2, 5])

        Library.toggleBookmark(2, for: doc)
        XCTAssertEqual(Library.bookmarkedPages(for: doc), [5])
    }

    // Simulates a meta.json written by a build before bookmarkedPages existed: the key is simply absent.
    func testMetaDecodesAFileMissingANewerFieldAsEmpty() throws {
        let folder = tempRoot.appending(path: "doc")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = ["title": "3주차", "favorite": true] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: old)
        try data.write(to: folder.appending(path: "meta.json"))

        let loaded = DocumentMeta.load(from: folder)
        XCTAssertEqual(loaded.title, "3주차")
        XCTAssertTrue(loaded.favorite)
        XCTAssertTrue(loaded.bookmarkedPages.isEmpty)
    }

    func testBlankNoteHasOnePageAndIsFindableAfterward() throws {
        let doc = try Library.createBlank(title: "빈 노트")
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(Library.all().map(\.title), ["빈 노트"])
    }

    func testTrashingRemovesFromLibraryAndListsInTrash() throws {
        let doc = try Library.createBlank(title: "노트")
        Library.trash(doc)
        XCTAssertTrue(Library.all().isEmpty)
        XCTAssertEqual(Library.trashedDocuments().map(\.title), ["노트"])
        XCTAssertNotNil(Library.trashedDocuments().first?.deletedAt)
    }

    func testRestoringATrashedDocumentBringsItBack() throws {
        let doc = try Library.createBlank(title: "노트")
        Library.trash(doc)
        let trashed = try XCTUnwrap(Library.trashedDocuments().first)
        Library.restore(trashed)
        XCTAssertTrue(Library.trashedDocuments().isEmpty)
        XCTAssertEqual(Library.all().map(\.title), ["노트"])
        XCTAssertNil(Library.all().first?.deletedAt)
    }

    func testPermanentlyDeletingATrashedDocumentRemovesTheFolder() throws {
        let doc = try Library.createBlank(title: "노트")
        Library.trash(doc)
        let trashed = try XCTUnwrap(Library.trashedDocuments().first)
        Library.permanentlyDelete(trashed)
        XCTAssertTrue(Library.trashedDocuments().isEmpty)
    }

    // purgeExpiredTrash only removes documents whose deletedAt is old enough — a document trashed moments ago
    // must survive the sweep.
    func testPurgeExpiredTrashOnlyRemovesOldEntries() throws {
        let fresh = try Library.createBlank(title: "최근 삭제")
        Library.trash(fresh)
        let old = try Library.createBlank(title: "오래된 삭제")
        Library.trash(old)
        var oldMeta = DocumentMeta.load(from: Library.trashedDocuments().first { $0.title == "오래된 삭제" }!.url)
        oldMeta.deletedAt = Date.now.addingTimeInterval(-Double(Library.trashLifetimeDays + 1) * 24 * 60 * 60)
        try oldMeta.save(to: Library.trashedDocuments().first { $0.title == "오래된 삭제" }!.url)

        Library.purgeExpiredTrash()
        XCTAssertEqual(Library.trashedDocuments().map(\.title), ["최근 삭제"])
    }
}
