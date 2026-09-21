import UIKit

enum PDFRenderer {
    // Tiles and previews draw on background threads and CGPDFPage drawing is not documented as thread safe.
    private static let lock = NSLock()

    // Draws the page to fill `size` in a UIKit-style (top-left origin) context.
    static func draw(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        // CGPDFPage.getDrawingTransform never scales a page up, only down, so it is asked to map the page at its
        // natural size (which gives rotation and box origin) and the scaling to `size` is done here.
        let box = page.getBoxRect(.cropBox)
        let natural = page.rotationAngle % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
        guard natural.width > 0, natural.height > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: size.width / natural.width, y: size.height / natural.height)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    // Low-resolution stand-in shown while sharp tiles are still being drawn.
    static func preview(of page: CGPDFPage, pageSize: CGSize) -> UIImage {
        let width: CGFloat = 1000
        let size = CGSize(width: width, height: (width * pageSize.height / pageSize.width).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(page, in: context.cgContext, size: size)
        }
    }
}

final class NoFadeTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

// Draws one PDF page at whatever size it is laid out at, tile by tile, so it stays sharp at any zoom.
// Never change contentScaleFactor of a tile view that has already drawn: its cached tiles then show at the
// wrong size. PageView swaps in a fresh tile view instead (as Apple's ZoomingPDFViewer sample does).
final class PDFTileView: UIView {
    private let page: CGPDFPage

    // Pixels per point the tiles are drawn at; applied once, before the first tile is drawn.
    var renderScale: CGFloat? {
        didSet { applyRenderScale() }
    }

    override class var layerClass: AnyClass { NoFadeTiledLayer.self }

    init(page: CGPDFPage) {
        self.page = page
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        (layer as? CATiledLayer)?.tileSize = CGSize(width: 512, height: 512)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyRenderScale()
    }

    private func applyRenderScale() {
        guard let scale = renderScale, window != nil, contentScaleFactor != scale else { return }
        contentScaleFactor = scale
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        PDFRenderer.draw(page, in: ctx, size: layer.bounds.size)
    }
}

// One page, bottom to top: low-res preview, sharp PDF tiles, ink.
final class PageView: UIView {
    let ink: InkPageView
    private let pdfPage: CGPDFPage
    private let preview = UIImageView()
    private var tile: PDFTileView
    private var backTile: PDFTileView? // the previous tiles, kept underneath while the new ones draw
    private var screenScale: CGFloat = 0
    private var renderZoom: CGFloat = 1

    private var tileScale: CGFloat { min(screenScale * renderZoom, 8) }

    init(page: CGPDFPage, pageSize: CGSize, index: Int, store: InkStore) {
        pdfPage = page
        tile = PDFTileView(page: page)
        ink = InkPageView(page: index, pageSize: pageSize, store: store)
        super.init(frame: .zero)
        backgroundColor = .white
        preview.contentMode = .scaleToFill
        addSubview(preview)
        addSubview(tile)
        addSubview(ink)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setPreview(_ image: UIImage) {
        preview.image = image
    }

    // Tiles are drawn at screen resolution times the zoom, so zooming in stays sharp. Called when a pinch ends.
    func setRenderZoom(_ zoom: CGFloat) {
        guard zoom != renderZoom else { return }
        renderZoom = zoom
        guard screenScale > 0, tile.renderScale != tileScale else { return }
        let old = tile
        backTile?.removeFromSuperview()
        backTile = old
        let fresh = PDFTileView(page: pdfPage)
        fresh.renderScale = tileScale
        fresh.frame = bounds
        insertSubview(fresh, aboveSubview: old)
        tile = fresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak old] in
            guard let old, self?.backTile === old else { return }
            old.removeFromSuperview()
            self?.backTile = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scale = window?.screen.scale, screenScale == 0 else { return }
        screenScale = scale
        tile.renderScale = tileScale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        backTile?.frame = bounds
        tile.frame = bounds
        ink.frame = bounds
    }
}
