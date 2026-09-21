import UIKit
import PDFKit
import PencilKit
import SwiftUI

// Continuous vertical PDF with one PencilKit canvas per page.
// PDFView sizes each overlay to its page, so strokes live in page space and survive rotation and zoom.
final class PDFNoteViewController: UIViewController, PDFPageOverlayViewProvider, PKToolPickerObserver {
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private var drawings: [PDFPage: PKDrawing] = [:]
    private var currentTool: PKTool = PKInkingTool(.pen, color: .black, width: 4)

    // The controller is the picker's responder, so the palette stays up while canvases come and go.
    override var canBecomeFirstResponder: Bool { true }

    init(document: PDFDocument) {
        super.init(nibName: nil, bundle: nil)
        pdfView.document = document
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
        pdfView.pageOverlayViewProvider = self
        view.addSubview(pdfView)

        currentTool = toolPicker.selectedTool
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        toolPicker.setVisible(false, forFirstResponder: self)
        resignFirstResponder()
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        if let existing = canvases[page] { return existing }
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light // ink is drawn on white paper in both modes
        canvas.tool = currentTool
        canvas.drawing = drawings[page] ?? PKDrawing()
        canvases[page] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        drawings[page] = canvas.drawing
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
    let document: PDFDocument

    func makeUIViewController(context: Context) -> PDFNoteViewController {
        PDFNoteViewController(document: document)
    }

    func updateUIViewController(_ controller: PDFNoteViewController, context: Context) {}
}
