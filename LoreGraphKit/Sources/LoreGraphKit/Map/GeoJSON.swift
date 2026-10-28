import Foundation

/// A longitude and latitude in degrees.
public struct LonLat: Codable, Hashable, Sendable {
    public var lon: Double
    public var lat: Double

    public init(_ lon: Double, _ lat: Double) {
        self.lon = lon
        self.lat = lat
    }
}

/// GeoJSON geometry (RFC 7946) in longitude and latitude, as map.features and entity shapes
/// return it. Rings and lines are lists of points.
public enum GeoJSONGeometry: Codable, Hashable, Sendable {
    case point(LonLat)
    case multiPoint([LonLat])
    case lineString([LonLat])
    case multiLineString([[LonLat]])
    case polygon([[LonLat]])
    case multiPolygon([[[LonLat]]])
    case collection([GeoJSONGeometry])

    private enum Keys: String, CodingKey { case type, coordinates, geometries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        func pt(_ a: [Double]) throws -> LonLat {
            guard a.count >= 2 else {
                throw DecodingError.dataCorruptedError(forKey: .coordinates, in: c, debugDescription: "a position needs two numbers")
            }
            return LonLat(a[0], a[1])
        }
        switch type {
        case "Point": self = .point(try pt(try c.decode([Double].self, forKey: .coordinates)))
        case "MultiPoint": self = .multiPoint(try c.decode([[Double]].self, forKey: .coordinates).map(pt))
        case "LineString": self = .lineString(try c.decode([[Double]].self, forKey: .coordinates).map(pt))
        case "MultiLineString":
            self = .multiLineString(try c.decode([[[Double]]].self, forKey: .coordinates).map { try $0.map(pt) })
        case "Polygon":
            self = .polygon(try c.decode([[[Double]]].self, forKey: .coordinates).map { try $0.map(pt) })
        case "MultiPolygon":
            self = .multiPolygon(try c.decode([[[[Double]]]].self, forKey: .coordinates).map { try $0.map { try $0.map(pt) } })
        case "GeometryCollection": self = .collection(try c.decode([GeoJSONGeometry].self, forKey: .geometries))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown geometry \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        func raw(_ p: LonLat) -> [Double] { [p.lon, p.lat] }
        switch self {
        case .point(let p):
            try c.encode("Point", forKey: .type)
            try c.encode(raw(p), forKey: .coordinates)
        case .multiPoint(let ps):
            try c.encode("MultiPoint", forKey: .type)
            try c.encode(ps.map(raw), forKey: .coordinates)
        case .lineString(let ps):
            try c.encode("LineString", forKey: .type)
            try c.encode(ps.map(raw), forKey: .coordinates)
        case .multiLineString(let ls):
            try c.encode("MultiLineString", forKey: .type)
            try c.encode(ls.map { $0.map(raw) }, forKey: .coordinates)
        case .polygon(let rings):
            try c.encode("Polygon", forKey: .type)
            try c.encode(rings.map { $0.map(raw) }, forKey: .coordinates)
        case .multiPolygon(let polys):
            try c.encode("MultiPolygon", forKey: .type)
            try c.encode(polys.map { $0.map { $0.map(raw) } }, forKey: .coordinates)
        case .collection(let gs):
            try c.encode("GeometryCollection", forKey: .type)
            try c.encode(gs, forKey: .geometries)
        }
    }

    /// Every position, flattened.
    public var positions: [LonLat] {
        switch self {
        case .point(let p): [p]
        case .multiPoint(let ps), .lineString(let ps): ps
        case .multiLineString(let ls), .polygon(let ls): ls.flatMap { $0 }
        case .multiPolygon(let ps): ps.flatMap { $0.flatMap { $0 } }
        case .collection(let gs): gs.flatMap(\.positions)
        }
    }

    /// West, south, east, north.
    public var bounds: (west: Double, south: Double, east: Double, north: Double)? {
        let ps = positions
        guard let first = ps.first else { return nil }
        var b = (west: first.lon, south: first.lat, east: first.lon, north: first.lat)
        for p in ps.dropFirst() {
            b.west = min(b.west, p.lon)
            b.east = max(b.east, p.lon)
            b.south = min(b.south, p.lat)
            b.north = max(b.north, p.lat)
        }
        return b
    }

    /// The middle of the bounds (a point is its own centre).
    public var centre: (lon: Double, lat: Double)? {
        if case .point(let p) = self { return (p.lon, p.lat) }
        guard let b = bounds else { return nil }
        return ((b.west + b.east) / 2, (b.south + b.north) / 2)
    }

    public var isPoint: Bool {
        switch self {
        case .point, .multiPoint: true
        default: false
        }
    }
}

/// A GeoJSON feature with free-form properties.
public struct GeoJSONFeature: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var geometry: GeoJSONGeometry?
    public var properties: [String: JSONValue]

    private enum Keys: String, CodingKey { case id, geometry, properties }

    public init(id: String, geometry: GeoJSONGeometry?, properties: [String: JSONValue]) {
        self.id = id
        self.geometry = geometry
        self.properties = properties
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        geometry = try c.decodeIfPresent(GeoJSONGeometry.self, forKey: .geometry)
        properties = try c.decodeIfPresent([String: JSONValue].self, forKey: .properties) ?? [:]
        if let s = try? c.decode(String.self, forKey: .id) {
            id = s
        } else if let n = try? c.decode(Int.self, forKey: .id) {
            id = String(n)
        } else {
            id = properties["shape_id"]?.string ?? properties["id"]?.string ?? UUID().uuidString
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(geometry, forKey: .geometry)
        try c.encode(properties, forKey: .properties)
    }

    public var layer: String? { properties["layer"]?.string }
    public var label: String? { properties["label"]?.string }
    /// The page the feature stands for (`entity`, `traveller` or `ruler` card).
    public var entityRef: String? {
        properties["slug"]?.string ?? properties["entity"]?["ref"]?.string
            ?? properties["traveller"]?["ref"]?.string ?? properties["ruler"]?["ref"]?.string
    }
}

/// map.features and map.territories answers.
public struct GeoJSONCollection: Codable, Hashable, Sendable {
    public var features: [GeoJSONFeature]
    public var truncated: Bool?
    public var year: Double?
    public var mapVersion: Int?
    public var warnings: [String]?
}
