import Foundation

/// loregraph's display projection and tile grid (DESIGN.md 13.2): equirectangular, true to
/// scale at 45° N on the sphere, square 256 px tiles counted from the top left. The same
/// numbers are in the database, the backend (app/mapping/coords.py) and the web app.
public enum MapProjection {
    public static let radius = 6_371_008.8
    public static let cos45 = cos(Double.pi / 4)
    public static let halfWidth = radius * cos45 * .pi        // 14,152,823.148 m
    public static let halfHeight = radius * .pi / 2            // 10,007,557.221 m
    public static let tileMetres = 2 * halfWidth               // a z0 tile, square
    public static let tileSize = 256.0
    public static let maxZoom = 16

    /// Longitude and latitude to map metres (x east, y north).
    public static func toMap(_ p: LonLat) -> Point {
        Point(radius * cos45 * p.lon * .pi / 180, radius * p.lat * .pi / 180)
    }

    public static func toLonLat(_ m: Point) -> LonLat {
        LonLat(m.x / (radius * cos45) * 180 / .pi, m.y / radius * 180 / .pi)
    }

    /// Metres per pixel at a zoom (true at 45° N).
    public static func resolution(_ zoom: Double) -> Double {
        tileMetres / tileSize / pow(2, zoom)
    }

    /// True metres per pixel east–west at a latitude (for the scale bar and measuring).
    public static func groundResolution(_ zoom: Double, latitude: Double) -> Double {
        resolution(zoom) * cos(latitude * .pi / 180) / cos45
    }

    /// The tile's bounds in map metres: west, south, east, north.
    public static func tileBounds(_ t: TileID) -> (west: Double, south: Double, east: Double, north: Double) {
        let size = tileMetres / pow(2, Double(t.z))
        let west = -halfWidth + Double(t.x) * size
        let north = halfHeight - Double(t.y) * size
        return (west, north - size, west + size, north)
    }

    /// The number of tiles across and down at a zoom (the grid is wider than tall).
    public static func tileCount(_ z: Int) -> (x: Int, y: Int) {
        let n = 1 << z
        let rows = Int((2 * halfHeight / (tileMetres / Double(n))).rounded(.up))
        return (n, rows)
    }

    /// The tile holding a point at a zoom.
    public static func tile(at m: Point, zoom z: Int) -> TileID {
        let size = tileMetres / pow(2, Double(z))
        let count = tileCount(z)
        let x = Int(floor((m.x + halfWidth) / size))
        let y = Int(floor((halfHeight - m.y) / size))
        return TileID(z: z, x: min(max(0, x), count.x - 1), y: min(max(0, y), count.y - 1))
    }

    /// Great-circle distance on the world sphere in kilometres (never a distance on the flat map).
    public static func greatCircleKm(_ a: LonLat, _ b: LonLat) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.lat - a.lat) * rad
        let dLon = (b.lon - a.lon) * rad
        let h = pow(sin(dLat / 2), 2) + cos(a.lat * rad) * cos(b.lat * rad) * pow(sin(dLon / 2), 2)
        return 2 * radius * asin(min(1, h.squareRoot())) / 1000
    }

    /// "26.06° E 45.13° N".
    public static func format(_ p: LonLat, digits: Int = 2) -> String {
        String(format: "%.\(digits)f° %@ %.\(digits)f° %@", abs(p.lon), p.lon < 0 ? "W" : "E", abs(p.lat), p.lat < 0 ? "S" : "N")
    }

    /// A scale bar for a width in points: a round length in km (or m) and its width (F-7.11).
    public static func scaleBar(zoom: Double, latitude: Double, maxPoints: Double = 110) -> (label: String, points: Double) {
        let metresPerPoint = groundResolution(zoom, latitude: latitude)
        let maxMetres = metresPerPoint * maxPoints
        let candidates: [Double] = [5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000,
                                    200_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
        let metres = candidates.last { $0 <= maxMetres } ?? candidates[0]
        let label = metres >= 1000 ? "\(Int(metres / 1000)) km" : "\(Int(metres)) m"
        return (label, metres / metresPerPoint)
    }
}

/// A tile of the grid.
public struct TileID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var z: Int
    public var x: Int
    public var y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    /// The tile one level up that holds this one, and where this one sits in it (0 or 1).
    public var parent: (tile: TileID, dx: Int, dy: Int)? {
        guard z > 0 else { return nil }
        return (TileID(z: z - 1, x: x / 2, y: y / 2), x % 2, y % 2)
    }
}

