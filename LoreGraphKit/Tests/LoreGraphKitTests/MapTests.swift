import Foundation
import Testing
@testable import LoreGraphKit

/// Writes protobuf wire format, to build vector tiles by hand.
struct ProtoWriter {
    var bytes: [UInt8] = []

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 {
            bytes.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    mutating func key(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    mutating func field(_ field: Int, varint v: UInt64) {
        key(field, 0)
        varint(v)
    }

    mutating func field(_ field: Int, bytes b: [UInt8]) {
        key(field, 2)
        varint(UInt64(b.count))
        bytes += b
    }

    mutating func field(_ field: Int, string s: String) { self.field(field, bytes: Array(s.utf8)) }

    mutating func field(_ field: Int, packed values: [UInt64]) {
        var inner = ProtoWriter()
        for v in values { inner.varint(v) }
        self.field(field, bytes: inner.bytes)
    }

    mutating func fixed32(_ field: Int, _ v: UInt32) {
        key(field, 5)
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) }
    }

    mutating func fixed64(_ field: Int, _ v: UInt64) {
        key(field, 1)
        for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    static func zigzag(_ n: Int64) -> UInt64 { UInt64(bitPattern: (n << 1) ^ (n >> 63)) }

    /// Geometry commands for parts (MoveTo, LineTo, optionally ClosePath).
    static func geometry(_ parts: [[(Int64, Int64)]], close: Bool) -> [UInt64] {
        var out: [UInt64] = []
        var x: Int64 = 0, y: Int64 = 0
        for part in parts {
            guard let first = part.first else { continue }
            out.append(UInt64(1 | (1 << 3)))
            out += [zigzag(first.0 - x), zigzag(first.1 - y)]
            (x, y) = first
            let rest = part.dropFirst()
            if !rest.isEmpty {
                out.append(UInt64(2 | (rest.count << 3)))
                for p in rest {
                    out += [zigzag(p.0 - x), zigzag(p.1 - y)]
                    (x, y) = p
                }
            }
            if close { out.append(UInt64(7 | (1 << 3))) }
        }
        return out
    }
}

/// A one-layer tile with features given as (type, properties, parts).
func makeTile(layer: String = "places", extent: Int = 4096,
              features: [(VectorTile.GeometryType, [String: JSONValue], [[(Int64, Int64)]])]) -> Data {
    var keys: [String] = []
    var values: [JSONValue] = []
    var layerW = ProtoWriter()
    layerW.field(15, varint: 2)   // version
    layerW.field(1, string: layer)
    for (i, f) in features.enumerated() {
        var fw = ProtoWriter()
        fw.field(1, varint: UInt64(i + 1))
        var tags: [UInt64] = []
        for (k, v) in f.1.sorted(by: { $0.key < $1.key }) {
            let ki = keys.firstIndex(of: k) ?? { keys.append(k); return keys.count - 1 }()
            let vi = values.firstIndex(of: v) ?? { values.append(v); return values.count - 1 }()
            tags += [UInt64(ki), UInt64(vi)]
        }
        fw.field(2, packed: tags)
        fw.field(3, varint: UInt64(f.0.rawValue))
        fw.field(4, packed: ProtoWriter.geometry(f.2, close: f.0 == .polygon))
        layerW.field(2, bytes: fw.bytes)
    }
    for k in keys { layerW.field(3, string: k) }
    for v in values {
        var vw = ProtoWriter()
        switch v {
        case .string(let s): vw.field(1, string: s)
        case .number(let n):
            if n.rounded() == n, n >= 0 { vw.field(5, varint: UInt64(n)) } else { vw.fixed64(3, n.bitPattern) }
        case .bool(let b): vw.field(7, varint: b ? 1 : 0)
        default: break
        }
        layerW.field(4, bytes: vw.bytes)
    }
    layerW.field(5, varint: UInt64(extent))
    var tile = ProtoWriter()
    tile.field(3, bytes: layerW.bytes)
    tile.field(9, varint: 1)   // an unknown field is skipped
    return Data(tile.bytes)
}

@Suite struct ProjectionTests {
    @Test func projectsAndBack() {
        let p = LonLat(26.06, 45.13)
        let m = MapProjection.toMap(p)
        let back = MapProjection.toLonLat(m)
        #expect(abs(back.lon - p.lon) < 1e-9 && abs(back.lat - p.lat) < 1e-9)
        #expect(abs(MapProjection.halfWidth - 14_152_823.148) < 0.01)
        #expect(abs(MapProjection.halfHeight - 10_007_557.221) < 0.01)
        #expect(abs(MapProjection.toMap(LonLat(180, 90)).x - MapProjection.halfWidth) < 1e-6)
    }

    @Test func tileGrid() {
        #expect(MapProjection.tileCount(0) == (1, 1))
        #expect(MapProjection.tileCount(3).x == 8)
        #expect(MapProjection.tileCount(3).y == 6)
        let b = MapProjection.tileBounds(TileID(z: 0, x: 0, y: 0))
        #expect(b.west == -MapProjection.halfWidth && b.north == MapProjection.halfHeight)
        let t = MapProjection.tile(at: MapProjection.toMap(LonLat(11.1, 45.5)), zoom: 5)
        #expect(t == TileID(z: 5, x: 16, y: 5))
        #expect(MapProjection.tile(at: Point(-1e9, 1e9), zoom: 2) == TileID(z: 2, x: 0, y: 0))
        #expect(TileID(z: 5, x: 16, y: 5).description == "5/16/5")
        let parent = TileID(z: 5, x: 17, y: 5).parent
        #expect(parent?.tile == TileID(z: 4, x: 8, y: 2) && parent?.dx == 1 && parent?.dy == 1)
        #expect(TileID(z: 0, x: 0, y: 0).parent == nil)
    }

