import UIKit

// MARK: - Model

struct TextBox: Identifiable, Codable {
    let id: UUID
    var text: String
    var frame: CGRect // page coordinates, top-left origin
    var fontSize: CGFloat

    init(id: UUID = UUID(), text: String = "", frame: CGRect, fontSize: CGFloat = 16) {
        self.id = id
        self.text = text
        self.frame = frame
        self.fontSize = fontSize
    }
}

struct ImageBox: Identifiable, Codable {
    let id: UUID
    var filename: String // relative to the document folder
    var frame: CGRect

    init(id: UUID = UUID(), filename: String, frame: CGRect) {
        self.id = id
        self.filename = filename
        self.frame = frame
    }
}

struct PageObjectsFile: Codable {
    var version = 1
    var textBoxes: [TextBox] = []
    var images: [ImageBox] = []
}

// MARK: - Store

// Text boxes and images live in their own per-page file, separate from ink, so a bug here can never touch
// the strokes — the one piece of data this app absolutely cannot lose.
final class ObjectStore {
    let folder: DocumentFolder
    private var pages: [Int: PageObjectsFile] = [:]
    private var dirty: Set<Int> = []
    private var timer: Timer?

    var undoManager: () -> UndoManager? = { nil }
    var onChange: ((Int) -> Void)?
    var onSaveError: ((Error) -> Void)?

    init(folder: DocumentFolder) { self.folder = folder }

    func objects(on page: Int) -> PageObjectsFile {
        if let cached = pages[page] { return cached }
        let url = folder.objectsURL(page: page)
        var loaded = PageObjectsFile()
        if let data = try? Data(contentsOf: url), let file = try? PropertyListDecoder().decode(PageObjectsFile.self, from: data) {
            loaded = file
        }
        pages[page] = loaded
        return loaded
    }

    func addText(_ box: TextBox, on page: Int) {
        mutate(page) { $0.textBoxes.append(box) }
        undoManager()?.registerUndo(withTarget: self) { $0.removeText(box.id, on: page) }
    }

    // No undo per keystroke or per auto-grow resize; only structural edits (insert/drag/delete) go on the stack.
    func updateText(_ id: UUID, text: String, on page: Int) {
        mutate(page) { file in
            if let i = file.textBoxes.firstIndex(where: { $0.id == id }) { file.textBoxes[i].text = text }
        }
    }

    func resizeText(_ id: UUID, to frame: CGRect, on page: Int) {
        mutate(page) { file in
            if let i = file.textBoxes.firstIndex(where: { $0.id == id }) { file.textBoxes[i].frame = frame }
        }
    }

    func moveText(_ id: UUID, to frame: CGRect, on page: Int) {
        guard let old = objects(on: page).textBoxes.first(where: { $0.id == id })?.frame else { return }
        mutate(page) { file in
            if let i = file.textBoxes.firstIndex(where: { $0.id == id }) { file.textBoxes[i].frame = frame }
        }
        undoManager()?.registerUndo(withTarget: self) { $0.moveText(id, to: old, on: page) }
    }

    func removeText(_ id: UUID, on page: Int) {
        guard let removed = objects(on: page).textBoxes.first(where: { $0.id == id }) else { return }
        mutate(page) { $0.textBoxes.removeAll { $0.id == id } }
        undoManager()?.registerUndo(withTarget: self) { $0.addText(removed, on: page) }
    }

    func addImage(_ box: ImageBox, on page: Int) {
        mutate(page) { $0.images.append(box) }
        undoManager()?.registerUndo(withTarget: self) { $0.removeImage(box.id, on: page) }
    }

    func moveImage(_ id: UUID, to frame: CGRect, on page: Int) {
        guard let old = objects(on: page).images.first(where: { $0.id == id })?.frame else { return }
        mutate(page) { file in
            if let i = file.images.firstIndex(where: { $0.id == id }) { file.images[i].frame = frame }
        }
        undoManager()?.registerUndo(withTarget: self) { $0.moveImage(id, to: old, on: page) }
    }

    // ponytail: the image file itself is left on disk (not deleted), so undoing a delete never points at a
    // missing file. Upgrade path: sweep files unreferenced by any page's .objects when the doc closes.
    func removeImage(_ id: UUID, on page: Int) {
        guard let removed = objects(on: page).images.first(where: { $0.id == id }) else { return }
        mutate(page) { $0.images.removeAll { $0.id == id } }
        undoManager()?.registerUndo(withTarget: self) { $0.addImage(removed, on: page) }
    }

    private func mutate(_ page: Int, _ body: (inout PageObjectsFile) -> Void) {
        var file = objects(on: page)
        body(&file)
        pages[page] = file
        dirty.insert(page)
        onChange?(page)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.flush() }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for page in dirty {
            guard let file = pages[page] else { dirty.remove(page); continue }
            do {
                try encoder.encode(file).write(to: folder.objectsURL(page: page), options: .atomic)
                dirty.remove(page)
            } catch {
                onSaveError?(error) // stays dirty, so the next flush retries
                return
            }
        }
    }

    // removeImage leaves the file on disk (see its comment) so an undo never points at a missing file; this
    // sweeps whatever no page still references. Reads every page's .objects file, so it's meant for a natural
    // pause point (closing the document), not something to run on every edit.
    func sweepOrphanedImages(pageCount: Int) {
        var referenced = Set<String>()
        for page in 0..<pageCount {
            for image in objects(on: page).images { referenced.insert(image.filename) }
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder.url, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("image_") && !referenced.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }
}

