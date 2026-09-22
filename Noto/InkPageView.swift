import UIKit

enum InkMode {
    case none
    case draw(kind: InkKind, color: [Float], width: Float)
    case erase(partial: Bool, radius: CGFloat) // radius in screen points
    case lasso
}

// Layers animate every property change by default, which would make strokes fade and slide.
private final class NoActionShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

private final class NoActionLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { NSNull() }
}

// The vector layers of one stroke: a group holding one shape layer per width run.
private final class StrokeLayers {
    let group = NoActionLayer()
    private var shapes: [NoActionShapeLayer] = []
    private let size: CGSize

    init(size: CGSize) {
        self.size = size
        group.frame = CGRect(origin: .zero, size: size)
    }

    func update(points: [InkPoint], color: [Float], width: Float, pressure: Float) {
        let runs = InkGeometry.runs(of: points, width: width, pressure: pressure)
        while shapes.count < runs.count {
            let shape = NoActionShapeLayer()
            shape.frame = CGRect(origin: .zero, size: size)
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.strokeColor = InkStroke.uiColor(color).cgColor
            group.addSublayer(shape)
            shapes.append(shape)
        }
        while shapes.count > runs.count { shapes.removeLast().removeFromSuperlayer() }
        for (shape, run) in zip(shapes, runs) {
            shape.lineWidth = run.width
            shape.path = InkGeometry.path(run.points)
        }
    }

    // A single custom path at a fixed width (snapped shapes).
    func show(path: CGPath, color: [Float], width: Float) {
        update(points: [InkPoint(x: 0, y: 0, force: 0, time: 0)], color: color, width: width, pressure: 0)
        shapes[0].path = path
    }
}

// One page's ink: a vector layer group per stroke, drawn in page coordinates under a scale transform, so it is
// sharp at any zoom. The stroke being written is just another group; on pen-up it stays as it is and becomes
// the committed stroke, so nothing redraws or flickers at that moment. Only the pencil draws.
//   pen: pressure changes the width (setting), and holding the pen still snaps a line or loop to a shape (setting)
//   eraser: partial or whole-stroke (setting)
//   lasso: draw a loop to select strokes, drag them, duplicate or delete them
final class InkPageView: UIView, UIEditMenuInteractionDelegate {
    var mode: InkMode = .none {
        didSet {
            if case .lasso = mode { return }
            clearSelection()
        }
    }

    private enum Gesture {
        case drawing
        case erasing(partial: Bool, radius: CGFloat)
        case lassoing
        case moving
    }

    private let page: Int
    private let pageSize: CGSize
    private let store: InkStore
    // A view (not a bare layer) so its scale transform rides along with UIKit's rotation animation.
    // Interactive (unlike ink's touch handling, which reads events straight off `self`), because the resize/
    // rotate handles below are real UIViews with their own gesture recognizers; PassthroughView keeps every
    // other point on the page falling through to this view's own touchesBegan, same as before.
    private let host = PassthroughView()
    private var layers: [UUID: StrokeLayers] = [:]
    private var scale: CGFloat = 0

    private var activeTouch: UITouch?
    private var gesture: Gesture?

    // drawing
    private var wet: StrokeLayers?
    private var wetPoints: [InkPoint] = []
    private var wetStyle: (kind: InkKind, color: [Float], width: Float, pressure: Float)?
    private var wetStart: TimeInterval = 0
    private let minStep: CGFloat = 0.3 // page points; closer samples are dropped

    // hold to shape
    private var holdTimer: Timer?
    private var holdAnchor = CGPoint.zero // where the pen was last seen moving, in window coordinates
    private var holdSince: TimeInterval = 0
    private var holdTried = false
    private var holdDelay: TimeInterval = 0.5
    private var snapped: RecognizedShape?
    private let holdSlop: CGFloat = 3 // screen points the pen may wander and still count as held

    // erasing
    private let eraserCursor = NoActionShapeLayer() // circle showing the eraser's reach while the pen is down
    private var eraseRemoved: [UUID: InkStroke] = [:] // strokes that existed before this eraser drag and are now gone
    private var eraseAdded: [UUID: InkStroke] = [:] // pieces created during this drag that are still there

