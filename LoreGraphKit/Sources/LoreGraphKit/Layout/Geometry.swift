import Foundation

/// A point in layout space (points on screen, or metres on the map). Kept apart from
/// CoreGraphics so layouts are computed and tested on any platform.
public struct Point: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(0, 0)

    public static func + (a: Point, b: Point) -> Point { Point(a.x + b.x, a.y + b.y) }
    public static func - (a: Point, b: Point) -> Point { Point(a.x - b.x, a.y - b.y) }
    public static func * (a: Point, k: Double) -> Point { Point(a.x * k, a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to p: Point) -> Double { (self - p).length }
}

public struct Size: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Hashable, Sendable, Codable {
    public var origin: Point
    public var size: Size

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x, y)
        size = Size(width, height)
    }

    public init(centre: Point, size: Size) {
        origin = Point(centre.x - size.width / 2, centre.y - size.height / 2)
        self.size = size
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var centre: Point { Point(origin.x + size.width / 2, origin.y + size.height / 2) }

    public func intersects(_ r: Rect) -> Bool {
        minX < r.maxX && r.minX < maxX && minY < r.maxY && r.minY < maxY
    }

    public func contains(_ p: Point) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: minX + d, y: minY + d, width: max(0, size.width - 2 * d), height: max(0, size.height - 2 * d))
    }

    /// The smallest rectangle holding both.
    public func union(_ r: Rect) -> Rect {
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        return Rect(x: x0, y: y0, width: max(maxX, r.maxX) - x0, height: max(maxY, r.maxY) - y0)
    }

    public static func bounding(_ points: [Point]) -> Rect? {
        guard let f = points.first else { return nil }
        var r = Rect(x: f.x, y: f.y, width: 0, height: 0)
        for p in points.dropFirst() { r = r.union(Rect(x: p.x, y: p.y, width: 0, height: 0)) }
        return r
    }
}
