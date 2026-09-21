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
    let points: [InkPoint]
    let bounds: CGRect // derived from the points, not stored

    init(id: UUID = UUID(), kind: InkKind, color: [Float], width: Float, points: [InkPoint]) {
        self.id = id
        self.kind = kind
        self.color = color
        self.width = width
        self.points = points
        self.bounds = InkStroke.bounds(of: points)
    }

    static func uiColor(_ rgba: [Float]) -> UIColor {
        guard rgba.count == 4 else { return .black }
        return UIColor(red: CGFloat(rgba[0]), green: CGFloat(rgba[1]), blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3]))
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
    private enum CodingKeys: String, CodingKey { case id, kind, color, width, pts }

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
                  points: points)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(color, forKey: .color)
        try container.encode(width, forKey: .width)
        try container.encode(points.flatMap { [$0.x, $0.y, $0.force, $0.time] }, forKey: .pts)
    }
}

// What one page file holds on disk.
struct InkPageFile: Codable {
    var version = 1
    var strokes: [InkStroke]
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
}