    // lasso
    private let lassoLayer = NoActionShapeLayer()
    private let selectionLayer = NoActionShapeLayer()
    private var lassoPoints: [CGPoint] = []
    private var selection: Set<UUID> = []
    private var selectionBounds = CGRect.null
    private var dragStart = CGPoint.zero
    private var dragOffset = CGSize.zero
    private var menu: UIEditMenuInteraction?

    // resize (bottom-right handle, opposite corner as pivot) / rotate (handle above top-center, pivot = center;
    // snaps to right angles). Real UIViews with their own pan gesture, not raw touch hit-testing: UIKit's own
    // hit-testing is what decides whether a touch lands on a handle, instead of a hand-rolled distance check.
    private let resizeHandleView = SelectionHandleView()
    private let rotateHandleView = SelectionHandleView()
    private let rotateHandleLine = NoActionShapeLayer() // purely visual connector, not itself interactive
    private var transformPivot = CGPoint.zero
    private var transformStartVector = CGPoint.zero
    private var resizeHandleOrigin = CGPoint.zero // the handle's own position before the live preview moves it
    private var rotateHandleOrigin = CGPoint.zero
    private var pendingTransform = CGAffineTransform.identity
    private var rotationSnapped = false
    private let handleTouchTarget: CGFloat = 32 // screen points, constant regardless of zoom
    private let rotateHandleOffset: CGFloat = 28 // screen points, above the selection
    private let rotationSnapThreshold: CGFloat = 4 * .pi / 180 // within this many degrees of a right angle, it locks on

