import UIKit
import PencilKit

final class NoFadeTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

// Draws one PDF page at whatever size it is laid out at, tile by tile, so it stays sharp at any zoom.
final class PDFTileView: UIView {
    // Tiles draw on background threads and CGPDFPage drawing is not documented as thread safe.
    private static let renderLock = NSLock()
    private let page: CGPDFPage

    override class var layerClass: AnyClass { NoFadeTiledLayer.self }

    init(page: CGPDFPage) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .white
        contentMode = .redraw
        (layer as? CATiledLayer)?.tileSize = CGSize(width: 512, height: 512)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        let size = layer.bounds.size
        Self.renderLock.lock()
        defer { Self.renderLock.unlock() }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}

// One page: PDF underneath, PencilKit canvas on top.
// The canvas is zoomed to the page's display width (as in Apple's PencilKit sample), so strokes are
// re-rendered at the real size instead of being stretched, and drawing coordinates stay in page points.
final class PageView: UIView {
    let canvas = PKCanvasView()
    private let tile: PDFTileView
    private let pageSize: CGSize
    private var fittedWidth: CGFloat = 0

    init(page: CGPDFPage, pageSize: CGSize) {
        tile = PDFTileView(page: page)
        self.pageSize = pageSize
        super.init(frame: .zero)
        addSubview(tile)
        addSubview(canvas)
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.overrideUserInterfaceStyle = .light // ink is drawn on white paper in both modes
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        tile.frame = bounds
        canvas.frame = bounds
        guard bounds.width > 0, bounds.width != fittedWidth else { return }
        fittedWidth = bounds.width
        let scale = bounds.width / pageSize.width
        canvas.minimumZoomScale = min(canvas.minimumZoomScale, scale)
        canvas.maximumZoomScale = max(canvas.maximumZoomScale, scale)
        canvas.zoomScale = scale
        canvas.minimumZoomScale = scale
        canvas.maximumZoomScale = scale
        canvas.contentSize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        canvas.contentOffset = .zero
    }
}
