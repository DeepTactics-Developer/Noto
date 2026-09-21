import SwiftUI
import PencilKit

// Step 0: bare PencilKit canvas, only to check the build pipeline and pen feel on device.
struct CanvasScreen: UIViewRepresentable {
    final class Coordinator { var picker: PKToolPicker? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .systemBackground
        let picker = PKToolPicker()
        picker.addObserver(canvas)
        context.coordinator.picker = picker
        DispatchQueue.main.async {
            picker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