    init(page: Int, pageSize: CGSize, store: InkStore) {
        self.page = page
        self.pageSize = pageSize
        self.store = store
        super.init(frame: .zero)
        backgroundColor = .clear
        isMultipleTouchEnabled = false

        host.layer.anchorPoint = .zero
        host.frame = CGRect(origin: .zero, size: pageSize)
        addSubview(host)

        for (layer, filled) in [(lassoLayer, false), (selectionLayer, true)] {
            layer.frame = CGRect(origin: .zero, size: pageSize)
            layer.strokeColor = UIColor.systemBlue.cgColor
            layer.fillColor = filled ? UIColor.systemBlue.withAlphaComponent(0.06).cgColor : nil
            layer.lineWidth = 1.2
            layer.lineDashPattern = [5, 4]
            layer.lineJoin = .round
        }

        eraserCursor.frame = CGRect(origin: .zero, size: pageSize)
        eraserCursor.strokeColor = UIColor.systemGray.cgColor
        eraserCursor.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor

        rotateHandleLine.frame = CGRect(origin: .zero, size: pageSize)
        rotateHandleLine.strokeColor = UIColor.systemBlue.cgColor
        rotateHandleLine.lineWidth = 1

        resizeHandleView.isHidden = true
        rotateHandleView.isHidden = true
        resizeHandleView.onPan = { [weak self] gesture in self?.handleResizePan(gesture) }
        rotateHandleView.onPan = { [weak self] gesture in self?.handleRotatePan(gesture) }
        host.addSubview(resizeHandleView)
        host.addSubview(rotateHandleView)

        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        self.menu = menu

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let newScale = bounds.width / pageSize.width
        guard newScale > 0, newScale != scale else { return }
        let first = scale == 0
        scale = newScale
        let apply = { self.host.transform = CGAffineTransform(scaleX: newScale, y: newScale) }
        if first { UIView.performWithoutAnimation(apply) } else { apply() } // later changes animate with a rotation
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func makeLayers(for stroke: InkStroke) -> StrokeLayers {
        let strokeLayers = StrokeLayers(size: pageSize)
        strokeLayers.update(points: stroke.points, color: stroke.color, width: stroke.width, pressure: stroke.pressure)
        return strokeLayers
    }

    // Brings the layers in line with the store: adds missing strokes, drops erased ones.
    func sync() {
        withoutAnimation {
            let strokes = store.strokes(on: page)
            let ids = Set(strokes.map(\.id))
            for (id, strokeLayers) in Array(layers) where !ids.contains(id) {
                strokeLayers.group.removeFromSuperlayer()
                layers[id] = nil
            }
            for stroke in strokes where layers[stroke.id] == nil {
                let strokeLayers = makeLayers(for: stroke)
                host.layer.addSublayer(strokeLayers.group)
                layers[stroke.id] = strokeLayers
            }
            if !selection.isSubset(of: ids) {
                selection.formIntersection(ids)
                updateSelectionVisual()
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) else {
            super.touchesBegan(touches, with: event)
            return
        }
        menu?.dismissMenu()
        switch mode {
        case .none:
            return
        case .draw(let kind, let color, let width):
            activeTouch = touch
            gesture = .drawing
            beginStroke(touch, kind: kind, color: color, width: width)
        case .erase(let partial, let radius):
            activeTouch = touch
            gesture = .erasing(partial: partial, radius: radius)
            eraseRemoved = [:]
            eraseAdded = [:]
            erase(at: pagePoint(of: touch), partial: partial, radius: radius)
            moveEraserCursor(to: pagePoint(of: touch), radius: radius)
        case .lasso:
            activeTouch = touch
            let p = pagePoint(of: touch)
            // A touch that landed on a resize/rotate handle never reaches here at all — UIKit delivers it to
            // that handle's own view instead, before this method is even called.
            if !selection.isEmpty, selectionBounds.contains(p) {
                gesture = .moving
                dragStart = p
                dragOffset = .zero
            } else {
                clearSelection()
                gesture = .lassoing
                lassoPoints = [p]
                withoutAnimation { host.layer.addSublayer(lassoLayer) }
                updateLassoPath()
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch), let gesture else {
            super.touchesMoved(touches, with: event)
            return
        }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        switch gesture {
        case .drawing:
            moveStroke(touch, event: event, samples: samples)
        case .erasing(let partial, let radius):
            samples.forEach { erase(at: pagePoint(of: $0), partial: partial, radius: radius) }
            moveEraserCursor(to: pagePoint(of: touch), radius: radius)
        case .lassoing:
            lassoPoints += samples.map(pagePoint)
            updateLassoPath()
        case .moving:
            let p = pagePoint(of: touch)
            dragOffset = CGSize(width: p.x - dragStart.x, height: p.y - dragStart.y)
            applyDrag()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesEnded(touches, with: event)
            return
        }
        finish(touch, commit: true)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else {
            super.touchesCancelled(touches, with: event)
            return
        }
        finish(touch, commit: false)
    }

    private func finish(_ touch: UITouch, commit: Bool) {
        let ended = gesture
        activeTouch = nil
        gesture = nil
        switch ended {
        case .drawing?: endStroke(touch, commit: commit)
        case .erasing?: endErase()
        case .lassoing?: endLasso(commit: commit)
        case .moving?: endMove(commit: commit)
        case nil: break
        }
    }

    // MARK: Drawing

    private func beginStroke(_ touch: UITouch, kind: InkKind, color: [Float], width: Float) {
        wetStart = touch.timestamp
        wetPoints = []
        let pressure: Float = kind == .pen && AppSettings.pressure ? Float(AppSettings.pressureSensitivity) : 0
        wetStyle = (kind, color, width, pressure)
        snapped = nil
        if AppSettings.shapeSnap {
            holdDelay = AppSettings.holdDelay
            holdAnchor = touch.preciseLocation(in: nil)
            holdSince = touch.timestamp
            holdTried = false
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkHold() }
        }
        let fresh = StrokeLayers(size: pageSize)
        withoutAnimation { host.layer.addSublayer(fresh.group) }
        wet = fresh
        append(touch)
        updateWet(nil, nil)
    }

    private func append(_ touch: UITouch) {
        let point = sample(touch)
        if let last = wetPoints.last, hypot(CGFloat(point.x - last.x), CGFloat(point.y - last.y)) < minStep { return }
        wetPoints.append(point)
    }

    // The predicted samples only extend the live stroke, they are never stored.
    private func updateWet(_ touch: UITouch?, _ event: UIEvent?) {
        guard let wet, let style = wetStyle else { return }
        var points = wetPoints
        if let touch, let predicted = event?.predictedTouches(for: touch) { points += predicted.map(sample) }
        withoutAnimation { wet.update(points: points, color: style.color, width: style.width, pressure: style.pressure) }
    }

    private func moveStroke(_ touch: UITouch, event: UIEvent?, samples: [UITouch]) {
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
            samples.forEach(append)
            updateWet(touch, event)
        }
    }

    private func endStroke(_ touch: UITouch, commit: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        defer {
            wet = nil
            wetPoints = []
            wetStyle = nil
            snapped = nil
        }
        guard let live = wet, let style = wetStyle else { return }
        if snapped == nil { append(touch) }
        let points = snapped.map(shapePoints) ?? wetPoints
        guard commit, !points.isEmpty else {
            withoutAnimation { live.group.removeFromSuperlayer() }
            return
        }
        let pressure = snapped == nil ? style.pressure : 0 // snapped shapes have a constant width
        let stroke = InkStroke(kind: style.kind, color: style.color, width: style.width, pressure: pressure, points: points)
        withoutAnimation { live.update(points: stroke.points, color: stroke.color, width: stroke.width, pressure: stroke.pressure) }
        layers[stroke.id] = live // the live layers become the stroke's layers, so sync() keeps them
        store.add(stroke, on: page)
    }

    // MARK: Hold to shape

    private func checkHold() {
        guard wet != nil, snapped == nil, !holdTried,
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
        guard let shape = snapped, let wet, let style = wetStyle else { return }
        let path = CGMutablePath()
        switch shape {
        case .line(let from, let to):
            path.move(to: from)
            path.addLine(to: to)
        case .ellipse(let center, let rx, let ry, let angle):
            path.addEllipse(in: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry),
                            transform: CGAffineTransform(translationX: center.x, y: center.y).rotated(by: angle))
        }
        withoutAnimation { wet.show(path: path, color: style.color, width: style.width) }
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

    // Partial: strokes are cut where the eraser circle passes. Whole: every stroke it touches goes.
    private func erase(at point: CGPoint, partial: Bool, radius screenRadius: CGFloat) {
        let radius = screenRadius / screenPerPagePoint // the same size on screen, whatever the zoom
        var removeIDs = Set<UUID>()
        var pieces: [InkStroke] = []
        for stroke in store.strokes(on: page) {
            if partial {
                if let cut = InkGeometry.cut(stroke, around: point, radius: radius) {
                    removeIDs.insert(stroke.id)
                    pieces += cut
                }
            } else if InkGeometry.hit(stroke, at: point, radius: radius) {
                removeIDs.insert(stroke.id)
            }
        }
        guard !removeIDs.isEmpty else { return }
        for stroke in store.liveEdit(remove: removeIDs, insert: pieces, on: page) {
            if eraseAdded[stroke.id] != nil { eraseAdded[stroke.id] = nil } else { eraseRemoved[stroke.id] = stroke }
        }
        for piece in pieces { eraseAdded[piece.id] = piece }
    }

    private func moveEraserCursor(to point: CGPoint, radius screenRadius: CGFloat) {
        let r = screenRadius / screenPerPagePoint
        withoutAnimation {
            eraserCursor.lineWidth = 1 / screenPerPagePoint
            eraserCursor.path = CGPath(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r), transform: nil)
            if eraserCursor.superlayer == nil { host.layer.addSublayer(eraserCursor) }
        }
    }