/// What the map shows: a centre in map metres, a fractional zoom and the screen size in points.
/// Converts between screen and map, and lists the tiles to draw (F-7.1).
public struct Viewport: Hashable, Sendable, Codable {
    public var centre: Point
    public var zoom: Double
    public var size: Size
    public var minZoom: Double = 0
    public var maxZoom: Double = Double(MapProjection.maxZoom)

    public init(centre: Point, zoom: Double, size: Size) {
        self.centre = centre
        self.zoom = zoom
        self.size = size
    }

    public init(centre: LonLat, zoom: Double, size: Size) {
        self.init(centre: MapProjection.toMap(centre), zoom: zoom, size: size)
    }

    /// Metres per point at the current zoom.
    public var resolution: Double { MapProjection.resolution(zoom) }

    public var centreLonLat: LonLat { MapProjection.toLonLat(centre) }

    public func toScreen(_ m: Point) -> Point {
        let r = resolution
        return Point((m.x - centre.x) / r + size.width / 2, (centre.y - m.y) / r + size.height / 2)
    }

    public func toMap(_ s: Point) -> Point {
        let r = resolution
        return Point(centre.x + (s.x - size.width / 2) * r, centre.y - (s.y - size.height / 2) * r)
    }

    public func toScreen(_ p: LonLat) -> Point { toScreen(MapProjection.toMap(p)) }
    public func toLonLat(_ s: Point) -> LonLat { MapProjection.toLonLat(toMap(s)) }

    /// The visible area in degrees: west, south, east, north, clamped to the world.
    public var bbox: (Double, Double, Double, Double) {
        let a = toLonLat(Point(0, size.height)), b = toLonLat(Point(size.width, 0))
        return (max(-180, a.lon), max(-90, a.lat), min(180, b.lon), min(90, b.lat))
    }

    /// The tile zoom to draw at: the level whose pixels are closest to a point, never past the
    /// layer's limit (deeper zooms magnify the last level).
    public func tileZoom(limit: Int = MapProjection.maxZoom) -> Int {
        max(0, min(limit, Int((zoom + 0.25).rounded(.down))))
    }

    /// The tiles covering the screen at a tile zoom, centre first.
    public func tiles(at z: Int) -> [TileID] {
        let tl = toMap(Point(0, 0)), br = toMap(Point(size.width, size.height))
        let a = MapProjection.tile(at: tl, zoom: z), b = MapProjection.tile(at: br, zoom: z)
        var out: [TileID] = []
        for y in min(a.y, b.y)...max(a.y, b.y) {
            for x in min(a.x, b.x)...max(a.x, b.x) { out.append(TileID(z: z, x: x, y: y)) }
        }
        let c = MapProjection.tile(at: centre, zoom: z)
        return out.sorted { abs($0.x - c.x) + abs($0.y - c.y) < abs($1.x - c.x) + abs($1.y - c.y) }
    }

    /// Where a tile lands on screen.
    public func frame(of t: TileID) -> Rect {
        let b = MapProjection.tileBounds(t)
        let tl = toScreen(Point(b.west, b.north)), br = toScreen(Point(b.east, b.south))
        return Rect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
    }

    /// Moved by a drag in points.
    public func panned(by d: Point) -> Viewport {
        var v = self
        v.centre = Point(centre.x - d.x * resolution, centre.y + d.y * resolution)
        return v.clamped()
    }

    /// Zoomed by a factor around a screen point (a pinch keeps the point under the fingers).
    public func zoomed(by factor: Double, around s: Point) -> Viewport {
        let anchor = toMap(s)
        var v = self
        v.zoom = min(maxZoom, max(minZoom, zoom + log2(max(0.0001, factor))))
        let after = v.toMap(s)
        v.centre = Point(centre.x + anchor.x - after.x, centre.y + anchor.y - after.y)
        return v.clamped()
    }

    /// Showing a box of map metres with some padding.
    public func fitting(_ box: Rect, padding: Double = 40, maxZoom fitMax: Double = 12) -> Viewport {
        var v = self
        v.centre = box.centre
        let w = max(1, size.width - 2 * padding), h = max(1, size.height - 2 * padding)
        let res = max(box.size.width / w, box.size.height / h)
        v.zoom = res > 0 ? min(fitMax, max(minZoom, log2(MapProjection.tileMetres / MapProjection.tileSize / res))) : fitMax
        return v.clamped()
    }

    /// Keeps the centre on the world.
    public func clamped() -> Viewport {
        var v = self
        v.zoom = min(maxZoom, max(minZoom, zoom))
        v.centre = Point(min(max(centre.x, -MapProjection.halfWidth), MapProjection.halfWidth),
                         min(max(centre.y, -MapProjection.halfHeight), MapProjection.halfHeight))
        return v
    }
}
