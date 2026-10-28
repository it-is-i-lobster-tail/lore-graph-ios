import Foundation

/// A label that wants a place on screen.
public struct LabelCandidate: Hashable, Sendable {
    public var id: String
    public var style: LabelStyle
    /// Where the label's centre goes, in screen points (before `style.offsetY`).
    public var anchor: Point
    /// Rotation in radians for a label along a line; 0 for a level one.
    public var angle: Double
    /// Drawn before others of the same rank (the selected feature, a pinned place).
    public var boosted: Bool

    public init(id: String, style: LabelStyle, anchor: Point, angle: Double = 0, boosted: Bool = false) {
        self.id = id
        self.style = style
        self.anchor = anchor
        self.angle = angle
        self.boosted = boosted
    }
}

/// A label given a place: its centre and the box it keeps clear.
public struct PlacedLabel: Hashable, Sendable, Identifiable {
    public var candidate: LabelCandidate
    public var centre: Point
    public var frame: Rect

    public var id: String { candidate.id }
}

/// Places map labels greedily, most important first, so none overlap (DESIGN.md 13.3: realms
/// before towns, the selected place before its rank). The same name is not repeated close by,
/// which happens where a line is cut at tile edges.
public enum LabelPlacer {
    /// The size of a label's text, estimated from its length (the canvas measures nothing).
    public static func size(of style: LabelStyle) -> Size {
        let text = style.shownText
        let perChar = style.fontSize * (style.serif ? 0.56 : 0.54)
        return Size(Double(text.count) * perChar + 4, style.fontSize * 1.3)
    }

    /// Where a label along a line goes: the middle of the line's visible length, turned to the
    /// line there but never upside down. Nil when the line is shorter than the label.
    public static func lineAnchor(_ points: [Point], minLength: Double) -> (Point, Double)? {
        guard points.count >= 2 else { return nil }
        var lengths: [Double] = []
        var total = 0.0
        for i in 1..<points.count {
            let d = points[i].distance(to: points[i - 1])
            lengths.append(d)
            total += d
        }
        guard total >= minLength, total > 0 else { return nil }
        var target = total / 2
        for (i, d) in lengths.enumerated() {
            if target <= d, d > 0 {
                let a = points[i], b = points[i + 1]
                let t = target / d
                var angle = atan2(b.y - a.y, b.x - a.x)
                if angle > .pi / 2 { angle -= .pi } else if angle < -.pi / 2 { angle += .pi }
                return (Point(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t), angle)
            }
            target -= d
        }
        return nil
    }

    /// The labels that fit, in drawing order. A label must have its centre inside `bounds`.
    public static func place(_ candidates: [LabelCandidate], in bounds: Rect, padding: Double = 3,
                             repeatDistance: Double = 180, limit: Int = 500) -> [PlacedLabel] {
        let ordered = candidates.sorted { a, b in
            if a.boosted != b.boosted { return a.boosted }
            if a.style.rank != b.style.rank { return a.style.rank < b.style.rank }
            return a.id < b.id
        }
        var grid = Grid(cell: 64)
        var placed: [PlacedLabel] = []
        var byText: [String: [Point]] = [:]
        for c in ordered {
            guard placed.count < limit else { break }
            let centre = Point(c.anchor.x, c.anchor.y + c.style.offsetY)
            guard bounds.contains(centre) else { continue }
            if let seen = byText[c.style.text], seen.contains(where: { $0.distance(to: centre) < repeatDistance }) {
                continue
            }
            let frame = box(centre: centre, size: size(of: c.style), angle: c.angle).insetBy(-padding)
            guard !grid.hits(frame) else { continue }
            grid.insert(frame)
            byText[c.style.text, default: []].append(centre)
            placed.append(PlacedLabel(candidate: c, centre: centre, frame: frame))
        }
        return placed
    }

    /// The upright box around a turned label.
    static func box(centre: Point, size: Size, angle: Double) -> Rect {
        guard angle != 0 else { return Rect(centre: centre, size: size) }
        let c = abs(cos(angle)), s = abs(sin(angle))
        return Rect(centre: centre, size: Size(size.width * c + size.height * s, size.width * s + size.height * c))
    }

    /// A bucket grid of placed boxes, so each test looks only at its neighbours.
    struct Grid {
        let cell: Double
        var buckets: [Int64: [Rect]] = [:]

        init(cell: Double) {
            self.cell = cell
        }

        func keys(_ r: Rect) -> [Int64] {
            let x0 = Int64(floor(r.minX / cell)), x1 = Int64(floor(r.maxX / cell))
            let y0 = Int64(floor(r.minY / cell)), y1 = Int64(floor(r.maxY / cell))
            var out: [Int64] = []
            for x in x0...x1 { for y in y0...y1 { out.append(x &* 1_000_003 &+ y) } }
            return out
        }

        func hits(_ r: Rect) -> Bool {
            keys(r).contains { k in buckets[k]?.contains { $0.intersects(r) } ?? false }
        }

        mutating func insert(_ r: Rect) {
            for k in keys(r) { buckets[k, default: []].append(r) }
        }
    }
}