    private func endErase() {
        withoutAnimation { eraserCursor.removeFromSuperlayer() }
        guard !eraseRemoved.isEmpty || !eraseAdded.isEmpty else { return }
        store.commitErase(removed: Array(eraseRemoved.values), added: Array(eraseAdded.values), on: page)
        eraseRemoved = [:]
        eraseAdded = [:]
    }

    // MARK: Lasso

    private var selectedStrokes: [InkStroke] {
        store.strokes(on: page).filter { selection.contains($0.id) }
    }

    private func updateLassoPath() {
        let path = CGMutablePath()
        if let first = lassoPoints.first {
            path.move(to: first)
            lassoPoints.dropFirst().forEach { path.addLine(to: $0) }
        }
        withoutAnimation { lassoLayer.path = path }
    }

    private func endLasso(commit: Bool) {
        withoutAnimation { lassoLayer.removeFromSuperlayer() }
        defer { lassoPoints = [] }
        guard commit, lassoPoints.count > 4 else { return }
        let loop = CGMutablePath()
        loop.addLines(between: lassoPoints)
        loop.closeSubpath()
        selection = Set(store.strokes(on: page).filter { InkGeometry.isSelected($0, by: loop) }.map(\.id))
        updateSelectionVisual()
        if !selection.isEmpty { presentMenu() }
    }