    @Test func distancesAndScale() {
        let km = MapProjection.greatCircleKm(LonLat(0, 0), LonLat(0, 1))
        #expect(abs(km - 111.19) < 0.1)
        #expect(MapProjection.groundResolution(5, latitude: 45) - MapProjection.resolution(5) < 1e-9)
        #expect(MapProjection.format(LonLat(-1.234, -5.678)) == "1.23° W 5.68° S")
        #expect(MapProjection.format(LonLat(1, 2), digits: 0) == "1° E 2° N")
        let bar = MapProjection.scaleBar(zoom: 5, latitude: 45)
        #expect(bar.label.hasSuffix("km"))
        #expect(bar.points <= 110 && bar.points > 20)
        #expect(MapProjection.scaleBar(zoom: 16, latitude: 45).label.hasSuffix(" m"))
        #expect(MapProjection.scaleBar(zoom: 30, latitude: 45).label == "5 m")
    }

    @Test func viewportConvertsAndMoves() {
        var v = Viewport(centre: LonLat(11, 45.5), zoom: 5, size: Size(400, 800))
        let centre = v.toScreen(LonLat(11, 45.5))
        #expect(abs(centre.x - 200) < 1e-6 && abs(centre.y - 400) < 1e-6)
        let ll = v.toLonLat(Point(200, 400))
        #expect(abs(ll.lon - 11) < 1e-9)
        #expect(abs(v.centreLonLat.lat - 45.5) < 1e-9)
        let bbox = v.bbox
        #expect(bbox.0 < 11 && bbox.2 > 11 && bbox.1 < 45.5 && bbox.3 > 45.5)
        #expect(v.tileZoom() == 5)
        #expect(Viewport(centre: Point.zero, zoom: 5.8, size: Size(1, 1)).tileZoom() == 6)
        #expect(Viewport(centre: Point.zero, zoom: 12, size: Size(1, 1)).tileZoom(limit: 10) == 10)
        let tiles = v.tiles(at: 5)
        #expect(tiles.first == MapProjection.tile(at: v.centre, zoom: 5))
        #expect(tiles.count >= 2)
        let f = v.frame(of: TileID(z: 5, x: 16, y: 5))
        #expect(abs(f.size.width - 256) < 1e-6)
        let panned = v.panned(by: Point(10, 0))
        #expect(panned.centre.x < v.centre.x)
        let zoomed = v.zoomed(by: 2, around: Point(100, 100))
        #expect(abs(zoomed.zoom - 6) < 1e-9)
        let before = v.toMap(Point(100, 100)), after = zoomed.toMap(Point(100, 100))
        #expect(abs(before.x - after.x) < 1e-6 && abs(before.y - after.y) < 1e-6)
        v.maxZoom = 7
        #expect(v.zoomed(by: 1000, around: .zero).zoom == 7)
        let box = Rect(x: 0, y: 0, width: 100_000, height: 50_000)
        let fit = v.fitting(box)
        #expect(fit.centre == box.centre)
        #expect(fit.zoom > 5)
        #expect(v.fitting(Rect(x: 0, y: 0, width: 0, height: 0)).zoom == 7)
        let far = Viewport(centre: Point(1e12, -1e12), zoom: 99, size: Size(1, 1)).clamped()
        #expect(far.centre.x == MapProjection.halfWidth && far.centre.y == -MapProjection.halfHeight)
        #expect(far.zoom == Double(MapProjection.maxZoom))
    }
}

@Suite struct GeoJSONTests {
    @Test func decodesEveryGeometry() throws {
        let text = """
        [{"type":"Point","coordinates":[1,2]},
         {"type":"MultiPoint","coordinates":[[1,2],[3,4]]},
         {"type":"LineString","coordinates":[[1,2],[3,4]]},
         {"type":"MultiLineString","coordinates":[[[1,2],[3,4]],[[5,6],[7,8]]]},
         {"type":"Polygon","coordinates":[[[0,0],[4,0],[4,4],[0,0]]]},
         {"type":"MultiPolygon","coordinates":[[[[0,0],[1,0],[1,1],[0,0]]],[[[5,5],[6,5],[6,6],[5,5]]]]},
         {"type":"GeometryCollection","geometries":[{"type":"Point","coordinates":[9,9]}]}]
        """
        let gs = try JSONDecoder().decode([GeoJSONGeometry].self, from: Data(text.utf8))
        #expect(gs.count == 7)
        #expect(gs.map(\.positions.count) == [1, 2, 2, 4, 4, 8, 1])
        #expect(gs.map(\.isPoint) == [true, true, false, false, false, false, false])
        #expect(gs[0].centre?.lon == 1)
        #expect(gs[4].centre?.lat == 2)
        #expect(gs[5].bounds?.east == 6)
        #expect(GeoJSONGeometry.multiPoint([]).bounds == nil)
        #expect(GeoJSONGeometry.multiPoint([]).centre == nil)
        let back = try JSONDecoder().decode([GeoJSONGeometry].self, from: JSONEncoder().encode(gs))
        #expect(back == gs)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GeoJSONGeometry.self, from: Data(#"{"type":"Blob"}"#.utf8)) }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GeoJSONGeometry.self, from: Data(#"{"type":"Point","coordinates":[1]}"#.utf8))
        }
    }

