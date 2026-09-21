import CoreGraphics

enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, angle: CGFloat) // rx runs along `angle` (radians)
}

// Decides whether a hand-drawn stroke is meant to be a straight line or an ellipse/circle.
// Input is in page points, thresholds are tuned for hand-drawn strokes and are deliberately strict:
// a wrong snap is worse than no snap.
enum ShapeRecognizer {
    static func recognize(_ points: [CGPoint]) -> RecognizedShape? {
        guard points.count >= 3 else { return nil }
        return line(points) ?? ellipse(points)
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
}
