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

    func testBlankNoteHasOnePageAndIsFindableAfterward() throws {
        let doc = try Library.createBlank(title: "빈 노트")
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(Library.all().map(\.title), ["빈 노트"])
    }
}