// A view whose empty areas never claim a touch, so it can cover a region wider than its actual content
// (a full page, here) without blocking pencil/finger input meant for whatever sits behind it. Default
// UIView.hitTest claims any point inside its own bounds even with no interactive content there — this override
// is what makes only the REAL children (an actual text box or image) receive touches; anywhere else falls
// through to the next view behind it. Every plain container in this per-page overlay needs this, not just the
// outermost one — an inner UIView with no override of its own would still swallow touches on its own account.
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - Per-page container

// Hosts the text/image objects for one page, above the ink layer (so ink can't be drawn directly under an
// object, which matches how inserting something and then annotating over it is expected to work). Uses the
// same scale-transform-on-a-UIView trick as InkPageView's `host`, so objects scale with the page and ride
// UIKit's rotation animation.
final class ObjectsPageView: PassthroughView {
    private let page: Int
    private let pageSize: CGSize
    private let store: ObjectStore
    private let host = PassthroughView()
    private var textViews: [UUID: TextBoxView] = [:]
    private var imageViews: [UUID: ImageBoxView] = [:]
    private var scale: CGFloat = 0

    init(page: Int, pageSize: CGSize, store: ObjectStore) {
        self.page = page
        self.pageSize = pageSize
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        host.layer.anchorPoint = .zero
        host.frame = CGRect(origin: .zero, size: pageSize)
        addSubview(host)
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newScale = bounds.width / pageSize.width
        guard newScale > 0, newScale != scale else { return }
        let first = scale == 0
        scale = newScale
        let apply = { self.host.transform = CGAffineTransform(scaleX: newScale, y: newScale) }
        if first { UIView.performWithoutAnimation(apply) } else { apply() } // later changes animate with a rotation
    }

    // Brings the views in line with the store: adds missing objects, drops deleted ones, refreshes edits.
    // Frames of objects the user is actively dragging are left alone, so this doesn't fight their finger.
    func sync() {
        let file = store.objects(on: page)

        let textIDs = Set(file.textBoxes.map(\.id))
        for (id, view) in textViews where !textIDs.contains(id) { view.removeFromSuperview(); textViews[id] = nil }
        for box in file.textBoxes {
            if let existing = textViews[box.id] {
                if existing.textView.text != box.text { existing.textView.text = box.text }
                if !existing.isDragging { existing.frame = box.frame }
            } else {
                addTextView(box)
            }
        }

        let imageIDs = Set(file.images.map(\.id))
        for (id, view) in imageViews where !imageIDs.contains(id) { view.removeFromSuperview(); imageViews[id] = nil }
        for box in file.images {
            if let existing = imageViews[box.id] {
                if !existing.isDragging { existing.frame = box.frame }
            } else {
                addImageView(box)
            }
        }
    }

    func insertText(at center: CGPoint) {
        let width: CGFloat = min(220, pageSize.width - 24)
        let box = TextBox(frame: CGRect(x: center.x - width / 2, y: center.y - 20, width: width, height: 40))
        store.addText(box, on: page)
        sync()
        textViews[box.id]?.textView.becomeFirstResponder()
    }

    func insertImage(_ image: UIImage, filename: String, at center: CGPoint) {
        let maxWidth: CGFloat = min(240, pageSize.width - 24)
        let aspect = image.size.height / max(image.size.width, 1)
        let size = CGSize(width: maxWidth, height: maxWidth * aspect)
        let box = ImageBox(filename: filename, frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                                              width: size.width, height: size.height))
        store.addImage(box, on: page)
        sync()
    }

    private func addTextView(_ box: TextBox) {
        let pageIndex = page
        let view = TextBoxView(id: box.id, text: box.text)
        view.frame = box.frame
        view.textView.font = .systemFont(ofSize: box.fontSize)
        view.onChange = { [weak self] text in self?.store.updateText(box.id, text: text, on: pageIndex) }
        view.onResize = { [weak self] frame in self?.store.resizeText(box.id, to: frame, on: pageIndex) }
        view.onMoveEnded = { [weak self] frame in self?.store.moveText(box.id, to: frame, on: pageIndex) }
        view.onDelete = { [weak self] in
            self?.store.removeText(box.id, on: pageIndex)
            self?.sync()
        }
        host.addSubview(view)
        textViews[box.id] = view
    }

    private func addImageView(_ box: ImageBox) {
        guard let data = try? Data(contentsOf: store.folder.fileURL(box.filename)), let image = UIImage(data: data) else { return }
        let pageIndex = page
        let view = ImageBoxView(id: box.id, image: image)
        view.frame = box.frame
        view.onMoveEnded = { [weak self] frame in self?.store.moveImage(box.id, to: frame, on: pageIndex) }
        view.onDelete = { [weak self] in
            self?.store.removeImage(box.id, on: pageIndex)
            self?.sync()
        }
        host.addSubview(view)
        imageViews[box.id] = view
    }
}

