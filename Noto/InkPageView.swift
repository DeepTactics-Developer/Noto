import UIKit

enum InkMode {
    case none
    case draw(kind: InkKind, color: [Float], width: Float)
    case erase
}

// Shape layers animate every property change by default, which would make strokes fade and slide.
private final class NoActionShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

// One page's ink: a vector layer per stroke, drawn in page coordinates under a scale transform, so it is
// sharp at any zoom. The stroke being written is just another layer; on pen-up it stays as it is and becomes
// the committed stroke, so nothing redraws or flickers at that moment. Only the pencil draws.
final class InkPageView: UIView {
    var mode: InkMode = .none

    private let page: Int
    private let pageSize: CGSize
    private let store: InkStore
    private let container = CALayer()
    private var layers: [UUID: NoActionShapeLayer] = [:]
    private var scale: CGFloat = 0

    private var activeTouch: UITouch?
    private var wetLayer: NoActionShapeLayer?
    private var wetPoints: [InkPoint] = []
    private var wetStyle: (kind: InkKind, color: [Float], width: Float)?
    private var wetStart: TimeInterval = 0
    private var erased: [InkStroke] = []

    private let minStep: CGFloat = 0.3 // page points; closer samples are dropped

    init(page: Int, pageSize: CGSize, store: InkStore) {
        self.page = page
        self.pageSize = pageSize
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
        container.anchorPoint = .zero
        container.bounds = CGRect(origin: .zero, size: pageSize)
        container.position = .zero
        layer.addSublayer(container)
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newScale = bounds.width / pageSize.width
        guard newScale > 0, newScale != scale else { return }
        scale = newScale
        withoutAnimation { container.sublayerTransform = CATransform3DMakeScale(newScale, newScale, 1) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func makeLayer(color: [Float], width: Float) -> NoActionShapeLayer {
        let layer = NoActionShapeLayer()
        layer.frame = CGRect(origin: .zero, size: pageSize)
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.lineWidth = CGFloat(width)
        layer.strokeColor = InkStroke.uiColor(color).cgColor
        return layer
    }

    // Brings the layers in line with the store: adds missing strokes, drops erased ones.
    func sync() {
        withoutAnimation {
            let strokes = store.strokes(on: page)
            let ids = Set(strokes.map(\.id))
            for (id, layer) in Array(layers) where !ids.contains(id) {
                layer.removeFromSuperlayer()
                layers[id] = nil
            }
            for stroke in strokes where layers[stroke.id] == nil {
                let layer = makeLayer(color: stroke.color, width: stroke.width)
                layer.path = InkGeometry.path(stroke.points)
                container.addSublayer(layer)
                layers[stroke.id] = layer
            }
        }
    }

    // MARK: Touches

    private func pagePoint(of touch: UITouch) -> CGPoint {
        let location = touch.preciseLocation(in: self)
        return CGPoint(x: location.x / max(scale, 0.01), y: location.y / max(scale, 0.01))
    }

    private func sample(_ touch: UITouch) -> InkPoint {
        let p = pagePoint(of: touch)
        let force = touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0.5
        return InkPoint(x: Float(p.x), y: Float(p.y), force: Float(force), time: Float(touch.timestamp - wetStart))
    }

    private func append(_ touch: UITouch) {
        let point = sample(touch)
        if let last = wetPoints.last, hypot(CGFloat(point.x - last.x), CGFloat(point.y - last.y)) < minStep { return }
        wetPoints.append(point)
    }

    // The predicted samples only extend the live path, they are never stored.
    private func updateWet(_ touch: UITouch, _ event: UIEvent?) {
        let predicted = (event?.predictedTouches(for: touch) ?? []).map(sample)
        withoutAnimation { wetLayer?.path = InkGeometry.path(wetPoints + predicted) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) else {
            super.touchesBegan(touches, with: event)
            return
        }
        switch mode {
        case .none:
            return
        case .draw(let kind, let color, let width):
            activeTouch = touch
            wetStart = touch.timestamp
            wetPoints = []
            wetStyle = (kind, color, width)
            let layer = makeLayer(color: color, width: width)
            withoutAnimation { container.addSublayer(layer) }
            wetLayer = layer
            append(touch)
            updateWet(touch, nil)
        case .erase:
            activeTouch = touch
            erased = []
            erase(at: pagePoint(of: touch))
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesMoved(touches, with: event)
            return
        }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        if wetLayer != nil {
            samples.forEach(append)
            updateWet(touch, event)
        } else {
            samples.forEach { erase(at: pagePoint(of: $0)) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        if wetLayer != nil { append(touch) }
        finish(commit: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        finish(commit: false)
    }

    private func finish(commit: Bool) {
        activeTouch = nil
        if let layer = wetLayer {
            wetLayer = nil
            if commit, !wetPoints.isEmpty, let style = wetStyle {
                let stroke = InkStroke(kind: style.kind, color: style.color, width: style.width, points: wetPoints)
                withoutAnimation { layer.path = InkGeometry.path(stroke.points) }
                layers[stroke.id] = layer // the live layer becomes the stroke's layer, so sync() keeps it
                store.add(stroke, on: page)
            } else {
                withoutAnimation { layer.removeFromSuperlayer() }
            }
            wetPoints = []
            wetStyle = nil
        } else if !erased.isEmpty {
            store.commitErase(erased, on: page)
            erased = []
        }
    }

    // Whole-stroke eraser: every stroke the eraser circle touches goes.
    private func erase(at point: CGPoint) {
        let radius = 10 / max(scale, 0.01) // 10 screen points
        let ids = Set(store.strokes(on: page).filter { InkGeometry.hit($0, at: point, radius: radius) }.map(\.id))
        guard !ids.isEmpty else { return }
        erased += store.erase(ids, on: page)
    }
}
