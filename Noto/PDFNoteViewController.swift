import UIKit
import PDFKit
import PencilKit
import SwiftUI

// The canvases' delegate must not be the view controller: PKCanvasView is a UIScrollView and asks its delegate
// for viewForZooming, which must stay PencilKit's own and not the page container below.
private final class InkDelegate: NSObject, PKCanvasViewDelegate {
    var onChange: ((PKCanvasView) -> Void)?

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onChange?(canvasView)
    }
}

// Own page viewer: a vertical stack of pages inside a UIScrollView.
// Pinch zoom is baked in when the gesture ends (pages are re-laid-out at the new size with zoomScale back at 1),
// so both the PDF tiles and the ink are rendered at the real display size rather than scaled up.
final class PDFNoteViewController: UIViewController, UIScrollViewDelegate, PKToolPickerObserver {
    private let folder: DocumentFolder
    private let document: PDFDocument // keeps the CGPDFPages alive
    private let pages: [CGPDFPage]
    private let pageSizes: [CGSize] // displayed size in PDF points

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let toolPicker = PKToolPicker()
    private let inkDelegate = InkDelegate()

    private var frames: [CGRect] = []
    private var live: [Int: PageView] = [:]
    private var zoom: CGFloat = 1
    private var laidOutWidth: CGFloat = 0
    private var isBaking = false
    private let maxZoom: CGFloat = 4
    private let margin: CGFloat = 12 // page gap and side margin at zoom 1; scales with zoom

    private let previews = NSCache<NSNumber, UIImage>()
    private let previewQueue = DispatchQueue(label: "noto.preview", qos: .userInitiated)

    private var drawings: [Int: PKDrawing] = [:]
    private var dirty: Set<Int> = []
    private var saveTimer: Timer?
    private var saveAlertShown = false
    private var currentTool: PKTool = PKInkingTool(.pen, color: .black, width: 4)

    // The controller is the picker's responder, so the palette stays up while pages come and go.
    override var canBecomeFirstResponder: Bool { true }

    init(folder: DocumentFolder, document: PDFDocument, pages: [CGPDFPage]) {
        self.folder = folder
        self.document = document
        self.pages = pages
        self.pageSizes = pages.map { page in
            let box = page.getBoxRect(.cropBox)
            let rotated = page.rotationAngle % 180 != 0
            let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            return size.width > 0 && size.height > 0 ? size : CGSize(width: 612, height: 792)
        }
        super.init(nibName: nil, bundle: nil)
        previews.totalCostLimit = 120_000_000
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
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.panGestureRecognizer.allowedTouchTypes = fingers // the pencil only draws
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = fingers
        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        inkDelegate.onChange = { [weak self] canvas in self?.inkChanged(canvas) }
        currentTool = toolPicker.selectedTool
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)
        NotificationCenter.default.addObserver(self, selector: #selector(flush), name: UIApplication.willResignActiveNotification, object: nil)
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

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0, width != laidOutWidth else { return }
        let anchor = anchorAtTop()
        let oldWidth = scrollView.contentSize.width
        let oldX = scrollView.contentOffset.x
        laidOutWidth = width
        relayout()
        updateZoomBounds()
        if let anchor {
            let frame = frames[anchor.index]
            let x = oldWidth > 0 ? oldX / oldWidth * scrollView.contentSize.width : 0
            scrollView.contentOffset = clamped(CGPoint(x: x, y: frame.minY + anchor.fraction * frame.height))
        }
        layoutVisiblePages()
    }

    // Layout at zoom z is exactly the layout at zoom 1 scaled by z, so baking a pinch causes no visible jump.
    private func relayout() {
        let width = scrollView.bounds.width
        let gap = margin * zoom
        let pageWidth = max(width - 2 * margin, 1) * zoom
        var y = gap
        frames = pageSizes.map { size in
            let frame = CGRect(x: gap, y: y, width: pageWidth, height: pageWidth * size.height / size.width)
            y = frame.maxY + gap
            return frame
        }
        let content = CGSize(width: width * zoom, height: y)
        contentView.frame = CGRect(origin: .zero, size: content)
        scrollView.contentSize = content
        for (index, view) in live { view.frame = frames[index] }
    }

    private func updateZoomBounds() {
        scrollView.minimumZoomScale = 1 / zoom
        scrollView.maximumZoomScale = maxZoom / zoom
    }