    private func updateSelectionVisual() {
        let strokes = selectedStrokes
        withoutAnimation {
            guard var box = strokes.first?.bounds else {
                selectionLayer.removeFromSuperlayer()
                rotateHandleLine.removeFromSuperlayer()
                resizeHandleView.isHidden = true
                rotateHandleView.isHidden = true
                selectionBounds = .null
                return
            }
            for stroke in strokes.dropFirst() { box = box.union(stroke.bounds) }
            selectionBounds = box.insetBy(dx: -8, dy: -8)

            selectionLayer.transform = CATransform3DIdentity
            selectionLayer.path = CGPath(roundedRect: selectionBounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
            selectionLayer.removeFromSuperlayer()
            host.layer.addSublayer(selectionLayer)

            let target = handleTouchTarget / screenPerPagePoint // constant on-screen size, whatever the zoom
            let targetSize = CGSize(width: target, height: target)

            resizeHandleView.transform = .identity
            resizeHandleView.bounds = CGRect(origin: .zero, size: targetSize)
            resizeHandleView.center = CGPoint(x: selectionBounds.maxX, y: selectionBounds.maxY)
            resizeHandleView.isHidden = false
            host.bringSubviewToFront(resizeHandleView)

            let rotateCenter = CGPoint(x: selectionBounds.midX, y: selectionBounds.minY - rotateHandleOffset / screenPerPagePoint)
            rotateHandleView.transform = .identity
            rotateHandleView.bounds = CGRect(origin: .zero, size: targetSize)
            rotateHandleView.center = rotateCenter
            rotateHandleView.isHidden = false
            host.bringSubviewToFront(rotateHandleView)

            rotateHandleLine.transform = CATransform3DIdentity
            let line = CGMutablePath()
            line.move(to: CGPoint(x: selectionBounds.midX, y: selectionBounds.minY))
            line.addLine(to: rotateCenter)
            rotateHandleLine.path = line
            rotateHandleLine.removeFromSuperlayer()
            host.layer.addSublayer(rotateHandleLine)
        }
    }

    private func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        updateSelectionVisual()
        menu?.dismissMenu()
    }

    // The rotate handle's resting position, before any live drag/transform offset.
    private var rotateHandleBaseCenter: CGPoint {
        CGPoint(x: selectionBounds.midX, y: selectionBounds.minY - rotateHandleOffset / screenPerPagePoint)
    }

    // While dragging, the selected layers (and the handles) are only shifted; the strokes are rewritten when
    // the pen lifts. Pure translation, so — unlike resize/rotate below — it needs no anchor-point juggling.
    private func applyDrag() {
        let shift = CATransform3DMakeTranslation(dragOffset.width, dragOffset.height, 0)
        withoutAnimation {
            for id in selection { layers[id]?.group.transform = shift }
            selectionLayer.transform = shift
            rotateHandleLine.transform = shift
            resizeHandleView.center = CGPoint(x: selectionBounds.maxX + dragOffset.width, y: selectionBounds.maxY + dragOffset.height)
            let base = rotateHandleBaseCenter
            rotateHandleView.center = CGPoint(x: base.x + dragOffset.width, y: base.y + dragOffset.height)
        }
    }