    @Test func featuresAndTheirIDs() throws {
        let text = """
        [{"id":"a","geometry":null,"properties":{"layer":"events","label":"Battle","entity":{"ref":"battle"}}},
         {"id":7,"properties":{"traveller":{"ref":"cato"}}},
         {"properties":{"shape_id":"s1","ruler":{"ref":"aldo"}}},
         {"properties":{"id":"p1","slug":"lampton"}},
         {}]
        """
        let fs = try JSONDecoder().decode([GeoJSONFeature].self, from: Data(text.utf8))
        #expect(fs.map(\.id).prefix(4) == ["a", "7", "s1", "p1"])
        #expect(!fs[4].id.isEmpty)
        #expect(fs[0].layer == "events" && fs[0].label == "Battle" && fs[0].entityRef == "battle")
        #expect(fs[1].entityRef == "cato")
        #expect(fs[2].entityRef == "aldo")
        #expect(fs[3].entityRef == "lampton")
        #expect(fs[4].entityRef == nil)
        let back = try JSONDecoder().decode([GeoJSONFeature].self, from: JSONEncoder().encode(fs))
        #expect(back.map(\.id) == fs.map(\.id))
    }
}

@Suite struct StyleTests {
    @Test func colours() {
        #expect(RGBA(hex: "#ff0000") == RGBA(1, 0, 0))
        #expect(RGBA(hex: "00ff0080").a == Double(0x80) / 255)
        #expect(RGBA(css: "#0000ff") == RGBA(0, 0, 1))
        #expect(RGBA(css: "rgb(255, 0, 0)") == RGBA(1, 0, 0))
        #expect(RGBA(css: "rgba(0,0,0,0.5)")?.a == 0.5)
        #expect(RGBA(css: "hsl(120, 100%, 50%)") == RGBA(0, 1, 0))
        #expect(RGBA(css: "hsla(240,100%,50%,0.2)")?.b == 1)
        #expect(RGBA(css: "red") == nil)
        #expect(RGBA(css: "rgb(1,2)") == nil)
        #expect(RGBA(css: "rgb(a,b,c)") == nil)
        #expect(RGBA(css: "lab(1,2,3)") == nil)
        for h in stride(from: -60.0, through: 360, by: 60) {
            let c = RGBA.hsl(h, 1, 0.5)
            #expect(max(c.r, c.g, c.b) == 1)
        }
        #expect(RGBA(1, 1, 1).opacity(0.3).a == 0.3)
        #expect(MapPalette.light != MapPalette.dark)
    }

    func info(_ p: [String: JSONValue], layer: String = "places") -> FeatureInfo { FeatureInfo(layer: layer, properties: p, fallbackID: "f") }

    @Test func readsFeatureProperties() {
        let shape = info(["shape_id": "s", "label": "Lampton", "rank": 3, "role": "point", "entity": ["ref": "lampton", "id": "e1", "type": "location", "kind": "location.town"], "claimed": true, "disputed": "true", "uncertainty_m": 500, "min_zoom": 4, "max_zoom": 9])
        #expect(shape.id == "shape:s" && shape.kindOf == "shape" && shape.label == "Lampton" && shape.rank == 3)
        #expect(shape.entityRef == "lampton" && shape.entityId == "e1" && shape.type == "location" && shape.kind == "location.town")
        #expect(shape.claimed && shape.disputed && shape.uncertaintyM == 500)
        #expect(shape.inZoomBand(4) && !shape.inZoomBand(3) && shape.inZoomBand(10) && !shape.inZoomBand(10.5))
        let base = info(["id": 12, "class": "river", "name": "Testwater", "label": "x", "rank": 0], layer: "base-rivers")
        #expect(base.kindOf == "feature" && base.label == nil && base.generatorName == "Testwater" && base.rank == 5)
        #expect(info(["id": "12"], layer: "next-coast").id == "feature:12")
        #expect(info(["feature_id": "9"]).id == "feature:9")
        #expect(info([:]).id == "f")
        #expect(info(["id": "x", "label": ""]).label == nil)
        #expect(info(["ruler": ["title": "Aldo", "ref": "aldo"]]).ruler == "Aldo")
    }

    func styles(_ p: [String: JSONValue], _ g: VectorTile.GeometryType, zoom: Double = 6, layer: String = "places",
                stored: [String: JSONValue] = [:], selected: String? = nil, palette: MapPalette = .light) -> [FeatureStyle] {
        MapStyler.styles(info(p, layer: layer), geometry: g, zoom: zoom, layerStyle: stored, palette: palette, selected: selected)
    }

