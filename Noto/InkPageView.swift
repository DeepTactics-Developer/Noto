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
// Hold the pen still for half a second while drawing and a rough line or loop snaps to a straight line or an ellipse.
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

    private var holdTimer: Timer?
    private var holdAnchor = CGPoint.zero // where the pen was last seen moving, in window coordinates
    private var holdSince: TimeInterval = 0
    private var holdTried = false
    private var snapped: RecognizedShape?
    private let holdDelay: TimeInterval = 0.5
    private let holdSlop: CGFloat = 3 // screen points the pen may wander and still count as held

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

    // Screen points per page point, including any zoom applied by ancestor views.
    private var screenPerPagePoint: CGFloat {
        let origin = convert(CGPoint.zero, to: nil)
        let unit = convert(CGPoint(x: 1, y: 0), to: nil)
        return max(hypot(unit.x - origin.x, unit.y - origin.y) * scale, 0.01)
    }

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
            snapped = nil
            holdAnchor = touch.preciseLocation(in: nil)
            holdSince = touch.timestamp
            holdTried = false
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHold() }
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
        guard wetLayer != nil else {
            (event?.coalescedTouches(for: touch) ?? [touch]).forEach { erase(at: pagePoint(of: $0)) }
            return
        }
        let screen = touch.preciseLocation(in: nil)
        let moved = hypot(screen.x - holdAnchor.x, screen.y - holdAnchor.y) > holdSlop
        if moved {
            holdAnchor = screen
            holdSince = touch.timestamp
            holdTried = false
        }
        switch snapped {
        case .line(let start, _)? where moved:
            // A snapped line keeps following the pen, and clicks onto horizontal or vertical.
            snapped = .line(from: start, to: axisSnapped(from: start, to: pagePoint(of: touch)))
            showSnapped()
        case .some:
            break // a snapped ellipse stays as it is
        case nil:
            (event?.coalescedTouches(for: touch) ?? [touch]).forEach(append)
            updateWet(touch, event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        if wetLayer != nil, snapped == nil { append(touch) }
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
        holdTimer?.invalidate()
        holdTimer = nil
        if let layer = wetLayer {
            wetLayer = nil
            let points = snapped.map(shapePoints) ?? wetPoints
            if commit, !points.isEmpty, let style = wetStyle {
                let stroke = InkStroke(kind: style.kind, color: style.color, width: style.width, points: points)
                withoutAnimation { layer.path = InkGeometry.path(stroke.points) }
                layers[stroke.id] = layer // the live layer becomes the stroke's layer, so sync() keeps it
                store.add(stroke, on: page)
            } else {
                withoutAnimation { layer.removeFromSuperlayer() }
            }
            wetPoints = []
            wetStyle = nil
            snapped = nil
        } else if !erased.isEmpty {
            store.commitErase(erased, on: page)
            erased = []
        }
    }

    // MARK: Hold to shape

    private func checkHold() {
        guard wetLayer != nil, snapped == nil, !holdTried,
              ProcessInfo.processInfo.systemUptime - holdSince >= holdDelay else { return }
        holdTried = true // look again only after the pen has moved
        guard var shape = ShapeRecognizer.recognize(wetPoints.map(\.cg)) else { return }
        if case .line(let from, let to) = shape { shape = .line(from: from, to: axisSnapped(from: from, to: to)) }
        snapped = shape
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showSnapped()
    }

    // Within 3 degrees of horizontal or vertical the line is made exactly so.
    private func axisSnapped(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 0 else { return b }
        let angle = atan2(dy, dx)
        let nearest = (angle / (.pi / 2)).rounded() * (.pi / 2)
        guard abs(angle - nearest) <= 3 * .pi / 180 else { return b }
        return CGPoint(x: a.x + length * cos(nearest), y: a.y + length * sin(nearest))
    }

    private func showSnapped() {
        guard let shape = snapped else { return }
        let path = CGMutablePath()
        switch shape {
        case .line(let from, let to):
            path.move(to: from)
            path.addLine(to: to)
        case .ellipse(let center, let rx, let ry, let angle):
            path.addEllipse(in: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry),
                            transform: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        }
        withoutAnimation { wetLayer?.path = path }
    }

    // The points stored for a snapped shape.
    private func shapePoints(_ shape: RecognizedShape) -> [InkPoint] {
        let force = wetPoints.last?.force ?? 0.5
        let end = wetPoints.last?.time ?? 0
        func point(_ p: CGPoint, _ time: Float) -> InkPoint { InkPoint(x: Float(p.x), y: Float(p.y), force: force, time: time) }
        switch shape {
        case .line(let from, let to):
            return [point(from, 0), point(to, end)]
        case .ellipse(let center, let rx, let ry, let angle):
            let steps = 72
            return (0...steps).map { i in
                let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                let p = CGPoint(x: center.x + x * cos(angle) - y * sin(angle), y: center.y + x * sin(angle) + y * cos(angle))
                return point(p, end * Float(i) / Float(steps))
            }
        }
    }

    // MARK: Eraser

    // Whole-stroke eraser: every stroke the eraser circle touches goes.
    private func erase(at point: CGPoint) {
        let radius = 10 / screenPerPagePoint // 10 screen points, whatever the zoom
        let ids = Set(store.strokes(on: page).filter { InkGeometry.hit($0, at: point, radius: radius) }.map(\.id))
        guard !ids.isEmpty else { return }
        erased += store.erase(ids, on: page)
    }
}
