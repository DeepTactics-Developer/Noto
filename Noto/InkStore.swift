import Foundation

// All strokes of one document, per page: loaded on demand, saved a second after the last change,
// with undo/redo registered on the responder chain's undo manager.
final class InkStore {
    private let folder: DocumentFolder
    private var pages: [Int: [InkStroke]] = [:]
    private var dirty: Set<Int> = []
    private var timer: Timer?

    var undoManager: () -> UndoManager? = { nil }
    var onChange: ((Int) -> Void)?
    var onSaveError: ((Error) -> Void)?

    init(folder: DocumentFolder) {
        self.folder = folder
    }

    func strokes(on page: Int) -> [InkStroke] {
        if let cached = pages[page] { return cached }
        let url = folder.inkURL(page: page)
        var loaded: [InkStroke] = []
        if let data = try? Data(contentsOf: url) {
            if let file = try? PropertyListDecoder().decode(InkPageFile.self, from: data) {
                loaded = file.strokes
            } else {
                // Keep an unreadable file instead of overwriting it with the next save.
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            }
        }
        pages[page] = loaded
        return loaded
    }

    func add(_ stroke: InkStroke, on page: Int) {
        replace(remove: [], insert: [stroke], on: page)
    }

    // One undoable edit: takes out `ids` and puts `added` in. It registers its own inverse, which is what makes redo work.
    func replace(remove ids: Set<UUID>, insert added: [InkStroke], on page: Int) {
        let removed = edit(remove: ids, insert: added, on: page)
        let addedIDs = Set(added.map(\.id))
        undoManager()?.registerUndo(withTarget: self) { $0.replace(remove: addedIDs, insert: removed, on: page) }
    }

    // The same edit without undo, for something that changes many times while a pen is down (eraser).
    // The caller collects what happened and registers one undo step at the end with commitErase.
    @discardableResult
    func liveEdit(remove ids: Set<UUID>, insert added: [InkStroke], on page: Int) -> [InkStroke] {
        edit(remove: ids, insert: added, on: page)
    }

    func commitErase(removed: [InkStroke], added: [InkStroke], on page: Int) {
        let addedIDs = Set(added.map(\.id))
        undoManager()?.registerUndo(withTarget: self) { $0.replace(remove: addedIDs, insert: removed, on: page) }
    }

    private func edit(remove ids: Set<UUID>, insert added: [InkStroke], on page: Int) -> [InkStroke] {
        let all = strokes(on: page)
        let removed = all.filter { ids.contains($0.id) }
        guard !removed.isEmpty || !added.isEmpty else { return [] }
        pages[page] = all.filter { !ids.contains($0.id) } + added
        touched(page)
        return removed
    }

    private func touched(_ page: Int) {
        dirty.insert(page)
        onChange?(page)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.flush() }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        for page in dirty {
            do {
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let data = try encoder.encode(InkPageFile(strokes: pages[page] ?? []))
                try data.write(to: folder.inkURL(page: page), options: .atomic)
                dirty.remove(page)
            } catch {
                onSaveError?(error) // stays dirty, so the next flush retries
                return
            }
        }
    }
}