    @Test func generatorGeometry() {
        for cls in ["land", "sea", "ocean", "lake", "pond", "coast", "coastline", "river", "stream", "creek", "road", "track", "path", "hill"] {
            let s = styles(["class": .string(cls), "rank": 2], .line, layer: "base-x")
            #expect(s.count == 1)
            #expect(s[0].fill != nil || s[0].stroke != nil)
        }
        #expect(styles(["class": "land"], .polygon, layer: "base-x", stored: ["fill-color": "#000000"])[0].fill == RGBA(0, 0, 0))
        #expect(styles(["class": "river"], .line, layer: "base-x", stored: ["stroke-width": 7])[0].strokeWidth == 7)
        #expect(styles(["class": "track"], .line, layer: "base-x")[0].dash == [3, 3])
        #expect(styles(["class": "river", "id": "9"], .line, layer: "base-x", selected: "feature:9").count == 2)
        #expect(styles(["class": "river", "min_zoom": 8], .line, zoom: 5, layer: "base-x").isEmpty)
    }

    @Test func derivedKinds() {
        let territory = styles(["kind_of": "territory", "ruler": ["title": "Aldo"], "label": "Testmark", "disputed": true], .polygon, zoom: 5)
        #expect(territory[0].dash == [5, 4] && territory[0].label?.text == "Testmark")
        #expect(styles(["kind_of": "territory", "label": "T"], .polygon, zoom: 10, stored: ["fill-opacity": 0.5])[0].label == nil)
        let event = styles(["kind_of": "event", "label": "Battle"], .line)
        #expect(event[0].marker == .diamond && event[0].dash == [6, 4] && event[0].label != nil)
        #expect(styles(["kind_of": "event", "label": "Battle"], .point, zoom: 3)[0].label == nil)
        #expect(styles(["kind_of": "journey", "label": "Road"], .line)[0].label?.alongLine == true)
        #expect(styles(["kind_of": "telling", "label": "Ballad"], .point)[0].marker == .triangle)
        for stance in ["believes", "suspects", "doubts", "denies", "unaware", "other"] {
            #expect(styles(["kind_of": "belief", "stance": .string(stance), "label": "x"], .point)[0].marker == .circle)
        }
    }

