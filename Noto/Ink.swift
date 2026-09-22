import UIKit

enum InkKind: Int, Codable {
    case pen, highlighter
}

// One sampled pen position, in page coordinates (PDF points, origin at the page's top-left).
struct InkPoint: Equatable {
    var x: Float
    var y: Float
    var force: Float // 0...1
    var time: Float // seconds since the stroke began

    var cg: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }
}

struct InkStroke: Identifiable, Codable {
    let id: UUID
    let kind: InkKind
    let color: [Float] // r, g, b, a
    let width: Float // page points
    let pressure: Float // 0 = constant width; otherwise how strongly pen force changes the width
    let points: [InkPoint]
    let bounds: CGRect // derived from the points, not stored

    init(id: UUID = UUID(), kind: InkKind, color: [Float], width: Float, pressure: Float = 0, points: [InkPoint]) {
        self.id = id
        self.kind = kind
        self.color = color
        self.width = width
        self.pressure = pressure
        self.points = points
        self.bounds = InkStroke.bounds(of: points)
    }

    static func uiColor(_ rgba: [Float]) -> UIColor {
        guard rgba.count == 4 else { return .black }
        return UIColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
    }

    // The same stroke moved, as a new stroke: every edit gets a fresh identity so views and undo never
    // confuse the old geometry with the new.
    func moved(by offset: CGSize) -> InkStroke {
        InkStroke(kind: kind, color: color, width: width, pressure: pressure, points: points.map {
            var p = $0
            p.x += Float(offset.width)
            p.y += Float(offset.height)
            return p
        })
    }

    // The same stroke scaled and/or rotated (lasso resize/rotate handles). Width scales with the transform's
    // magnitude so a bigger shape doesn't end up with a relatively hairline outline.
    func transformed(by transform: CGAffineTransform) -> InkStroke {
        let scaleFactor = sqrt(transform.a * transform.a + transform.b * transform.b)
        return InkStroke(kind: kind, color: color, width: width * Float(scaleFactor), pressure: pressure, points: points.map {
            let moved = CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)).applying(transform)
            var p = $0
            p.x = Float(moved.x)
            p.y = Float(moved.y)
            return p
        })
    }

    private static func bounds(of points: [InkPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
    }

    // Points are stored flat (x, y, force, time) to keep the file small.
    private enum CodingKeys: String, CodingKey { case id, kind, color, width, pressure, pts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let flat = try container.decode([Float].self, forKey: .pts)
        let color = try container.decode([Float].self, forKey: .color)
        guard flat.count >= 4, flat.count % 4 == 0, color.count == 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Malformed stroke"))
        }
        let points = stride(from: 0, to: flat.count, by: 4).map {
            InkPoint(x: flat[$0], y: flat[$0 + 1], force: flat[$0 + 2], time: flat[$0 + 3])
        }
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  kind: try container.decode(InkKind.self, forKey: .kind),
                  color: color,
                  width: try container.decode(Float.self, forKey: .width),
                  pressure: try container.decodeIfPresent(Float.self, forKey: .pressure) ?? 0, // files from before pressure
                  points: points)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(color, forKey: .color)
        try container.encode(width, forKey: .width)
        try container.encode(pressure, forKey: .pressure)
        try container.encode(points.flatMap { [$0.x, $0.y, $0.force, $0.time] }, forKey: .pts)
    }
}

// What one page file holds on disk.
struct InkPageFile: Codable {
    var version = 1
    var strokes: [InkStroke]
}

// A stretch of a stroke drawn at one width. A pressure-sensitive stroke is a chain of runs whose widths follow the pen force.
struct InkRun {
    var points: [InkPoint]
    var width: CGFloat
}

