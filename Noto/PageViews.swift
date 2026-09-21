import UIKit

enum PDFRenderer {
    // Tiles and previews draw on background threads and CGPDFPage drawing is not documented as thread safe.
    private static let lock = NSLock()

    // Draws the page to fill `size` in a UIKit-style (top-left origin) context.
    static func draw(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        lock.lock()
        defer { lock.unlock() }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
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
final class PDFTileView: UIView {
    private let page: CGPDFPage

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
    private let preview = UIImageView()
    private let tile: PDFTileView
    private var snapshot: UIView?
    private var screenScale: CGFloat = 0
    private var renderZoom: CGFloat = 1

    init(page: CGPDFPage, pageSize: CGSize, index: Int, store: InkStore) {
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
        applyTileScale(animated: true)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scale = window?.screen.scale else { return }
        screenScale = scale
        applyTileScale(animated: false)
    }

    private func applyTileScale(animated: Bool) {
        guard screenScale > 0 else { return }
        let target = min(screenScale * renderZoom, 8)
        guard target != tile.contentScaleFactor else { return }
        if animated { freezeTile() }
        tile.contentScaleFactor = target
        tile.setNeedsDisplay()
    }

    // Keeps a picture of the current tiles underneath until the freshly drawn ones cover it, so the page
    // never goes blank while it redraws.
    private func freezeTile() {
        snapshot?.removeFromSuperview()
        snapshot = nil
        guard bounds.width > 0, let picture = tile.snapshotView(afterScreenUpdates: false) else { return }
        insertSubview(picture, belowSubview: tile)
        snapshot = picture
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak picture] in
            guard let picture, self?.snapshot === picture else { return }
            picture.removeFromSuperview()
            self?.snapshot = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        snapshot?.frame = bounds
        tile.frame = bounds
        ink.frame = bounds
    }
}