    @Test func loreShapes() {
        let label = styles(["role": "label", "label": "Sea of Glass", "rank": 1], .line)
        #expect(label[0].label?.alongLine == true)
        #expect(label[0].label?.shownText == "Sea of Glass")
        #expect(styles(["role": "label", "label": "Realm", "rank": 1], .point)[0].label?.shownText == "R E A L M")
        #expect(styles(["role": "label"], .point).isEmpty)
        let point = styles(["label": "Lampton", "rank": 3, "precision": "region", "uncertainty_m": 2000, "type": "event"], .point)
        #expect(point[0].uncertaintyMetres == 2000 && point[0].markerFill == MapPalette.light.event && point[0].label != nil)
        #expect(styles(["label": "L", "uncertainty_m": 0], .point)[0].uncertaintyMetres == nil)
        #expect(styles([:], .point, stored: ["circle-radius": 9])[0].markerRadius == 9)
        let footprint = styles(["role": "footprint", "label": "Keep"], .polygon)
        #expect(footprint[0].fill != nil && footprint[0].label == nil)
        let extent = styles(["role": "extent", "label": "Vale", "rank": 4], .polygon, zoom: 6)
        #expect(extent[0].fill == nil && extent[0].label?.rank == 2 && extent[0].zIndex == 0)
        #expect(styles(["role": "extent", "label": "Vale"], .polygon, zoom: 10)[0].label == nil)
        #expect(styles(["role": "territory", "label": "Vale"], .polygon, zoom: 10)[0].label == nil)
        let stored = styles(["role": "extent"], .polygon, stored: ["fill-color": "rgb(0,0,255)", "stroke-color": "#ff0000", "stroke-width": 3])
        #expect(stored[0].fill == RGBA(0, 0, 1) && stored[0].stroke == RGBA(1, 0, 0) && stored[0].strokeWidth == 3)
        let front = styles(["role": "front", "label": "Front", "rank": 2], .line, stored: ["stroke-dash": [2, 2]])
        #expect(front[0].stroke == MapPalette.light.danger && front[0].dash == [2, 2] && front[0].label?.rank == 4)
        #expect(styles(["role": "route"], .line, stored: ["stroke-line-dash": [1, 3]])[0].dash == [1, 3])
        // status: proposed, claimed, designer, restricted
        #expect(styles(["canon": "proposed"], .line)[0].stroke == MapPalette.light.proposed)
        #expect(styles(["canon": "draft"], .polygon)[0].dash == [6, 4])
        #expect(styles(["claimed": true], .line)[0].stroke == MapPalette.light.claim)
        #expect(styles(["visibility": "designer"], .point)[0].markerStroke == MapPalette.light.designer)
        #expect(styles(["visibility": "restricted"], .line)[0].stroke == MapPalette.light.restricted)
        #expect(styles(["shape_id": "s", "slug": "lampton"], .point, selected: "lampton").count == 2)
        #expect(styles([:], .unknown).count == 1)
        #expect(MapStyler.hash("Aldo") == MapStyler.hash("Aldo"))
        #expect(MapStyler.hash("") == 0)
        for rank in 0...7 { #expect(LabelStyle.fontSize(rank: rank) >= 11) }
    }
}

@Suite struct VectorTileTests {
    @Test func decodesRecordedTiles() throws {
        for name in ["base-rivers-0-0-0", "base-rivers-5-16-5", "places-5-16-5", "regions-5-16-5", "routes-5-16-5", "places-9-271-89",
                     "regions-9-271-89", "routes-9-271-89", "canary-designer-layer-3-4-1"] {
            let data = try #require(Fixture.tile(name))
            let tile = try VectorTile(data: data)
            #expect(!tile.layers.isEmpty, "\(name)")
            for l in tile.layers {
                #expect(l.extent > 0)
                for f in l.features { #expect(!f.geometry.isEmpty) }
            }
        }
        let places = try VectorTile(data: try #require(Fixture.tile("places-5-16-5")))
        #expect(places.layer(places.layers[0].name) != nil)
        #expect(places.layer("nothing") == nil)
    }

    @Test func decodesBuiltTiles() throws {
        let data = makeTile(features: [
            (.point, ["label": "Lampton", "rank": 3, "claimed": true, "x": .number(-2.5)], [[(10, 20)], [(30, 40)]]),
            (.line, ["label": "Road"], [[(0, 0), (100, 0), (100, 100)], [(5, 5), (6, 6)]]),
            (.polygon, ["role": "extent"], [[(0, 0), (10, 0), (10, 10)]]),
        ])
        let tile = try VectorTile(data: data)
        let l = try #require(tile.layers.first)
        #expect(l.name == "places" && l.extent == 4096 && l.features.count == 3)
        #expect(l.features[0].geometry == [[Point(10, 20)], [Point(30, 40)]])
        #expect(l.features[0].properties["label"] == .string("Lampton"))
        #expect(l.features[0].properties["rank"] == .number(3))
        #expect(l.features[0].properties["claimed"] == .bool(true))
        #expect(l.features[0].properties["x"] == .number(-2.5))
        #expect(l.features[1].geometry.count == 2)
        #expect(l.features[2].geometry[0].first == l.features[2].geometry[0].last)
        #expect(l.features[0].id == 1)
    }

    @Test func readsEveryValueType() throws {
        func value(_ build: (inout ProtoWriter) -> Void) throws -> JSONValue {
            var w = ProtoWriter()
            build(&w)
            return try VectorTile.value(w.bytes)
        }
        #expect(try value { $0.field(1, string: "s") } == .string("s"))
        #expect(try value { $0.fixed32(2, Float(1.5).bitPattern) } == .number(1.5))
        #expect(try value { $0.fixed64(3, Double(2.25).bitPattern) } == .number(2.25))
        #expect(try value { $0.field(4, varint: UInt64(bitPattern: -3)) } == .number(-3))
        #expect(try value { $0.field(5, varint: 7) } == .number(7))
        #expect(try value { $0.field(6, varint: ProtoWriter.zigzag(-4)) } == .number(-4))
        #expect(try value { $0.field(7, varint: 0) } == .bool(false))
        #expect(try value { $0.field(8, varint: 1) } == .null)
    }

    @Test func refusesBrokenBytes() {
        #expect(throws: ProtoError.self) { try VectorTile(data: Data([0x1A, 0x05, 0x01])) }
        #expect(throws: ProtoError.self) { try VectorTile(data: Data([0x80])) }
        var r = ProtoReader([0x01])
        #expect(throws: ProtoError.self) { try r.fixed32() }
        #expect(throws: ProtoError.self) { try r.fixed64() }
        #expect(throws: ProtoError.self) { try r.skip(1) }
        #expect(throws: ProtoError.self) { try r.skip(5) }
        #expect(throws: ProtoError.self) { try r.skip(3) }
        var ok = ProtoReader([0x05, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x01, 0x07])
        #expect(throws: Never.self) {
            try ok.skip(0)
            try ok.skip(1)
            try ok.skip(2)
        }
        #expect(ProtoReader.zigzag(3) == -2)
        // geometry with a bad command or a short count stops cleanly
        #expect(VectorTile.decodeGeometry([UInt32(1 | 2 << 3), 2, 2], type: .point) == [[Point(1, 1)]])
        #expect(VectorTile.decodeGeometry([UInt32(4 | 1 << 3), 1, 1], type: .line).isEmpty)
        #expect(VectorTile.decodeGeometry([], type: .line).isEmpty)
        #expect(VectorTile.decodeGeometry([UInt32(7 | 1 << 3)], type: .polygon).isEmpty)
        var layer = ProtoWriter()
        layer.field(1, string: "l")
        layer.field(2, bytes: { var f = ProtoWriter(); f.field(2, packed: [0, 5, 9, 0]); f.field(9, varint: 1); f.field(3, varint: 9); return f.bytes }())
        layer.field(3, string: "k")
        let parsed = try? VectorTile.layer(layer.bytes)
        #expect(parsed?.features.first?.properties.isEmpty == true)
        #expect(parsed?.features.first?.type == .unknown)
        _ = VectorTile(layers: [])
    }
}

@Suite struct LabelPlacerTests {
    func style(_ text: String, rank: Int = 3, offsetY: Double = 0) -> LabelStyle {
        LabelStyle(text: text, rank: rank, alongLine: false, italic: false, serif: true, colour: RGBA(0, 0, 0), offsetY: offsetY,
                   fontSize: LabelStyle.fontSize(rank: rank), spacedCapitals: false)
    }

