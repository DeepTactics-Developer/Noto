import UIKit
import PDFKit
import PencilKit
import SwiftUI

// Continuous vertical PDF with one PencilKit canvas per page.
// PDFView sizes each overlay to its page, so strokes live in page space and survive rotation and zoom.
final class PDFNoteViewController: UIViewController, PDFPageOverlayViewProvider, PKToolPickerObserver, PKCanvasViewDelegate {
    private let folder: DocumentFolder
    private let document: PDFDocument
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private var drawings: [PDFPage: PKDrawing] = [:]
    private var dirty: Set<PDFPage> = []
    private var saveTimer: Timer?
    private var saveAlertShown = false
    private var currentTool: PKTool = PKInkingTool(.pen, color: .black, width: 4)

    // The controller is the picker's responder, so the palette stays up while canvases come and go.
    override var canBecomeFirstResponder: Bool { true }

    init(folder: DocumentFolder, document: PDFDocument) {
        self.folder = folder
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.frame = view.bounds
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.backgroundColor = .systemGray5
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.usePageViewController(false)
        pdfView.isInMarkupMode = true // lets touches reach the overlay canvases instead of PDFView's own gestures
        pdfView.pageOverlayViewProvider = self // must be set before the document
        pdfView.document = document
        view.addSubview(pdfView)

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

    // MARK: Storage

    private func drawing(for page: PDFPage) -> PKDrawing {
        if let cached = drawings[page] { return cached }
        let url = folder.drawingURL(page: document.index(for: page))
        var loaded = PKDrawing()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? PKDrawing(data: data) {
                loaded = decoded
            } else {
                // Keep an unreadable file instead of overwriting it with the next save.
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("corrupt"))
            }
        }
        drawings[page] = loaded
        return loaded
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.flush() }
    }

    @objc private func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        for page in dirty {
            let drawing = canvases[page]?.drawing ?? drawings[page] ?? PKDrawing()
            do {
                try drawing.dataRepresentation().write(to: folder.drawingURL(page: document.index(for: page)), options: .atomic)
                dirty.remove(page)
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

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let page = canvases.first(where: { $0.value === canvasView })?.key else { return }
        drawings[page] = canvasView.drawing
        dirty.insert(page)
        scheduleSave()
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let existing = canvases[page] { return existing }
        let canvas = PKCanvasView()
        // experiment: PDFView scales the overlay up, which blurs ink; ask for a denser backing store first
        canvas.contentScaleFactor = min(pdfView.traitCollection.displayScale * pdfView.scaleFactor, 4)
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light // ink is drawn on white paper in both modes
        canvas.tool = currentTool
        canvas.drawing = drawing(for: page)
        canvas.delegate = self
        canvases[page] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        // PDFKit turns interaction off on its page views, which would swallow touches meant for the canvas.
        overlayView.superview?.isUserInteractionEnabled = true
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        drawings[page] = canvas.drawing
        flush()
        canvases[page] = nil
    }

    // MARK: PKToolPickerObserver

    private func apply(_ tool: PKTool) {
        currentTool = tool
        canvases.values.forEach { $0.tool = tool }
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

    func makeUIViewController(context: Context) -> PDFNoteViewController {
        PDFNoteViewController(folder: folder, document: document)
    }

    func updateUIViewController(_ controller: PDFNoteViewController, context: Context) {}
}
