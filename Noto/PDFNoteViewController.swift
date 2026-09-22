import UIKit
import PDFKit
import PencilKit
import PhotosUI
import SwiftUI

// Own page viewer: a vertical stack of pages inside a UIScrollView with its standard pinch zoom.
// Layout never changes while zooming. Ink is vector and scales with the container; when a pinch ends the PDF
// tiles are redrawn at the new resolution. PencilKit is only used for its tool palette.
final class PDFNoteViewController: UIViewController, UIScrollViewDelegate, PKToolPickerObserver, PHPickerViewControllerDelegate {
    private let folder: DocumentFolder
    private let document: PDFDocument // keeps the CGPDFPages alive
    private let pages: [CGPDFPage]
    private let pageSizes: [CGSize] // displayed size in PDF points
    private let store: InkStore
    private let objectStore: ObjectStore
    private let model: NoteViewModel
    private var imagePickerPage: Int?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let toolPicker = PKToolPicker()

    private var frames: [CGRect] = []
    private var live: [Int: PageView] = [:]
    private var laidOutWidth: CGFloat = 0
    private var renderZoom: CGFloat = 1
    private let margin: CGFloat = 12 // page gap and side margin

    private var mode: InkMode = .none
    private var currentTool: PKTool = PKInkingTool(.pen)
    private var saveAlertShown = false

    private let previews = NSCache<NSNumber, UIImage>()
    private let previewQueue = DispatchQueue(label: "noto.preview", qos: .userInitiated)

    // The controller is the picker's responder, so the palette stays up while pages come and go.
    override var canBecomeFirstResponder: Bool { true }

    init(folder: DocumentFolder, document: PDFDocument, pages: [CGPDFPage], model: NoteViewModel) {
        self.folder = folder
        self.document = document
        self.pages = pages
        self.store = InkStore(folder: folder)
        self.objectStore = ObjectStore(folder: folder)
        self.model = model
        self.pageSizes = pages.map { page in
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            return size.width > 0 && size.height > 0 ? size : CGSize(width: 612, height: 792)
        }
        super.init(nibName: nil, bundle: nil)
        previews.totalCostLimit = 120_000_000
        store.undoManager = { [weak self] in self?.undoManager }
        store.onChange = { [weak self] page in self?.live[page]?.ink.sync() }
        store.onSaveError = { [weak self] error in self?.reportSaveFailure(error) }
        objectStore.undoManager = { [weak self] in self?.undoManager }
        objectStore.onChange = { [weak self] page in self?.live[page]?.objects.sync() }
        objectStore.onSaveError = { [weak self] error in self?.reportSaveFailure(error) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .systemGray5
        scrollView.delegate = self
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.panGestureRecognizer.allowedTouchTypes = fingers // the pencil only draws
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = fingers
        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        apply(toolPicker.selectedTool)
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)
        NotificationCenter.default.addObserver(self, selector: #selector(flush), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: UserDefaults.didChangeNotification, object: nil)
        model.scrollToPage = { [weak self] index in self?.scrollToPage(index) }
        model.showMatch = { [weak self] page, rect in self?.flashHighlight(page: page, rectInPage: rect) }
        model.insertText = { [weak self] in self?.insertText() }
        model.insertImage = { [weak self] in self?.presentImagePicker() }
        model.pasteInk = { [weak self] in self?.pasteInk() }
    }

    // MARK: Search

    // Jumps to the match's page and briefly flashes its rect. The rect comes from PDFKit's own text layout in
    // that page's point space, which already accounts for rotation the same way pageSizes does.
    private func flashHighlight(page: Int, rectInPage: CGRect) {
        guard frames.indices.contains(page) else { return }
        scrollToPage(page)
        let pageFrame = frames[page]
        let scale = pageFrame.width / pageSizes[page].width
        let highlightFrame = CGRect(x: pageFrame.minX + rectInPage.minX * scale, y: pageFrame.minY + rectInPage.minY * scale,
                                    width: rectInPage.width * scale, height: rectInPage.height * scale).insetBy(dx: -2, dy: -2)
        let box = UIView(frame: highlightFrame)
        box.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.4)
        box.layer.cornerRadius = 2
        contentView.addSubview(box)
        UIView.animate(withDuration: 1.0, delay: 0.7, options: []) { box.alpha = 0 } completion: { _ in box.removeFromSuperview() }
    }

    // MARK: Insert text / image

    // A point near the middle of whatever part of the page is currently on screen, so a freshly inserted
    // object doesn't land off-screen on a page taller than the viewport.
    private func visibleCenter(on page: Int) -> CGPoint {
        let visible = visibleRect().intersection(frames[page])
        let localY = visible.isNull ? pageSizes[page].height / 2 : visible.midY - frames[page].minY
        return CGPoint(x: pageSizes[page].width / 2, y: max(20, min(localY, pageSizes[page].height - 20)))
    }