    @Test func placesMostImportantFirstWithoutOverlap() {
        let bounds = Rect(x: 0, y: 0, width: 400, height: 400)
        let cs = [
            LabelCandidate(id: "town", style: style("Lampton", rank: 4), anchor: Point(100, 100)),
            LabelCandidate(id: "realm", style: style("Testmark", rank: 1), anchor: Point(105, 102)),
            LabelCandidate(id: "picked", style: style("Ford", rank: 6), anchor: Point(100, 100), boosted: true),
            LabelCandidate(id: "far", style: style("Eastbrook", rank: 4), anchor: Point(300, 300)),
            LabelCandidate(id: "outside", style: style("Gone"), anchor: Point(-50, 0)),
            LabelCandidate(id: "again", style: style("Eastbrook", rank: 4), anchor: Point(300, 350)),
            LabelCandidate(id: "a", style: style("Same", rank: 5), anchor: Point(20, 380)),
            LabelCandidate(id: "b", style: style("Other", rank: 5), anchor: Point(380, 20)),
        ]
        let placed = LabelPlacer.place(cs, in: bounds)
        #expect(placed.map(\.id) == ["picked", "again", "a", "b"])
        #expect(placed[0].frame.contains(Point(100, 100)))
        #expect(LabelPlacer.place(cs, in: bounds, limit: 1).count == 1)
    }

    @Test func linesAndTurnedLabels() throws {
        #expect(LabelPlacer.lineAnchor([Point(0, 0)], minLength: 1) == nil)
        #expect(LabelPlacer.lineAnchor([Point(0, 0), Point(5, 0)], minLength: 10) == nil)
        let (mid, angle) = try #require(LabelPlacer.lineAnchor([Point(0, 0), Point(100, 0), Point(100, 100)], minLength: 10))
        #expect(mid == Point(100, 0) && angle == 0)
        let (_, back) = try #require(LabelPlacer.lineAnchor([Point(100, 0), Point(0, 0)], minLength: 10))
        #expect(abs(back) < 1e-9)
        let (_, up) = try #require(LabelPlacer.lineAnchor([Point(0, 100), Point(-1, 0)], minLength: 10))
        #expect(up > -Double.pi / 2 && up <= Double.pi / 2)
        let (_, down) = try #require(LabelPlacer.lineAnchor([Point(0, 0), Point(-1, 100)], minLength: 10))
        #expect(down >= -Double.pi / 2 && down <= Double.pi / 2)
        #expect(LabelPlacer.lineAnchor([Point(0, 0), Point(0, 0), Point(0, 20)], minLength: 1) != nil)
        let flat = LabelPlacer.box(centre: .zero, size: Size(10, 2), angle: 0)
        let turned = LabelPlacer.box(centre: .zero, size: Size(10, 2), angle: .pi / 2)
        #expect(abs(turned.size.width - flat.size.height) < 1e-9)
        let size = LabelPlacer.size(of: style("Abc"))
        #expect(size.width > 10 && size.height > 10)
    }
}

@Suite struct TileStoreTests {
    @Test func requestsAndKeys() {
        let r = TileRequest(layer: "places", tile: TileID(z: 5, x: 16, y: 5), year: 1131, viewpoint: "dirk", version: 67, world: "main")
        #expect(r.path == "/map/tiles/places/5/16/5.mvt")
        #expect(r.query.map(\.name) == ["year", "viewpoint", "v"])
        #expect(r.cacheKey.contains("world=main"))
        #expect(r.parent?.tile == TileID(z: 4, x: 8, y: 2))
        #expect(TileRequest(layer: "x", tile: TileID(z: 0, x: 0, y: 0), version: 1).parent == nil)
        let raster = TileRequest(kind: .raster, layer: "atlas", tile: TileID(z: 1, x: 0, y: 0), version: 1)
        #expect(raster.path == "/map/raster-tiles/atlas/1/0/0")
        #expect(raster.description == "raster:atlas/1/0/0")
    }

    @Test func lruDropsTheOldest() {
        var lru = LRU<String, Int>(capacity: 2)
        lru.set("a", 1)
        lru.set("b", 2)
        _ = lru.get("a")
        lru.set("c", 3)
        #expect(lru.peek("b") == nil && lru.peek("a") == 1 && lru.count == 2)
        lru.set("a", 4)
        #expect(lru.get("a") == 4)
        #expect(lru.get("zz") == nil)
        lru.removeAll()
        #expect(lru.count == 0)
        #expect(LRU<String, Int>(capacity: 0).capacity == 1)
    }

    @Test func fetchesOnceThenFromMemoryAndDisk() async throws {
        let stack = Stack()
        let r = TileRequest(layer: "places", tile: TileID(z: 5, x: 16, y: 5), year: 1131, version: 67, world: "main")
        guard case .vector(let v) = try await stack.tiles.tile(r) else {
            Issue.record("not a vector tile")
            return
        }
        #expect(!v.layers.isEmpty)
        #expect(await stack.tiles.peek(r) != nil)
        _ = try await stack.tiles.tile(r)
        #expect(stack.server.requests.filter { $0.url.path.hasSuffix(".mvt") }.count == 1)
        #expect(await stack.tiles.memoryCount == 1)
        // a new store over the same disk cache reads the disk
        let again = TileStore(client: stack.client, cache: stack.tiles.cache)
        _ = try await again.tile(r)
        #expect(stack.server.requests.filter { $0.url.path.hasSuffix(".mvt") }.count == 1)
        await again.clear()
        #expect(await again.memoryCount == 0)
    }