// MARK: - Object views

// A draggable text note. The text view handles typing/cursor itself; dragging only happens via the handle
// strip above it, so a tap on the text body always edits rather than fighting a pan gesture. Finger only —
// consistent with the rest of the app, where the pencil draws and fingers manipulate.
final class TextBoxView: UIView, UITextViewDelegate {
    let id: UUID
    let textView = UITextView()
    private(set) var isDragging = false

    var onChange: ((String) -> Void)?
    var onResize: ((CGRect) -> Void)?
    var onMoveEnded: ((CGRect) -> Void)?
    var onDelete: (() -> Void)?

    private let handle = UIView()
    private let grip = UIImageView(image: UIImage(systemName: "line.3.horizontal"))
    private let deleteButton = UIButton(type: .system)
    private let handleHeight: CGFloat = 22
    private var frameAtDragStart: CGRect = .zero

    init(id: UUID, text: String) {
        self.id = id
        super.init(frame: .zero)
        backgroundColor = .clear

        handle.backgroundColor = .systemGray5
        addSubview(handle)
        grip.tintColor = .secondaryLabel
        grip.contentMode = .center
        handle.addSubview(grip)
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = .secondaryLabel
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        handle.addSubview(deleteButton)

        textView.text = text
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.isOpaque = false
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        textView.layer.borderColor = UIColor.separator.cgColor
        textView.layer.borderWidth = 0.5
        textView.delegate = self
        addSubview(textView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.maximumNumberOfTouches = 1
        handle.addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // The pencil is reserved for drawing/erasing/lasso everywhere else in the app; only fingers drag or edit
    // an object. So a pencil touch here passes straight through to whatever's behind it (normally ink), instead
    // of this box swallowing it just because it happens to sit on top.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let touches = event?.allTouches, touches.contains(where: { $0.type == .pencil }) { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        handle.frame = CGRect(x: 0, y: 0, width: bounds.width, height: handleHeight)
        grip.frame = handle.bounds
        deleteButton.frame = CGRect(x: bounds.width - handleHeight, y: 0, width: handleHeight, height: handleHeight)
        textView.frame = CGRect(x: 0, y: handleHeight, width: bounds.width, height: max(0, bounds.height - handleHeight))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textSize = textView.sizeThatFits(CGSize(width: size.width, height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: handleHeight + max(textSize.height, 24))
    }

    @objc private func deleteTapped() { onDelete?() }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            frameAtDragStart = frame
        case .changed:
            let translation = gesture.translation(in: superview)
            frame = frameAtDragStart.offsetBy(dx: translation.x, dy: translation.y)
        case .ended, .cancelled:
            isDragging = false
            onMoveEnded?(frame)
        default:
            break
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        onChange?(textView.text)
        let fit = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        if abs(fit.height - bounds.height) > 0.5 {
            frame = CGRect(origin: frame.origin, size: fit)
            onResize?(frame)
        }
    }
}

// A draggable, pinch-resizable image. Finger only, same reasoning as the text box.
final class ImageBoxView: UIView {
    let id: UUID
    private(set) var isDragging = false
    private let imageView = UIImageView()
    private let deleteButton = UIButton(type: .system)

    var onMoveEnded: ((CGRect) -> Void)?
    var onDelete: (() -> Void)?

    private var frameAtGestureStart: CGRect = .zero

    init(id: UUID, image: UIImage) {
        self.id = id
        super.init(frame: .zero)
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        imageView.isOpaque = false
        imageView.layer.borderColor = UIColor.separator.cgColor
        imageView.layer.borderWidth = 0.5
        addSubview(imageView)

        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = .secondaryLabel
        deleteButton.backgroundColor = .white
        deleteButton.layer.cornerRadius = 11
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        addSubview(deleteButton)

        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = fingers
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = fingers
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // See the matching override on TextBoxView: a pencil touch always draws through to whatever's behind this.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let touches = event?.allTouches, touches.contains(where: { $0.type == .pencil }) { return nil }
        return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        deleteButton.frame = CGRect(x: bounds.width - 22, y: -8, width: 22, height: 22)
    }

    @objc private func deleteTapped() { onDelete?() }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            frameAtGestureStart = frame
        case .changed:
            let translation = gesture.translation(in: superview)
            frame = frameAtGestureStart.offsetBy(dx: translation.x, dy: translation.y)
        case .ended, .cancelled:
            isDragging = false
            onMoveEnded?(frame)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDragging = true
            frameAtGestureStart = frame
        case .changed:
            let width = max(40, frameAtGestureStart.width * gesture.scale)
            let height = max(40, frameAtGestureStart.height * gesture.scale)
            frame = CGRect(x: frameAtGestureStart.midX - width / 2, y: frameAtGestureStart.midY - height / 2, width: width, height: height)
        case .ended, .cancelled:
            isDragging = false
            onMoveEnded?(frame)
        default:
            break
        }
    }
}