    private func insertText() {
        let page = model.currentPage
        live[page]?.objects.insertText(at: visibleCenter(on: page))
    }

    private func pasteInk() {
        let page = model.currentPage
        live[page]?.ink.pasteClipboard(at: visibleCenter(on: page))
    }

    private func presentImagePicker() {
        imagePickerPage = model.currentPage
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let page = imagePickerPage, let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async { self?.addPickedImage(image, on: page) }
        }
    }

    private func addPickedImage(_ image: UIImage, on page: Int) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        let filename = "image_\(UUID().uuidString).jpg"
        do {
            try data.write(to: folder.fileURL(filename))
        } catch {
            reportSaveFailure(error)
            return
        }
        live[page]?.objects.insertImage(image, filename: filename, at: visibleCenter(on: page))
    }

    // Called by the thumbnail sidebar. scrollRectToVisible only guarantees the rect becomes visible with the
    // least motion, which for a page taller than the viewport can land on its bottom half (or even leave the
    // scroll short of the page, reading as the wrong page). Converting the page's top through the content view
    // instead targets that exact point at the very top of the viewport, correct at any zoom level.
    private func scrollToPage(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        let top = contentView.convert(CGPoint(x: 0, y: frames[index].minY), to: scrollView)
        let bottomRight = contentView.convert(CGPoint(x: contentView.bounds.width, y: contentView.bounds.height), to: scrollView)
        let maxX = max(0, bottomRight.x - scrollView.bounds.width)
        let maxY = max(0, bottomRight.y - scrollView.bounds.height)
        let target = CGPoint(x: min(max(top.x, 0), maxX), y: min(max(top.y, 0), maxY))
        scrollView.setContentOffset(target, animated: true)
    }

    // "Current page" for the sidebar highlight: whichever page covers the middle of the viewport, not just
    // whichever page's top edge the viewport has scrolled past. A page shorter than the viewport can leave its
    // last sliver at the very top while the next page already fills most of the screen; topmost-edge anchoring
    // (used above for rotation continuity, where exactness matters more than perception) would keep reporting
    // the page that's mostly scrolled away.
    private func updateCurrentPage() {
        guard let index = pageAtViewportCenter(), model.currentPage != index else { return }
        model.currentPage = index
    }

    private func pageAtViewportCenter() -> Int? {
        let center = visibleRect().midY
        if let hit = frames.firstIndex(where: { $0.minY <= center && center <= $0.maxY }) { return hit }
        // In the gap between pages: whichever page's edge is closer.
        return frames.indices.min { gapTo(frames[$0], center) < gapTo(frames[$1], center) }
    }

    private func gapTo(_ frame: CGRect, _ y: CGFloat) -> CGFloat {
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }

    // The eraser mode setting decides how the palette's eraser behaves, so the tool is mapped again.
    @objc private func settingsChanged() {
        apply(currentTool)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flush()
        toolPicker.setVisible(false, forFirstResponder: self)
        resignFirstResponder()
    }

    @objc private func flush() {
        store.flush()
        objectStore.flush()
    }

    // MARK: Layout

    // The part of the content currently on screen, in content coordinates (undoes the zoom).
    private func visibleRect() -> CGRect {
        scrollView.convert(scrollView.bounds, to: contentView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0, width != laidOutWidth else { return }
        let anchor = anchorAtTop()
        laidOutWidth = width
        scrollView.setZoomScale(1, animated: false)
        renderZoom = 1
        live.values.forEach { $0.beginResize(renderZoom: 1) } // before the pages change size
        relayout()
        if let anchor {
            let frame = frames[anchor.index]
            scrollView.contentOffset = clamped(CGPoint(x: 0, y: frame.minY + anchor.fraction * frame.height))
        }
        layoutVisiblePages()
        updateCurrentPage()
    }

    // Only called at zoom 1.
    private func relayout() {
        let width = scrollView.bounds.width
        let pageWidth = max(width - 2 * margin, 1)
        var y = margin
        frames = pageSizes.map { size in
            let frame = CGRect(x: margin, y: y, width: pageWidth, height: pageWidth * size.height / size.width)
            y = frame.maxY + margin
            return frame
        }
        let content = CGSize(width: width, height: y)
        contentView.frame = CGRect(origin: .zero, size: content)
        scrollView.contentSize = content
        for (index, view) in live { view.frame = frames[index] }
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        return CGPoint(x: max(0, min(offset.x, max(0, content.width - bounds.width))),
                       y: max(0, min(offset.y, max(0, content.height - bounds.height))))
    }

    private func anchorAtTop() -> (index: Int, fraction: CGFloat)? {
        let y = visibleRect().minY
        guard let index = frames.lastIndex(where: { $0.minY <= y }) ?? frames.indices.first else { return nil }
        let frame = frames[index]
        return (index, frame.height > 0 ? (y - frame.minY) / frame.height : 0)
    }

    // Pages within a couple of screens of the viewport get views; they are only released once well outside
    // that, so scrolling back and forth does not rebuild them.
    private func layoutVisiblePages() {
        guard !frames.isEmpty else { return }
        let visible = visibleRect()
        func intersects(_ index: Int, above: CGFloat, below: CGFloat) -> Bool {
            frames[index].maxY >= visible.minY - above && frames[index].minY <= visible.maxY + below
        }
        for index in Array(live.keys) where !intersects(index, above: 3 * visible.height, below: 4 * visible.height) { retire(index) }
        for index in frames.indices where live[index] == nil && intersects(index, above: 1.5 * visible.height, below: 2.5 * visible.height) { show(index) }
    }

    private func show(_ index: Int) {
        let view = PageView(page: pages[index], pageSize: pageSizes[index], index: index, store: store, objectStore: objectStore)
        view.frame = frames[index]
        view.ink.mode = mode
        view.setRenderZoom(renderZoom)
        contentView.addSubview(view)
        contentView.sendSubviewToBack(view) // pages never overlap each other, but this keeps overlays (search highlight) on top
        live[index] = view
        loadPreview(for: index, into: view)
    }

    private func retire(_ index: Int) {
        live[index]?.removeFromSuperview()
        live[index] = nil
    }

    private func loadPreview(for index: Int, into view: PageView) {
        let key = NSNumber(value: index)
        if let cached = previews.object(forKey: key) {
            view.setPreview(cached)
            return
        }
        let page = pages[index]
        let size = pageSizes[index]
        previewQueue.async { [weak self, weak view] in
            let image = PDFRenderer.preview(of: page, pageSize: size)
            DispatchQueue.main.async {
                self?.previews.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
                view?.setPreview(image)
            }
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutVisiblePages()
        updateCurrentPage()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        layoutVisiblePages()
        updateCurrentPage()
    }

    // The container was only scaled while pinching, so PDF tiles are soft; redraw them for the new zoom.
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderZoom = scale
        live.values.forEach { $0.setRenderZoom(scale) }
    }

    // MARK: Errors

    private func reportSaveFailure(_ error: Error) {
        guard !saveAlertShown, presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        saveAlertShown = true
        let alert = UIAlertController(title: "필기를 저장하지 못했습니다", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak self] _ in self?.saveAlertShown = false })
        present(alert, animated: true)
    }

    // MARK: Tools (PencilKit's palette is only the UI; the engine draws)

    // Widths from the palette are in PencilKit's units, scaled here to page points. Tune by feel.
    private func apply(_ tool: PKTool) {
        currentTool = tool
        switch tool {
        case let ink as PKInkingTool:
            var color = Self.rgba(ink.color)
            if ink.inkType == .marker {
                color[3] *= 0.35
                mode = .draw(kind: .highlighter, color: color, width: max(Float(ink.width) * 0.75, 1))
            } else {
                mode = .draw(kind: .pen, color: color, width: max(Float(ink.width) * 0.5, 0.5))
            }
        case let eraser as PKEraserTool:
            var radius = CGFloat(AppSettings.eraserSize)
            if eraser.eraserType == .fixedWidthBitmap { radius = min(max(eraser.width / 2, 4), 60) } // the palette's own size
            switch AppSettings.eraserMode {
            case .partial: mode = .erase(partial: true, radius: radius)
            case .stroke: mode = .erase(partial: false, radius: radius)
            case .palette: mode = .erase(partial: eraser.eraserType != .vector, radius: radius)
            }
        case is PKLassoTool:
            mode = .lasso
        default:
            mode = .none // the ruler is not built yet
        }
        live.values.forEach { $0.ink.mode = mode }
    }

    // Pages are white paper, so colors are resolved for light mode.
    private static func rgba(_ color: UIColor) -> [Float] {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Float(r), Float(g), Float(b), Float(a)]
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        apply(toolPicker.selectedTool)
    }

    @available(iOS 18.0, *)
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        apply(toolPicker.selectedTool)
    }
}

struct PDFNoteView: UIViewControllerRepresentable {
    let folder: DocumentFolder
    let document: PDFDocument
    let pages: [CGPDFPage]
    let model: NoteViewModel

    func makeUIViewController(context: Context) -> PDFNoteViewController {
        PDFNoteViewController(folder: folder, document: document, pages: pages, model: model)
    }

    func updateUIViewController(_ controller: PDFNoteViewController, context: Context) {}
}