    @Test func emptyRasterAndBrokenTiles() async throws {
        let stack = Stack()
        let empty = TileRequest(layer: "places", tile: TileID(z: 0, x: 0, y: 0), version: 67)
        guard case .empty = try await stack.tiles.tile(empty) else {
            Issue.record("not empty")
            return
        }
        let raster = TileRequest(kind: .raster, layer: "atlas", tile: TileID(z: 0, x: 0, y: 0), version: 67)
        guard case .raster(let d) = try await stack.tiles.tile(raster) else {
            Issue.record("not a raster")
            return
        }
        #expect(d.count == 4)
        // damaged bytes on disk are dropped and fetched again
        let r = TileRequest(layer: "routes", tile: TileID(z: 5, x: 16, y: 5), version: 67)
        await stack.tiles.cache.store(Data([0x80]), for: r.cacheKey, mark: 67)
        guard case .vector = try await stack.tiles.tile(r) else {
            Issue.record("not refetched")
            return
        }
        // two asks at once share a request
        let s = TileRequest(layer: "regions", tile: TileID(z: 5, x: 16, y: 5), version: 67)
        async let one = stack.tiles.tile(s)
        async let two = stack.tiles.tile(s)
        _ = try await (one, two)
        #expect(stack.server.requests.filter { $0.url.path.contains("/regions/5/16/5") }.count == 1)
        stack.server.status("/map/tiles/places/1/1/0.mvt", 200, body: Data([0x80]))
        await #expect(throws: ProtoError.self) {
            try await stack.tiles.tile(TileRequest(layer: "places", tile: TileID(z: 1, x: 1, y: 0), version: 67))
        }
    }
}

@Suite struct SceneTests {
    func tile() throws -> VectorTile {
        try VectorTile(data: makeTile(features: [
            (.point, ["shape_id": "p", "label": "Lampton", "rank": 3, "slug": "lampton", "precision": "region", "uncertainty_m": 1000], [[(2048, 2048)]]),
            (.line, ["shape_id": "l", "label": "The Old Road Long Name", "rank": 4], [[(0, 100), (4096, 100)], [(0, 0), (10, 0)]]),
            (.polygon, ["shape_id": "a", "label": "Vale", "role": "extent", "rank": 2], [[(1000, 1000), (3000, 1000), (3000, 3000), (1000, 3000)]]),
            (.polygon, ["shape_id": "z", "min_zoom": 12], [[(0, 0), (1, 0), (1, 1)]]),
            (.line, ["shape_id": "front", "role": "label", "label": "Along", "rank": 2], [[(0, 4000), (4096, 4000)]]),
        ]))
    }

    @Test func buildsAPieceFromATile() throws {
        let r = TileRequest(layer: "places", tile: TileID(z: 5, x: 16, y: 5), version: 67)
        let layer = MapLayers.Layer(id: "1", key: "places", title: "Places", kind: "vector", zOrder: 5)
        let piece = SceneBuilder.piece(tile: try tile(), request: r, layer: layer, zoom: 5, palette: .light, id: "x")
        #expect(piece.layerZ == 5 && piece.id == "x")
        #expect(piece.hits.count == 4)
        #expect(piece.labels.count == 4)
        #expect(piece.groups.allSatisfy { !$0.isEmpty })
        #expect(piece.groups.contains { !$0.halos.isEmpty })
        #expect(piece.groups.map(\.style.zIndex) == piece.groups.map(\.style.zIndex).sorted())
        let vp = Viewport(centre: MapProjection.toMap(LonLat(11.1, 45.5)), zoom: 5, size: Size(800, 800))
        let s = piece.toScreen(Point(2048, 2048), in: vp)
        let back = piece.fromScreen(s, in: vp)
        #expect(abs(back.x - 2048) < 1e-6 && abs(back.y - 2048) < 1e-6)
        let candidates = piece.labelCandidates(in: vp, selected: "shape:p")
        #expect(candidates.contains { $0.boosted })
        #expect(candidates.contains { $0.angle == 0 && $0.style.alongLine })
        // zoomed far out, a line label is too long to place
        let tiny = Viewport(centre: vp.centre, zoom: 0, size: Size(800, 800))
        #expect(piece.labelCandidates(in: tiny).count < candidates.count)
        let empty = ScenePiece.empty(.metres, layerZ: 2, id: "e")
        #expect(empty.groups.isEmpty && empty.layerZ == 2)
    }

