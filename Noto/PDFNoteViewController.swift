import UIKit
import PDFKit
import PencilKit
import SwiftUI

// Own page viewer: a vertical stack of pages inside a UIScrollView.
// Pinch zoom is handled here, not by the scroll view: while the fingers are down the page container is just
// scaled (fast, briefly soft); on release the pages are laid out at the new size and the PDF tiles redraw sharp.
// Ink is vector, so it stays sharp throughout. PencilKit is only used for its tool palette.
final class PDFNoteViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate, PKToolPickerObserver {
    private struct PinchState {
        var focal: CGPoint // point of the content under the fingers when the pinch began
        var screen: CGPoint // where the fingers are now, in this controller's view
        var scale = CGFloat(1) // zoom change since the pinch began
    }

    private let folder: DocumentFolder
    private let document: PDFDocument // keeps the CGPDFPages alive
    private let pages: [CGPDFPage]
    private let pageSizes: [CGSize] // displayed size in PDF points
    private let store: InkStore

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let toolPicker = PKToolPicker()

    private var frames: [CGRect] = []
    private var live: [Int: PageView] = [:]
    private var zoom: CGFloat = 1
    private var laidOutWidth: CGFloat = 0
    private var pinch: PinchState?
    private let maxZoom: CGFloat = 4
    private let margin: CGFloat = 12 // page gap and side margin at zoom 1; scales with zoom

    private var mode: InkMode = .none
    private var saveAlertShown = false

    private let previews = NSCache<NSNumber, UIImage>()
    private let previewQueue = DispatchQueue(label: "noto.preview", qos: .userInitiated)

    // The controller is the picker's responder, so the palette stays up while pages come and go.
    override var canBecomeFirstResponder: Bool { true }

    init(folder: DocumentFolder, document: PDFDocument, pages: [CGPDFPage]) {
        self.folder = folder
        self.document = document
        self.pages = pages
        self.store = InkStore(folder: folder)
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
        scrollView.panGestureRecognizer.allowedTouchTypes = fingers // the pencil only draws
        contentView.layer.anchorPoint = .zero // scale about the top-left corner while pinching
        scrollView.addSubview(contentView)
        view.addSubview(scrollView)

        let pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchRecognizer.allowedTouchTypes = fingers
        pinchRecognizer.delegate = self
        scrollView.addGestureRecognizer(pinchRecognizer)

        apply(toolPicker.selectedTool)
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

    @objc private func flush() {
        store.flush()
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width
        guard width > 0, width != laidOutWidth, pinch == nil else { return }
        let anchor = anchorAtTop()
        let oldWidth = scrollView.contentSize.width
        let oldX = scrollView.contentOffset.x
        laidOutWidth = width
        relayout()
        if let anchor {
            let frame = frames[anchor.index]
            let x = oldWidth > 0 ? oldX / oldWidth * scrollView.contentSize.width : 0
            scrollView.contentOffset = clamped(CGPoint(x: x, y: frame.minY + anchor.fraction * frame.height))
        }
        layoutVisiblePages()
    }

    // Layout at zoom z is exactly the layout at zoom 1 scaled by z, so committing a pinch causes no jump.
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
        let view = PageView(page: pages[index], pageSize: pageSizes[index], index: index, store: store)
        view.frame = frames[index]
        view.ink.mode = mode
        contentView.addSubview(view)
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

    // MARK: Scrolling and pinching

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard pinch == nil else { return }
        layoutVisiblePages()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinch = PinchState(focal: gesture.location(in: contentView), screen: gesture.location(in: view))
            scrollView.panGestureRecognizer.isEnabled = false // the pinch moves the content itself
        case .changed:
            guard var state = pinch else { return }
            state.scale = min(max(zoom * gesture.scale, 1), maxZoom) / zoom
            state.screen = gesture.location(in: view)
            pinch = state
            let base = contentView.bounds.size
            contentView.transform = CGAffineTransform(scaleX: state.scale, y: state.scale)
            scrollView.contentSize = CGSize(width: base.width * state.scale, height: base.height * state.scale)
            scrollView.contentOffset = clamped(offset(for: state))
        case .ended, .cancelled, .failed:
            scrollView.panGestureRecognizer.isEnabled = true
            commitPinch()
        default:
            break
        }
    }

    // Keeps the point that was under the fingers under the fingers.
    private func offset(for state: PinchState) -> CGPoint {
        CGPoint(x: state.focal.x * state.scale - state.screen.x, y: state.focal.y * state.scale - state.screen.y)
    }

    private func commitPinch() {
        guard let state = pinch else { return }
        pinch = nil
        guard abs(state.scale - 1) > 0.005 else {
            contentView.transform = .identity
            scrollView.contentSize = contentView.bounds.size
            return
        }
        live.values.forEach { $0.freezeTile() }
        contentView.transform = .identity
        zoom *= state.scale
        relayout()
        scrollView.contentOffset = clamped(offset(for: state))
        layoutVisiblePages()
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
        switch tool {
        case let ink as PKInkingTool:
            var color = Self.rgba(ink.color)
            if ink.inkType == .marker {
                color[3] *= 0.35
                mode = .draw(kind: .highlighter, color: color, width: max(Float(ink.width) * 0.75, 1))
            } else {
                mode = .draw(kind: .pen, color: color, width: max(Float(ink.width) * 0.5, 0.5))
            }
        case is PKEraserTool:
            mode = .erase
        default:
            mode = .none // lasso and ruler are not built yet
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

    func makeUIViewController(context: Context) -> PDFNoteViewController {
        PDFNoteViewController(folder: folder, document: document, pages: pages)
    }

    func updateUIViewController(_ controller: PDFNoteViewController, context: Context) {}
}