    private func clamped(_ offset: CGPoint) -> CGPoint {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        return CGPoint(x: max(0, min(offset.x, max(0, content.width - bounds.width))),
                       y: max(0, min(offset.y, max(0, content.height - bounds.height))))
    }

    private func anchorAtTop() -> (index: Int, fraction: CGFloat)? {
        let y = scrollView.contentOffset.y
        guard let index = frames.lastIndex(where: { $0.minY <= y }) ?? frames.indices.first else { return nil }
        let frame = frames[index]
        return (index, frame.height > 0 ? (y - frame.minY) / frame.height : 0)
    }

    // Pages within a couple of screens of the viewport get views; they are only released once well outside
    // that, so scrolling back and forth does not rebuild them.
    private func layoutVisiblePages() {
        guard !frames.isEmpty else { return }
        let y = scrollView.contentOffset.y
        let height = scrollView.bounds.height
        func intersects(_ index: Int, above: CGFloat, below: CGFloat) -> Bool {
            frames[index].maxY >= y - above && frames[index].minY <= y + height + below
        }
        for index in Array(live.keys) where !intersects(index, above: 3 * height, below: 4 * height) { retire(index) }
        for index in frames.indices where live[index] == nil && intersects(index, above: 1.5 * height, below: 2.5 * height) { show(index) }
    }

    private func show(_ index: Int) {
        let view = PageView(page: pages[index], pageSize: pageSizes[index])
        view.frame = frames[index]
        view.canvas.tool = currentTool
        view.canvas.drawing = drawing(for: index)
        view.canvas.delegate = inkDelegate
        contentView.addSubview(view)
        live[index] = view
        loadPreview(for: index, into: view)
    }

    private func retire(_ index: Int) {
        guard let view = live[index] else { return }
        drawings[index] = view.canvas.drawing
        view.removeFromSuperview()
        live[index] = nil
        flush()
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === self.scrollView ? contentView : nil
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === self.scrollView, !isBaking, scrollView.zoomScale == 1 else { return }
        layoutVisiblePages()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === self.scrollView, abs(scale - 1) > 0.01 else { return }
        let offset = scrollView.contentOffset
        isBaking = true
        zoom = min(max(zoom * scale, 1), maxZoom)
        scrollView.zoomScale = 1
        relayout()
        scrollView.contentOffset = clamped(offset)
        updateZoomBounds()
        isBaking = false
        layoutVisiblePages()
    }

    // MARK: Storage

    private func drawing(for index: Int) -> PKDrawing {
        if let cached = drawings[index] { return cached }
        let url = folder.drawingURL(page: index)
        var loaded = PKDrawing()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? PKDrawing(data: data) {
                loaded = decoded
            } else {
                // Keep an unreadable file instead of overwriting it with the next save.
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            }
        }
        drawings[index] = loaded
        return loaded
    }

    private func inkChanged(_ canvas: PKCanvasView) {
        guard let index = live.first(where: { $0.value.canvas === canvas })?.key else { return }
        drawings[index] = canvas.drawing
        dirty.insert(index)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.flush() }
    }

    @objc private func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        for index in dirty {
            let drawing = live[index]?.canvas.drawing ?? drawings[index] ?? PKDrawing()
            do {
                try drawing.dataRepresentation().write(to: folder.drawingURL(page: index), options: .atomic)
                dirty.remove(index)
            } catch {
                reportSaveFailure(error) // stays dirty, so the next flush retries
                return
            }
        }
    }

    private func reportSaveFailure(_ error: Error) {
        guard !saveAlertShown, presentedViewController == nil, viewIfLoaded?.window != nil else { return }
        saveAlertShown = true
        let alert = UIAlertController(title: "필기를 저장하지 못했습니다", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .default) { [weak self] _ in self?.saveAlertShown = false })
        present(alert, animated: true)
    }

    // MARK: PKToolPickerObserver

    private func apply(_ tool: PKTool) {
        currentTool = tool
        live.values.forEach { $0.canvas.tool = tool }
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

    func makeUIViewController(context: Context) -> PDFNoteViewController {
        PDFNoteViewController(folder: folder, document: document, pages: pages)
    }

    func updateUIViewController(_ controller: PDFNoteViewController, context: Context) {}
}