    @Test func buildsAPieceFromGeoJSON() throws {
        let derived = try Fixture.decode(GeoJSONCollection.self, "features-derived")
        let layer = MapLayers.Layer(id: "e", key: "events", title: "Events", kind: "derived", zOrder: 8)
        let piece = SceneBuilder.piece(collection: derived, layer: layer, zoom: 6, palette: .dark)
        #expect(piece.space == .metres)
        #expect(piece.hits.count >= 4)
        #expect(!piece.labels.isEmpty)
        let territories = try Fixture.decode(GeoJSONCollection.self, "territories")
        let t = SceneBuilder.piece(collection: territories, layer: nil, zoom: 5, palette: .light)
        #expect(t.groups.count == 2)
        let vp = Viewport(centre: MapProjection.toMap(LonLat(11.1, 45.5)), zoom: 5, size: Size(800, 800))
        let s = t.toScreen(MapProjection.toMap(LonLat(11.1, 45.5)), in: vp)
        #expect(abs(s.x - 400) < 1e-6 && abs(s.y - 400) < 1e-6)
        let mixed = GeoJSONCollection(features: [
            GeoJSONFeature(id: "c", geometry: .collection([.point(LonLat(1, 1)), .multiLineString([[LonLat(0, 0), LonLat(1, 1)]]),
                                                         .multiPolygon([[[LonLat(0, 0), LonLat(1, 0), LonLat(1, 1)]]])]),
                           properties: ["kind_of": "event", "label": "Mixed"]),
            GeoJSONFeature(id: "n", geometry: nil, properties: [:]),
        ])
        let m = SceneBuilder.piece(collection: mixed, layer: nil, zoom: 6, palette: .light)
        #expect(m.hits.count == 3)
    }

    @Test func geometryHelpers() {
        typealias B = SceneBuilder.Builder
        #expect(B.middle([]) == nil)
        #expect(B.middle([Point(0, 0), Point(10, 0)]) == Point(5, 0))
        #expect(B.middle([Point(1, 1), Point(1, 1)]) == Point(1, 1))
        #expect(B.area([Point(0, 0), Point(1, 0)]) == 0)
        #expect(B.area([Point(0, 0), Point(2, 0), Point(2, 2), Point(0, 2)]) == 4)
        #expect(B.centroid([Point(0, 0), Point(2, 0), Point(2, 2), Point(0, 2)]) == Point(1, 1))
        #expect(B.centroid([Point(0, 0), Point(2, 0)]) == Point(1, 0))
        #expect(B.centroid([]) == .zero)
        #expect(B.length([Point(0, 0), Point(3, 4)]) == 5)
        #expect(SceneBuilder.flatten(.multiPoint([LonLat(1, 1), LonLat(2, 2)]))[0].1.count == 2)
        #expect(SceneBuilder.flatten(.lineString([LonLat(1, 1), LonLat(2, 2)]))[0].0 == .line)
        #expect(SceneBuilder.flatten(.polygon([[LonLat(1, 1)]]))[0].0 == .polygon)
    }

    @Test func hitsAndHighlights() throws {
        let r = TileRequest(layer: "places", tile: TileID(z: 5, x: 16, y: 5), version: 67)
        let piece = SceneBuilder.piece(tile: try tile(), request: r, layer: nil, zoom: 5, palette: .light)
        let vp = Viewport(centre: MapProjection.toMap(LonLat(11.1, 45.5)), zoom: 5, size: Size(800, 800))
        // the point beats the area it sits in
        let onPoint = piece.toScreen(Point(2048, 2048), in: vp)
        let hit = try #require(HitTester.hit([piece], at: onPoint, in: vp))
        #expect(hit.target.info.id == "shape:p")
        let ll = try #require(hit.lonLat)
        #expect(abs(ll.lon - 11.25) < 6 && abs(ll.lat - 45) < 6)
        // the line
        let onLine = piece.toScreen(Point(500, 100), in: vp)
        #expect(HitTester.hit([piece], at: onLine, in: vp)?.target.type == .line)
        // inside the area only
        let inArea = piece.toScreen(Point(1200, 2800), in: vp)
        #expect(HitTester.hit([piece], at: inArea, in: vp)?.target.type == .polygon)
        // nothing
        #expect(HitTester.hit([piece], at: Point(-500, -500), in: vp) == nil)
        for h in piece.hits {
            let m = MapHit(target: h, space: piece.space)
            #expect(m.highlight(.light).layerZ == 10_000)
            #expect(m.lonLat != nil)
        }
        let metres = MapHit(target: HitTarget(info: piece.hits[0].info, type: .point, geometry: [[MapProjection.toMap(LonLat(1, 2))]], zIndex: 0),
                            space: .metres)
        #expect(abs((metres.lonLat?.lon ?? 0) - 1) < 1e-9)
        #expect(MapHit(target: HitTarget(info: piece.hits[0].info, type: .line, geometry: [], zIndex: 0), space: .metres).lonLat == nil)
        // a higher layer wins at the same rank
        var top = piece
        top.layerZ = 9
        top.id = "top"
        #expect(HitTester.hit([piece, top], at: onPoint, in: vp)?.target.info.id == "shape:p")
        #expect(HitTester.distance(Point(0, 0), toLine: []) == .infinity)
        #expect(HitTester.distance(Point(0, 0), toLine: [Point(3, 4)]) == 5)
        #expect(HitTester.distance(Point(0, 1), toLine: [Point(0, 0), Point(0, 0)]) == 1)
        #expect(HitTester.inside(Point(0.5, 0.5), rings: [[Point(0, 0), Point(1, 0)]]) == false)
    }
}
