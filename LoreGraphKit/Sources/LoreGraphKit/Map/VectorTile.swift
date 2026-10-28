import Foundation

/// A decoded Mapbox Vector Tile (spec 2.1): layers of features with properties and geometry in
/// tile units (0 to `extent`, y down). A small protobuf reader stands in for a protobuf library.
public struct VectorTile: Sendable, Hashable {
    public enum GeometryType: Int, Sendable, Hashable { case unknown = 0, point = 1, line = 2, polygon = 3 }

    public struct Feature: Sendable, Hashable {
        public var id: UInt64?
        public var type: GeometryType
        public var properties: [String: JSONValue]
        /// Points, lines, or polygon rings, in tile units.
        public var geometry: [[Point]]
    }

    public struct Layer: Sendable, Hashable {
        public var name: String
        public var extent: Int
        public var features: [Feature]
    }

    public var layers: [Layer]

    public func layer(_ name: String) -> Layer? { layers.first { $0.name == name } }

    public init(layers: [Layer]) {
        self.layers = layers
    }

    public init(data: Data) throws {
        var r = ProtoReader([UInt8](data))
        var layers: [Layer] = []
        while let (field, wire) = try r.key() {
            if field == 3, wire == 2 {
                layers.append(try Self.layer(try r.bytes()))
            } else {
                try r.skip(wire)
            }
        }
        self.layers = layers
    }

    static func layer(_ bytes: [UInt8]) throws -> Layer {
        var r = ProtoReader(bytes)
        var name = "", extent = 4096
        var keys: [String] = []
        var values: [JSONValue] = []
        var raw: [[UInt8]] = []
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 2): name = try r.string()
            case (2, 2): raw.append(try r.bytes())
            case (3, 2): keys.append(try r.string())
            case (4, 2): values.append(try value(try r.bytes()))
            case (5, 0): extent = Int(try r.varint())
            default: try r.skip(wire)
            }
        }
        let features = try raw.map { try feature($0, keys: keys, values: values) }
        return Layer(name: name, extent: extent, features: features)
    }

    static func value(_ bytes: [UInt8]) throws -> JSONValue {
        var r = ProtoReader(bytes)
        var out = JSONValue.null
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 2): out = .string(try r.string())
            case (2, 5): out = .number(Double(Float(bitPattern: try r.fixed32())))
            case (3, 1): out = .number(Double(bitPattern: try r.fixed64()))
            case (4, 0): out = .number(Double(Int64(bitPattern: try r.varint())))
            case (5, 0): out = .number(Double(try r.varint()))
            case (6, 0): out = .number(Double(ProtoReader.zigzag(try r.varint())))
            case (7, 0): out = .bool(try r.varint() != 0)
            default: try r.skip(wire)
            }
        }
        return out
    }

    static func feature(_ bytes: [UInt8], keys: [String], values: [JSONValue]) throws -> Feature {
        var r = ProtoReader(bytes)
        var id: UInt64?
        var type = GeometryType.unknown
        var tags: [UInt64] = []
        var geometry: [UInt32] = []
        while let (field, wire) = try r.key() {
            switch (field, wire) {
            case (1, 0): id = try r.varint()
            case (2, 2): tags = try r.packedVarints()
            case (3, 0): type = GeometryType(rawValue: Int(try r.varint())) ?? .unknown
            case (4, 2): geometry = try r.packedVarints().map { UInt32(truncatingIfNeeded: $0) }
            default: try r.skip(wire)
            }
        }
        var props: [String: JSONValue] = [:]
        var i = 0
        while i + 1 < tags.count {
            let k = Int(tags[i]), v = Int(tags[i + 1])
            if k < keys.count, v < values.count { props[keys[k]] = values[v] }
            i += 2
        }
        return Feature(id: id, type: type, properties: props, geometry: decodeGeometry(geometry, type: type))
    }

    /// Geometry commands (MoveTo, LineTo, ClosePath) with zigzag deltas to point lists.
    static func decodeGeometry(_ cmds: [UInt32], type: GeometryType) -> [[Point]] {
        var out: [[Point]] = []
        var current: [Point] = []
        var x: Int64 = 0, y: Int64 = 0
        var i = 0
        while i < cmds.count {
            let cmd = cmds[i] & 0x7, count = Int(cmds[i] >> 3)
            i += 1
            switch cmd {
            case 1, 2:
                for _ in 0..<count {
                    guard i + 1 < cmds.count else { break }
                    x += ProtoReader.zigzag(UInt64(cmds[i]))
                    y += ProtoReader.zigzag(UInt64(cmds[i + 1]))
                    i += 2
                    if cmd == 1 {
                        if !current.isEmpty, type != .point { out.append(current); current = [] }
                    }
                    current.append(Point(Double(x), Double(y)))
                }
            case 7:
                if let first = current.first { current.append(first) }
            default:
                i = cmds.count
            }
        }
        if !current.isEmpty {
            if type == .point { out += current.map { [$0] } } else { out.append(current) }
        }
        return out
    }
}

public struct ProtoError: Error, Hashable {
    public let message: String
}

/// Reads protobuf wire format: varints, fixed numbers and length-delimited fields.
struct ProtoReader {
    let buf: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) {
        self.buf = bytes
    }

    mutating func key() throws -> (Int, Int)? {
        guard i < buf.count else { return nil }
        let k = try varint()
        return (Int(k >> 3), Int(k & 7))
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard i < buf.count, shift < 64 else { throw ProtoError(message: "truncated varint") }
            let b = buf[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func bytes() throws -> [UInt8] {
        let n = Int(try varint())
        guard n >= 0, i + n <= buf.count else { throw ProtoError(message: "truncated field") }
        defer { i += n }
        return Array(buf[i..<(i + n)])
    }

    mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    mutating func fixed32() throws -> UInt32 {
        guard i + 4 <= buf.count else { throw ProtoError(message: "truncated fixed32") }
        defer { i += 4 }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(buf[i + $1]) << (8 * UInt32($1)) }
    }

    mutating func fixed64() throws -> UInt64 {
        guard i + 8 <= buf.count else { throw ProtoError(message: "truncated fixed64") }
        defer { i += 8 }
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(buf[i + $1]) << (8 * UInt64($1)) }
    }

    mutating func packedVarints() throws -> [UInt64] {
        var sub = ProtoReader(try bytes())
        var out: [UInt64] = []
        while sub.i < sub.buf.count { out.append(try sub.varint()) }
        return out
    }

    mutating func skip(_ wire: Int) throws {
        switch wire {
        case 0: _ = try varint()
        case 1: guard i + 8 <= buf.count else { throw ProtoError(message: "truncated") }; i += 8
        case 2: _ = try bytes()
        case 5: guard i + 4 <= buf.count else { throw ProtoError(message: "truncated") }; i += 4
        default: throw ProtoError(message: "unknown wire type \(wire)")
        }
    }

    static func zigzag(_ n: UInt64) -> Int64 {
        Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1)))
    }
}
