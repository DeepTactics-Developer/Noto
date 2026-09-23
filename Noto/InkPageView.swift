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

    func update(points: [InkPoint], color: [Float], width: Float, pressure: Float, kind: InkKind) {
        let runs = InkGeometry.runs(of: points, width: width, pressure: pressure, kind: kind)
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

    // A single custom path at a fixed width (snapped shapes) — the path is overwritten below regardless of
    // how `update` would have run-split it, so `kind` here is arbitrary.
    func show(path: CGPath, color: [Float], width: Float) {
        update(points: [InkPoint(x: 0, y: 0, force: 0, time: 0)], color: color, width: width, pressure: 0, kind: .pen)
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
    private var wetRecording: (id: UUID, offset: Float)?
    // Queried when a stroke begins, so the finished stroke can be tagged with which recording (if any) was
    // running and how far into it — playback uses this to highlight strokes as their moment comes up.
    var activeRecording: (() -> (id: UUID, elapsed: TimeInterval)?)?
    private let minStep: CGFloat = 0.3 // page points; closer samples are dropped

    // hold to shape
    private var holdTimer: Timer?
    private var holdAnchor = CGPoint.zero // where the pen was last seen moving, in window coordinates
    private var holdSince: TimeInterval = 0
    private var holdTried = false
    private var holdDelay: TimeInterval = 0.5
    private var snapped: RecognizedShape?
    // This page's text lines (top-left origin, page points), for the highlighter's "snap to text" setting.
    // Set by whoever owns the document; nil (or an empty result) just means the feature quietly does nothing.
    var textLineProvider: (() -> [CGRect])?
    // Fired at the start of every touch this view itself receives — which, given ObjectsPageView sits in front
    // and passes pencil through but claims fingers, only happens for a touch that landed on empty canvas (or a
    // pencil touch anywhere). The owner uses this to deselect any selected text/image object.
    var onCanvasTouch: (() -> Void)?
    // Called when the user picks "AI로 설명" from the lasso selection menu, with the selected strokes and the
    // lasso's own loop (page points) — the owner uses the loop to also gather any PDF text inside it, so the
    // explanation isn't limited to handwriting.
    var onExplainSelection: (([InkStroke], [CGPoint]) -> Void)?
    private var lastLassoPolygon: [CGPoint] = []
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
    private var dragStart = CGPoint.zero
    private var dragOffset = CGSize.zero
    private var menu: UIEditMenuInteraction?

    // The selection's own frame, independent of how the strokes it holds happen to be stored: `selectionAngle`
    // persists across gestures (a rotate adds to it, a resize/move leave it alone) instead of being re-derived
    // as a fresh axis-aligned box every time, which is what made a rotated selection's outline and handles snap
    // back to looking un-rotated the moment you let go.
    private var selectionCenter = CGPoint.zero // absolute page coordinates
    private var selectionSize = CGSize.zero // width/height in the selection's own (unrotated) local frame
    private var selectionAngle: CGFloat = 0 // accumulated rotation, radians

    // resize (bottom-right handle, opposite corner as pivot) / rotate (handle above top-center, pivot = center;
    // snaps to right angles). Real UIViews with their own pan gesture, not raw touch hit-testing: UIKit's own
    // hit-testing is what decides whether a touch lands on a handle, instead of a hand-rolled distance check.
    private let resizeHandleView = SelectionHandleView()
    private let rotateHandleView = SelectionHandleView()
    private let rotateHandleLine = NoActionShapeLayer() // purely visual connector, not itself interactive
    private enum TransformKind { case resize, rotate }
    private var transformKind: TransformKind?
    private var transformPivot = CGPoint.zero
    private var transformStartVector = CGPoint.zero
    private var resizeHandleOrigin = CGPoint.zero // the handle's own position before the live preview moves it
    private var rotateHandleOrigin = CGPoint.zero
    private var pendingTransform = CGAffineTransform.identity
    private var liveScale: CGFloat = 1
    private var liveAngle: CGFloat = 0
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

    // Called by PageView.layoutSubviews, in the same statement as ObjectsPageView's own applyScale — each view
    // used to compute this independently from its own layoutSubviews, which let the two host transforms start
    // their implicit rotation animations a runloop tick apart. That's what made ink and the text/image objects
    // visibly drift out of step for a few frames during a device rotation (confirmed by a frame-by-frame look
    // at a screen recording of a rotation: an object's handle bar was visibly at a different angle than the
    // surrounding ink for a couple of frames, back in sync a couple of frames later). Driving both from one
    // caller in the same CATransaction keeps them locked together throughout.
    func applyScale(_ newScale: CGFloat, animated: Bool) {
        guard newScale > 0, newScale != scale else { return }
        scale = newScale
        let apply = { self.host.transform = CGAffineTransform(scaleX: newScale, y: newScale) }
        if animated { apply() } else { UIView.performWithoutAnimation(apply) }
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func makeLayers(for stroke: InkStroke) -> StrokeLayers {
        let strokeLayers = StrokeLayers(size: pageSize)
        strokeLayers.update(points: stroke.points, color: stroke.color, width: stroke.width, pressure: stroke.pressure, kind: stroke.kind)
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
                resetSelectionFrame()
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
        onCanvasTouch?()
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
        let pressure: Float = (kind == .pen || kind == .pencil) && AppSettings.pressure ? Float(AppSettings.pressureSensitivity) : 0
        wetStyle = (kind, color, width, pressure)
        wetRecording = activeRecording?().map { (id: $0.id, offset: Float($0.elapsed)) }
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
        withoutAnimation { wet.update(points: points, color: style.color, width: style.width, pressure: style.pressure, kind: style.kind) }
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
        let recording = wetRecording
        defer {
            wet = nil
            wetPoints = []
            wetStyle = nil
            wetRecording = nil
            snapped = nil
        }
        guard let live = wet, let style = wetStyle else { return }
        if snapped == nil { append(touch) }
        let points = snapped.map(shapePoints) ?? wetPoints
        guard commit, !points.isEmpty else {
            withoutAnimation { live.group.removeFromSuperlayer() }
            return
        }
        let textSnapped = style.kind == .highlighter && snapped == nil && AppSettings.highlighterTextSnap
            ? snappedHighlightStrokes(sweeping: points, color: style.color, lines: textLineProvider?() ?? [])
            : []
        if !textSnapped.isEmpty {
            withoutAnimation { live.group.removeFromSuperlayer() } // discard the freehand preview; these replace it
            for stroke in textSnapped {
                let strokeLayers = makeLayers(for: stroke)
                withoutAnimation { host.layer.addSublayer(strokeLayers.group) }
                layers[stroke.id] = strokeLayers
                store.add(stroke, on: page)
            }
            return
        }
        let pressure = snapped == nil ? style.pressure : 0 // snapped shapes have a constant width
        let stroke = InkStroke(kind: style.kind, color: style.color, width: style.width, pressure: pressure, points: points,
                               recordingID: recording?.id, recordingOffset: recording?.offset)
        withoutAnimation { live.update(points: stroke.points, color: stroke.color, width: stroke.width, pressure: stroke.pressure, kind: stroke.kind) }
        layers[stroke.id] = live // the live layers become the stroke's layers, so sync() keeps them
        store.add(stroke, on: page)
    }

    // One flat, constant-width stroke per text line the highlighter's stroke swept over — this is what makes
    // a highlighter drawn loosely over a line of text come out looking like it exactly covers that line,
    // the way it would on paper. Only for documents that actually have a text layer (real text or OCR'd);
    // `textLineProvider` reports no lines otherwise, so this quietly falls back to the freehand stroke.
    private func snappedHighlightStrokes(sweeping points: [InkPoint], color: [Float], lines: [CGRect]) -> [InkStroke] {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let sweep = CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        let overlapped = lines.filter { $0.intersects(sweep) }
        return overlapped.compactMap { line -> InkStroke? in
            // Only the part of the line actually swept, not its full width — a highlighter dragged over one
            // word shouldn't light up the whole sentence.
            let x0 = max(line.minX, sweep.minX)
            let x1 = min(line.maxX, sweep.maxX)
            guard x1 > x0 else { return nil }
            let y = Float(line.midY)
            return InkStroke(kind: .highlighter, color: color, width: Float(line.height * 0.9),
                             points: [InkPoint(x: Float(x0), y: y, force: 0.5, time: 0),
                                     InkPoint(x: Float(x1), y: y, force: 0.5, time: 0.1)])
        }
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
        case .polygon(let corners):
            path.addLines(between: corners)
            path.closeSubpath()
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
        case .polygon(let corners):
            // InkGeometry.path() smooths a quadratic curve THROUGH each interior point (it only passes exactly
            // through the first and last), which is right for freehand ink but rounds off every corner except
            // one if fed just the 3-4 raw corners. Resampling each edge densely keeps consecutive points close
            // to colinear, so that same smoothing stays imperceptibly close to straight — the same trick the
            // ellipse case above already relies on for its curve.
            let closed = corners + [corners[0]]
            let perEdge = 24
            var dense: [CGPoint] = []
            for i in 0..<(closed.count - 1) {
                let a = closed[i], b = closed[i + 1]
                for k in 0..<perEdge {
                    let t = CGFloat(k) / CGFloat(perEdge)
                    dense.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
            }
            dense.append(closed[closed.count - 1])
            let n = dense.count
            return dense.enumerated().map { i, p in point(p, end * Float(i) / Float(max(n - 1, 1))) }
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
        lastLassoPolygon = lassoPoints
        selection = Set(store.strokes(on: page).filter { InkGeometry.isSelected($0, by: loop) }.map(\.id))
        resetSelectionFrame()
        updateSelectionVisual()
        if !selection.isEmpty {
            presentMenu()
        } else {
            // No ink under the loop doesn't mean nothing was selected — there may be PDF text there. Show the
            // menu anyway (editMenuInteraction below hides the ink-only actions when selection is empty), so
            // "AI로 설명" still works purely on PDF text with no handwriting over it.
            let xs = lastLassoPolygon.map(\.x), ys = lastLassoPolygon.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min() else { return }
            let anchor = CGPoint(x: (minX + maxX) / 2 * scale, y: minY * scale)
            menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: anchor))
        }
    }

    // A fresh, axis-aligned frame around whatever is currently selected. Called whenever the selection itself
    // changes (a new lasso, duplicate, or an external edit shrinking it) — not after a resize/rotate/move, which
    // update the existing frame incrementally instead so its remembered orientation survives.
    private func resetSelectionFrame() {
        let strokes = selectedStrokes
        guard var box = strokes.first?.bounds else {
            selectionCenter = .zero
            selectionSize = .zero
            selectionAngle = 0
            return
        }
        for stroke in strokes.dropFirst() { box = box.union(stroke.bounds) }
        let padded = box.insetBy(dx: -8, dy: -8)
        selectionCenter = CGPoint(x: padded.midX, y: padded.midY)
        selectionSize = padded.size
        selectionAngle = 0
    }

    // `offset` in the selection's own local (unrotated) frame, rotated to its actual place in the page.
    private func worldPoint(localOffset offset: CGPoint) -> CGPoint {
        let c = cos(selectionAngle), s = sin(selectionAngle)
        return CGPoint(x: selectionCenter.x + offset.x * c - offset.y * s, y: selectionCenter.y + offset.x * s + offset.y * c)
    }

    // Top-left, top-right, bottom-right, bottom-left, in world space — bottom-right is the resize handle, and
    // top-left is its pivot (the opposite corner).
    private var selectionCorners: [CGPoint] {
        let half = CGPoint(x: selectionSize.width / 2, y: selectionSize.height / 2)
        return [CGPoint(x: -half.x, y: -half.y), CGPoint(x: half.x, y: -half.y),
               CGPoint(x: half.x, y: half.y), CGPoint(x: -half.x, y: half.y)].map(worldPoint(localOffset:))
    }

    private var selectionRotateHandlePoint: CGPoint {
        worldPoint(localOffset: CGPoint(x: 0, y: -selectionSize.height / 2 - rotateHandleOffset / screenPerPagePoint))
    }

    // The axis-aligned box enclosing the (possibly rotated) selection — only for the "tap inside to drag" hit
    // test and the edit menu's anchor point, where an exact rotated hit test would be more precision than it's worth.
    private var selectionBounds: CGRect {
        let corners = selectionCorners
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func updateSelectionVisual() {
        withoutAnimation {
            guard !selection.isEmpty else {
                selectionLayer.removeFromSuperlayer()
                rotateHandleLine.removeFromSuperlayer()
                resizeHandleView.isHidden = true
                rotateHandleView.isHidden = true
                return
            }

            selectionLayer.transform = CATransform3DIdentity
            let corners = selectionCorners
            let path = CGMutablePath()
            path.move(to: corners[0])
            corners.dropFirst().forEach { path.addLine(to: $0) }
            path.closeSubpath()
            selectionLayer.path = path
            selectionLayer.removeFromSuperlayer()
            host.layer.addSublayer(selectionLayer)

            let target = handleTouchTarget / screenPerPagePoint // constant on-screen size, whatever the zoom
            let targetSize = CGSize(width: target, height: target)

            resizeHandleView.transform = .identity
            resizeHandleView.bounds = CGRect(origin: .zero, size: targetSize)
            resizeHandleView.center = corners[2] // bottom-right, in the selection's own (possibly rotated) frame
            resizeHandleView.isHidden = false
            host.bringSubviewToFront(resizeHandleView)

            let rotatePoint = selectionRotateHandlePoint
            rotateHandleView.transform = .identity
            rotateHandleView.bounds = CGRect(origin: .zero, size: targetSize)
            rotateHandleView.center = rotatePoint
            rotateHandleView.isHidden = false
            host.bringSubviewToFront(rotateHandleView)

            rotateHandleLine.transform = CATransform3DIdentity
            let line = CGMutablePath()
            line.move(to: worldPoint(localOffset: CGPoint(x: 0, y: -selectionSize.height / 2)))
            line.addLine(to: rotatePoint)
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

    // While dragging, the selected layers (and the handles) are only shifted; the strokes are rewritten when
    // the pen lifts. Pure translation, so — unlike resize/rotate below — it needs no anchor-point juggling.
    private func applyDrag() {
        let shift = CATransform3DMakeTranslation(dragOffset.width, dragOffset.height, 0)
        withoutAnimation {
            for id in selection { layers[id]?.group.transform = shift }
            selectionLayer.transform = shift
            rotateHandleLine.transform = shift
            let corner = selectionCorners[2]
            resizeHandleView.center = CGPoint(x: corner.x + dragOffset.width, y: corner.y + dragOffset.height)
            let rotatePoint = selectionRotateHandlePoint
            rotateHandleView.center = CGPoint(x: rotatePoint.x + dragOffset.width, y: rotatePoint.y + dragOffset.height)
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
        // `selection` must already name the new strokes *before* store.replace runs: replacing strokes fires
        // sync() synchronously, and sync() resets the selection frame the moment it sees `selection` pointing
        // at strokes the store no longer has — which, since every edit here mints fresh ids, is true of `old`
        // for the rest of this function. Updating `selection` first keeps sync() from ever seeing that gap.
        selection = Set(moved.map(\.id))
        store.replace(remove: old, insert: moved, on: page)
        selectionCenter = CGPoint(x: selectionCenter.x + offset.width, y: selectionCenter.y + offset.height)
        updateSelectionVisual()
        presentMenu()
    }

    // MARK: Resize / rotate

    // Dragging the corner handle scales the selection about the opposite corner; dragging the one above the
    // selection rotates it about its center, snapping to right angles within a few degrees.
    private func handleResizePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            transformKind = .resize
            liveScale = 1
            beginTransform(pivot: selectionCorners[0], at: gesture.location(in: host)) // opposite (top-left) corner, fixed
        case .changed:
            let p = gesture.location(in: host)
            let current = CGPoint(x: p.x - transformPivot.x, y: p.y - transformPivot.y)
            let startLength = hypot(transformStartVector.x, transformStartVector.y)
            guard startLength > 1 else { return }
            liveScale = max(0.2, min(6, hypot(current.x, current.y) / startLength))
            applyTransformPreview(CGAffineTransform(scaleX: liveScale, y: liveScale))
        case .ended, .cancelled:
            endTransform(commit: gesture.state == .ended)
        default:
            break
        }
    }

    private func handleRotatePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            transformKind = .rotate
            rotationSnapped = false
            liveAngle = 0
            beginTransform(pivot: selectionCenter, at: gesture.location(in: host))
        case .changed:
            let p = gesture.location(in: host)
            let current = CGPoint(x: p.x - transformPivot.x, y: p.y - transformPivot.y)
            var angle = normalizedAngle(atan2(current.y, current.x) - atan2(transformStartVector.y, transformStartVector.x))
            let step = CGFloat.pi / 2
            let nearest = (angle / step).rounded() * step
            let snapped = abs(angle - nearest) <= rotationSnapThreshold
            if snapped { angle = nearest }
            if snapped != rotationSnapped {
                rotationSnapped = snapped
                UISelectionFeedbackGenerator().selectionChanged() // a tick as it locks on or lets go
            }
            liveAngle = angle
            applyTransformPreview(CGAffineTransform(rotationAngle: angle))
        case .ended, .cancelled:
            endTransform(commit: gesture.state == .ended)
        default:
            break
        }
    }

    // atan2's difference can otherwise land outside (-π, π] right as the pen crosses behind the pivot, which
    // would read as a huge jump instead of the small turn it actually was.
    private func normalizedAngle(_ angle: CGFloat) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
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
        let kind = transformKind
        let pivot = transformPivot
        pendingTransform = .identity
        transformKind = nil
        resetTransformAnchors()
        guard commit, transform != .identity else {
            updateSelectionVisual() // nothing written to the store; lay the handles back out from scratch
            if commit { presentMenu() }
            return
        }
        let transformed = selectedStrokes.map { $0.transformed(by: transform) }
        let old = selection
        selection = Set(transformed.map(\.id)) // see the comment in endMove: must happen before store.replace
        store.replace(remove: old, insert: transformed, on: page)
        switch kind {
        case .resize:
            // The opposite corner stayed fixed; the frame just grew/shrank from there, in its existing orientation.
            selectionSize = CGSize(width: selectionSize.width * liveScale, height: selectionSize.height * liveScale)
            let half = CGPoint(x: selectionSize.width / 2, y: selectionSize.height / 2)
            let c = cos(selectionAngle), s = sin(selectionAngle)
            selectionCenter = CGPoint(x: pivot.x + half.x * c - half.y * s, y: pivot.y + half.x * s + half.y * c)
        case .rotate:
            selectionAngle += liveAngle
        case nil:
            break
        }
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
        var actions: [UIMenuElement] = [
            UIAction(title: "AI로 설명", image: UIImage(systemName: "sparkles")) { [weak self] _ in self?.explainSelection() },
        ]
        // Copy/duplicate/delete only make sense with ink actually selected — a lasso over plain PDF text with
        // no handwriting still gets here (see endLasso) purely so "AI로 설명" is reachable.
        if !selection.isEmpty {
            actions += [
                UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
                UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelection() },
                UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
            ]
        }
        return UIMenu(children: actions)
    }

    private func explainSelection() {
        onExplainSelection?(selectedStrokes, lastLassoPolygon)
    }

    private func copySelection() {
        InkClipboard.copy(selectedStrokes)
    }

    private func duplicateSelection() {
        let copies = selectedStrokes.map { $0.moved(by: CGSize(width: 24, height: 24)) }
        guard !copies.isEmpty else { return }
        selection = Set(copies.map(\.id)) // see the comment in endMove: must happen before store.replace
        store.replace(remove: [], insert: copies, on: page)
        resetSelectionFrame()
        updateSelectionVisual()
        presentMenu()
    }

    private func deleteSelection() {
        store.replace(remove: selection, insert: [], on: page)
        selection = []
        updateSelectionVisual()
        menu?.dismissMenu()
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
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
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

    // This view has no touchesBegan override of its own, so by default an unrecognized touch here (the brief
    // window before the pan gesture above has moved enough to recognize) forwards up the responder chain —
    // through `host` and into InkPageView's own touchesBegan, which for a pencil touch immediately reads it as
    // "empty canvas, start a new lasso," clearing the very selection this handle belongs to. Swallowing the
    // touch here (never calling super) keeps it local to this view's own pan gesture, which is what actually
    // drives resize/rotate for both finger and pencil.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}