    private func endMove(commit: Bool) {
        let offset = dragOffset
        dragOffset = .zero
        guard commit, hypot(offset.width, offset.height) > 1 else {
            applyDrag() // a tap inside the selection, or a cancelled drag: put everything back
            if commit { presentMenu() }
            return
        }
        let moved = selectedStrokes.map { $0.moved(by: offset) }
        let old = selection
        store.replace(remove: old, insert: moved, on: page)
        selection = Set(moved.map(\.id))
        updateSelectionVisual()
        presentMenu()
    }

    // MARK: Resize / rotate

    // Dragging the corner handle scales the selection about the opposite corner; dragging the one above the
    // selection rotates it about its center, snapping to right angles within a few degrees.
    private func handleResizePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginTransform(pivot: CGPoint(x: selectionBounds.minX, y: selectionBounds.minY), at: gesture.location(in: host))
        case .changed:
            let p = gesture.location(in: host)
            let current = CGPoint(x: p.x - transformPivot.x, y: p.y - transformPivot.y)
            let startLength = hypot(transformStartVector.x, transformStartVector.y)
            guard startLength > 1 else { return }
            let scale = max(0.2, min(6, hypot(current.x, current.y) / startLength))
            applyTransformPreview(CGAffineTransform(scaleX: scale, y: scale))
        case .ended, .cancelled:
            endTransform(commit: gesture.state == .ended)
        default:
            break
        }
    }

    private func handleRotatePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            rotationSnapped = false
            beginTransform(pivot: CGPoint(x: selectionBounds.midX, y: selectionBounds.midY), at: gesture.location(in: host))
        case .changed:
            let p = gesture.location(in: host)
            let current = CGPoint(x: p.x - transformPivot.x, y: p.y - transformPivot.y)
            var angle = atan2(current.y, current.x) - atan2(transformStartVector.y, transformStartVector.x)
            let step = CGFloat.pi / 2
            let nearest = (angle / step).rounded() * step
            let snapped = abs(angle - nearest) <= rotationSnapThreshold
            if snapped { angle = nearest }
            if snapped != rotationSnapped {
                rotationSnapped = snapped
                UISelectionFeedbackGenerator().selectionChanged() // a tick as it locks on or lets go
            }
            applyTransformPreview(CGAffineTransform(rotationAngle: angle))
        case .ended, .cancelled:
            endTransform(commit: gesture.state == .ended)
        default:
            break
        }
    }

    // Re-anchors every selected layer (plus the selection outline and the rotate handle's connector line) at
    // `pivot`, keeping their on-screen position unchanged for now. From here on, a *plain* scale or rotation —
    // not one built with `.pivoted` — visually turns them about that shared point, because CALayer applies
    // `.transform` relative to its own anchorPoint/position, not to an arbitrary point in its parent. (The
    // `.pivoted` version is still what gets applied to the actual stroke *geometry* once the gesture ends;
    // `InkStroke.transformed(by:)` has no notion of anchors, it just moves points.)
    private func beginTransform(pivot: CGPoint, at touchPoint: CGPoint) {
        menu?.dismissMenu()
        transformPivot = pivot
        transformStartVector = CGPoint(x: touchPoint.x - pivot.x, y: touchPoint.y - pivot.y)
        pendingTransform = .identity
        resizeHandleOrigin = resizeHandleView.center
        rotateHandleOrigin = rotateHandleView.center
        let anchorUnit = CGPoint(x: pivot.x / pageSize.width, y: pivot.y / pageSize.height)
        withoutAnimation {
            for id in selection {
                guard let group = layers[id]?.group else { continue }
                group.anchorPoint = anchorUnit
                group.position = pivot
            }
            selectionLayer.anchorPoint = anchorUnit
            selectionLayer.position = pivot
            rotateHandleLine.anchorPoint = anchorUnit
            rotateHandleLine.position = pivot
        }
    }

    private func applyTransformPreview(_ core: CGAffineTransform) {
        pendingTransform = CGAffineTransform.pivoted(core, around: transformPivot)
        withoutAnimation {
            let layerTransform = CATransform3DMakeAffineTransform(core) // anchor is already the pivot, so this is unpivoted
            for id in selection { layers[id]?.group.transform = layerTransform }
            selectionLayer.transform = layerTransform
            rotateHandleLine.transform = layerTransform
            resizeHandleView.center = resizeHandleOrigin.applying(pendingTransform)
            rotateHandleView.center = rotateHandleOrigin.applying(pendingTransform)
        }
    }

    // Puts every layer's anchorPoint/position back to CALayer's plain default, so a later drag or the next
    // resize/rotate starts from a known state instead of whatever pivot the last gesture left behind.
    private func resetTransformAnchors() {
        let center = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
        let defaultAnchor = CGPoint(x: 0.5, y: 0.5)
        withoutAnimation {
            for id in selection {
                guard let group = layers[id]?.group else { continue }
                group.anchorPoint = defaultAnchor
                group.position = center
                group.transform = CATransform3DIdentity
            }
            selectionLayer.anchorPoint = defaultAnchor
            selectionLayer.position = center
            selectionLayer.transform = CATransform3DIdentity
            rotateHandleLine.anchorPoint = defaultAnchor
            rotateHandleLine.position = center
            rotateHandleLine.transform = CATransform3DIdentity
        }
    }

    private func endTransform(commit: Bool) {
        let transform = pendingTransform
        pendingTransform = .identity
        resetTransformAnchors()
        guard commit, transform != .identity else {
            updateSelectionVisual() // nothing written to the store; lay the handles back out from scratch
            if commit { presentMenu() }
            return
        }
        let transformed = selectedStrokes.map { $0.transformed(by: transform) }
        let old = selection
        store.replace(remove: old, insert: transformed, on: page)
        selection = Set(transformed.map(\.id))
        updateSelectionVisual()
        presentMenu()
    }

    @objc private func handleTap(_ tap: UITapGestureRecognizer) {
        guard !selection.isEmpty else { return }
        let location = tap.location(in: self)
        let p = CGPoint(x: location.x / max(scale, 0.01), y: location.y / max(scale, 0.01))
        if selectionBounds.contains(p) { presentMenu() } else { clearSelection() }
    }

    private func presentMenu() {
        guard !selection.isEmpty else { return }
        let point = CGPoint(x: selectionBounds.midX * scale, y: selectionBounds.minY * scale)
        menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
            UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelection() },
            UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ])
    }

    private func copySelection() {
        InkClipboard.copy(selectedStrokes)
    }

    private func duplicateSelection() {
        let copies = selectedStrokes.map { $0.moved(by: CGSize(width: 24, height: 24)) }
        guard !copies.isEmpty else { return }
        store.replace(remove: [], insert: copies, on: page)
        selection = Set(copies.map(\.id))
        updateSelectionVisual()
        presentMenu()
    }

    private func deleteSelection() {
        store.replace(remove: selection, insert: [], on: page)
        clearSelection()
    }

    // Pastes onto THIS page (may be a different page, or even a different document, from where the copy was
    // made), centered wherever the caller says is currently visible. Triggered from the "+" menu, not the lasso
    // menu, since there is nothing to lasso-select when pasting into empty space.
    func pasteClipboard(at center: CGPoint) {
        let pasted = InkClipboard.pasteStrokes(centeredAt: center)
        guard !pasted.isEmpty else { return }
        store.replace(remove: [], insert: pasted, on: page)
        // Not auto-selected: paste can happen from any tool, and a selection outline only means anything in lasso mode.
    }
}

// A small round drag handle. The visible dot is inset from the view's own bounds, so the actual touch target
// is comfortably bigger than what's drawn — standard for a control this small.
private final class SelectionHandleView: UIView {
    private let dot = UIView()
    var onPan: ((UIPanGestureRecognizer) -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        dot.backgroundColor = .systemBlue
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 1.5
        dot.isUserInteractionEnabled = false
        addSubview(dot)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)] // fingers only, like every other manipulation
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = bounds.insetBy(dx: bounds.width * 0.22, dy: bounds.height * 0.22)
        dot.layer.cornerRadius = dot.bounds.width / 2
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) { onPan?(gesture) }
}