enum InkGeometry {
    // Smooth curve through the samples: quadratic segments between midpoints, the samples being the controls.
    static func path(_ points: [InkPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first.cg)
        switch points.count {
        case 1:
            path.addLine(to: first.cg) // zero-length line: a dot with round caps
        case 2:
            path.addLine(to: points[1].cg)
        default:
            for i in 1..<(points.count - 1) {
                let control = points[i].cg
                let next = points[i + 1].cg
                path.addQuadCurve(to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2), control: control)
            }
            path.addLine(to: points[points.count - 1].cg)
        }
        return path
    }

    // How much wider or thinner than the base width a point is drawn. Force is stored as a fraction of the pencil's
    // maximum and ordinary writing stays below about 40% of it, so 40% counts as "firm". A light touch draws thinner,
    // a firm one thicker; `pressure` (the sensitivity setting) scales the effect. 1 at a medium touch.
    static func widthFactor(force: Float, pressure: Float) -> CGFloat {
        let firm = min(max(CGFloat(force) / 0.4, 0), 1)
        return max(0.25, 1 + CGFloat(pressure) * 2 * (firm - 0.4))
    }

    // Splits a stroke into runs of one width each. Force is averaged over five samples and the width only steps
    // when it has really moved, so pen jitter does not chop the stroke into many runs. Neighbouring runs share a point.
    static func runs(of points: [InkPoint], width: Float, pressure: Float) -> [InkRun] {
        guard pressure > 0, points.count > 2 else { return [InkRun(points: points, width: CGFloat(width))] }
        let step = max(CGFloat(width) * 0.1, 0.05)
        let smooth: [Float] = points.indices.map { i in
            let lo = max(0, i - 2), hi = min(points.count - 1, i + 2)
            return points[lo...hi].reduce(0) { $0 + $1.force } / Float(hi - lo + 1)
        }
        func levels(_ i: Int) -> CGFloat {
            widthFactor(force: smooth[i], pressure: pressure) * CGFloat(width) / step
        }
        var runs: [InkRun] = []
        var current = [points[0]]
        var level = max(1, Int(levels(0).rounded()))
        for i in 1..<points.count {
            let x = levels(i)
            current.append(points[i])
            if abs(x - CGFloat(level)) >= 0.75 {
                runs.append(InkRun(points: current, width: CGFloat(level) * step))
                current = [points[i]]
                level = max(1, Int(x.rounded()))
            }
        }
        if current.count > 1 || runs.isEmpty { runs.append(InkRun(points: current, width: CGFloat(level) * step)) }
        return runs
    }

    static func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // Does a circle of `radius` around `p` touch the stroke?
    static func hit(_ stroke: InkStroke, at p: CGPoint, radius: CGFloat) -> Bool {
        let reach = radius + CGFloat(stroke.width) / 2
        guard stroke.bounds.insetBy(dx: -reach, dy: -reach).contains(p) else { return false }
        let points = stroke.points
        if points.count == 1 { return hypot(p.x - points[0].cg.x, p.y - points[0].cg.y) <= reach }
        for i in 1..<points.count where distance(from: p, to: points[i - 1].cg, points[i].cg) <= reach {
            return true
        }
        return false
    }

    // Partial eraser: what is left of the stroke after a circle of `radius` around `center` is taken out of it.
    // nil when the circle does not touch the stroke; an empty array when nothing is left.
    static func cut(_ stroke: InkStroke, around center: CGPoint, radius: CGFloat) -> [InkStroke]? {
        guard hit(stroke, at: center, radius: radius) else { return nil }
        let reach = radius + CGFloat(stroke.width) / 2
        let points = stroke.points
        var pieces: [[InkPoint]] = []
        var current: [InkPoint] = []
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = []
        }
        if hypot(points[0].cg.x - center.x, points[0].cg.y - center.y) >= reach { current = [points[0]] }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if let (lo, hi) = insideInterval(a.cg, b.cg, center: center, reach: reach) {
                if lo > 0 { current.append(lerp(a, b, lo)) } // walked up to the circle
                flush()
                if hi < 1 { current = [lerp(a, b, hi), b] } // came out the other side
            } else {
                if current.isEmpty { current.append(a) }
                current.append(b)
            }
        }
        flush()
        return pieces
            .filter { $0.count >= 2 && ShapeRecognizer.pathLength($0.map(\.cg)) >= 0.3 }
            .map { InkStroke(kind: stroke.kind, color: stroke.color, width: stroke.width, pressure: stroke.pressure, points: $0) }
    }

    // The part of segment a-b (as parameters 0...1) that lies inside the circle, if any.
    private static func insideInterval(_ a: CGPoint, _ b: CGPoint, center: CGPoint, reach: CGFloat) -> (CGFloat, CGFloat)? {
        let dx = b.x - a.x, dy = b.y - a.y
        let fx = a.x - center.x, fy = a.y - center.y
        let qa = dx * dx + dy * dy
        let qc = fx * fx + fy * fy - reach * reach
        guard qa > 0 else { return qc < 0 ? (0, 1) : nil }
        let qb = 2 * (fx * dx + fy * dy)
        let discriminant = qb * qb - 4 * qa * qc
        guard discriminant > 0 else { return nil }
        let root = sqrt(discriminant)
        let lo = max((-qb - root) / (2 * qa), 0), hi = min((-qb + root) / (2 * qa), 1)
        return lo < hi ? (lo, hi) : nil
    }

    private static func lerp(_ a: InkPoint, _ b: InkPoint, _ t: CGFloat) -> InkPoint {
        let t = Float(t)
        return InkPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                        force: a.force + (b.force - a.force) * t, time: a.time + (b.time - a.time) * t)
    }

    // Lasso: a stroke is picked when at least half of its points are inside the loop.
    static func isSelected(_ stroke: InkStroke, by lasso: CGPath) -> Bool {
        let inside = stroke.points.filter { lasso.contains($0.cg, using: .evenOdd) }.count
        return inside * 2 >= stroke.points.count
    }
}

// A lasso "copy" simply remembers the strokes; "paste" re-centers them wherever the user pastes, on any page
// of any open document, the same way the system pasteboard works. Kept in memory only — nothing to persist.
enum InkClipboard {
    private static var strokes: [InkStroke] = []

    static var isEmpty: Bool { strokes.isEmpty }

    static func copy(_ strokes: [InkStroke]) {
        self.strokes = strokes
    }

    static func pasteStrokes(centeredAt center: CGPoint) -> [InkStroke] {
        guard !strokes.isEmpty else { return [] }
        var box = strokes[0].bounds
        for stroke in strokes.dropFirst() { box = box.union(stroke.bounds) }
        let offset = CGSize(width: center.x - box.midX, height: center.y - box.midY)
        return strokes.map { $0.moved(by: offset) } // moved(by:) already mints a fresh id per stroke
    }
}
