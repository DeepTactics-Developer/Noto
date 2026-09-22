import CoreGraphics

enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) // rx runs along `angle` (radians)
    case polygon([CGPoint]) // 3 points = triangle, 4 = rectangle (rectangles are re-fit to be exact; triangles aren't)
}

// Decides whether a hand-drawn stroke is meant to be a straight line, an ellipse/circle, or a triangle/rectangle.
// Input is in page points, thresholds are tuned for hand-drawn strokes and are deliberately strict:
// a wrong snap is worse than no snap.
enum ShapeRecognizer {
    static func recognize(_ points: [CGPoint]) -> RecognizedShape? {
        guard points.count >= 3 else { return nil }
        return line(points) ?? ellipse(points) ?? polygon(points)
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    private static func line(_ points: [CGPoint]) -> RecognizedShape? {
        let a = points[0], b = points[points.count - 1]
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord >= 20, pathLength(points) <= chord * 1.35 else { return nil }
        let ux = (b.x - a.x) / chord, uy = (b.y - a.y) / chord
        let deviation = points.map { abs(($0.x - a.x) * uy - ($0.y - a.y) * ux) }.max() ?? 0
        guard deviation <= max(chord * 0.08, 2) else { return nil }
        return .line(from: a, to: b)
    }

    // Evenly spaced along the path, so uneven pen speed does not skew the fit.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        let total = pathLength(points)
        guard total > 0 else { return points }
        let step = total / CGFloat(count - 1)
        var out = [points[0]]
        var travelled: CGFloat = 0
        var target = step
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let segment = hypot(b.x - a.x, b.y - a.y)
            guard segment > 0 else { continue }
            while travelled + segment >= target, out.count < count {
                let t = (target - travelled) / segment
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                target += step
            }
            travelled += segment
        }
        if out.count < count { out.append(points[points.count - 1]) }
        return out
    }

    private static func ellipse(_ points: [CGPoint]) -> RecognizedShape? {
        guard pathLength(points) >= 40 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let diagonal = hypot((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        let gap = hypot(points[points.count - 1].x - points[0].x, points[points.count - 1].y - points[0].y)
        guard diagonal >= 16, gap <= diagonal * 0.35 else { return nil } // must be a (nearly) closed loop

        let samples = resample(points, count: 72)
        let n = CGFloat(samples.count)
        let cx = samples.map(\.x).reduce(0, +) / n
        let cy = samples.map(\.y).reduce(0, +) / n
        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for q in samples {
            let dx = q.x - cx, dy = q.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy) // direction of the major axis
        let c = cos(angle), s = sin(angle)
        let local = samples.map { q -> CGPoint in
            let dx = q.x - cx, dy = q.y - cy
            return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        }
        // For points spread evenly around an ellipse the variance along an axis is r squared over two.
        let rx = sqrt(2 * local.reduce(0) { $0 + $1.x * $1.x } / n)
        let ry = sqrt(2 * local.reduce(0) { $0 + $1.y * $1.y } / n)
        guard ry >= 8, rx > 0 else { return nil }

        var errorSum: CGFloat = 0, errorMax: CGFloat = 0
        var covered = Set<Int>()
        for p in local {
            let error = abs(hypot(p.x / rx, p.y / ry) - 1)
            errorSum += error
            errorMax = max(errorMax, error)
            let turn = (atan2(p.y / ry, p.x / rx) + .pi) / (2 * .pi) // 0...1 around the ellipse
            covered.insert(min(11, Int(turn * 12)))
        }
        guard errorSum / n <= 0.12, errorMax <= 0.3, covered.count == 12 else { return nil } // a full loop, close to an ellipse

        let center = CGPoint(x: cx, y: cy)
        if abs(rx - ry) / max(rx, ry) < 0.15 {
            let r = (rx + ry) / 2
            return .ellipse(center: center, rx: r, ry: r, angle: 0)
        }
        return .ellipse(center: center, rx: rx, ry: ry, angle: angle)
    }

    // MARK: Triangle / rectangle

    private static func polygon(_ points: [CGPoint]) -> RecognizedShape? {
        guard pathLength(points) >= 40 else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let diagonal = hypot((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        let gap = hypot(points[points.count - 1].x - points[0].x, points[points.count - 1].y - points[0].y)
        guard diagonal >= 20, gap <= diagonal * 0.35 else { return nil } // must be a (nearly) closed loop

        let samples = resample(points, count: 72)
        let corners = dominantCorners(samples)
        guard corners.count == 3 || corners.count == 4 else { return nil }

        // Every sample must stay close to one of the candidate polygon's edges — otherwise this is closer to a
        // scribble that happens to have a few sharp wobbles than an actual triangle or rectangle.
        let tolerance = max(diagonal * 0.07, 3)
        guard samples.allSatisfy({ distance(from: $0, toPolygon: corners) <= tolerance }) else { return nil }

        if corners.count == 3 {
            guard isWellFormedTriangle(corners) else { return nil }
            return .polygon(corners)
        }
        guard let rectangle = fittedRectangle(corners) else { return nil }
        return .polygon(rectangle)
    }

    // Points where the loop's direction changes sharply, thinned to one per cluster (its strongest turn) so a
    // single hand-drawn corner doesn't register as several. `points` is a closed loop (resampled, evenly spaced).
    private static func dominantCorners(_ points: [CGPoint]) -> [CGPoint] {
        let n = points.count
        let window = max(3, n / 12)
        let threshold: CGFloat = 28 * .pi / 180
        var turn = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let prev = points[(i - window + n) % n], next = points[(i + window) % n]
            let inAngle = atan2(points[i].y - prev.y, points[i].x - prev.x)
            let outAngle = atan2(next.y - points[i].y, next.x - points[i].x)
            var delta = outAngle - inAngle
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            turn[i] = abs(delta)
        }
        let peaks = (0..<n).filter { i in
            turn[i] >= threshold && turn[i] >= turn[(i - 1 + n) % n] && turn[i] >= turn[(i + 1) % n]
        }
        var kept: [Int] = []
        let minGap = n / 10
        for i in peaks.sorted(by: { turn[$0] > turn[$1] }) {
            if kept.allSatisfy({ min(abs($0 - i), n - abs($0 - i)) >= minGap }) { kept.append(i) }
        }
        return kept.sorted().map { points[$0] }
    }

    private static func distance(from p: CGPoint, toPolygon corners: [CGPoint]) -> CGFloat {
        var best = CGFloat.greatestFiniteMagnitude
        for i in 0..<corners.count {
            best = min(best, InkGeometry.distance(from: p, to: corners[i], corners[(i + 1) % corners.count]))
        }
        return best
    }

    // Rejects a "triangle" that's really just a bent line — one side much shorter than the longest.
    private static func isWellFormedTriangle(_ corners: [CGPoint]) -> Bool {
        let sides = (0..<3).map { hypot(corners[($0 + 1) % 3].x - corners[$0].x, corners[($0 + 1) % 3].y - corners[$0].y) }
        guard let shortest = sides.min(), let longest = sides.max(), longest > 0 else { return false }
        return shortest / longest >= 0.25
    }

    // Replaces the 4 hand-drawn corners with a true rectangle of the same center and orientation: rejects the
    // candidate unless adjacent edges are close to perpendicular, then re-derives clean corners by projecting
    // onto that orientation's own axes, so the result is crisp instead of a wobbly quadrilateral.
    private static func fittedRectangle(_ corners: [CGPoint]) -> [CGPoint]? {
        let center = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
        let edgeAngles = (0..<4).map { atan2(corners[($0 + 1) % 4].y - corners[$0].y, corners[($0 + 1) % 4].x - corners[$0].x) }
        for i in 0..<4 {
            var diff = abs(edgeAngles[i] - edgeAngles[(i + 1) % 4]).truncatingRemainder(dividingBy: .pi)
            if diff > .pi / 2 { diff = .pi - diff }
            guard abs(diff - .pi / 2) <= 18 * .pi / 180 else { return nil } // adjacent sides must be roughly square
        }
        let angle = edgeAngles[0].truncatingRemainder(dividingBy: .pi / 2)
        let c = cos(angle), s = sin(angle)
        let local = corners.map { p -> CGPoint in
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        }
        let halfW = local.map { abs($0.x) }.reduce(0, +) / 4
        let halfH = local.map { abs($0.y) }.reduce(0, +) / 4
        guard halfW >= 4, halfH >= 4 else { return nil }
        return [CGPoint(x: -halfW, y: -halfH), CGPoint(x: halfW, y: -halfH), CGPoint(x: halfW, y: halfH), CGPoint(x: -halfW, y: halfH)]
            .map { CGPoint(x: center.x + $0.x * c - $0.y * s, y: center.y + $0.x * s + $0.y * c) }
    }
}
