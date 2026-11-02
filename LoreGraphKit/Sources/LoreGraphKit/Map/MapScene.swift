import Foundation

/// Features that share a style, merged so the canvas draws them in one go.
public struct StyledGroup: Hashable, Sendable {
    public var style: FeatureStyle
    /// Rings (polygons, closed) and lines, in the piece's space.
    public var rings: [[Point]]
    public var lines: [[Point]]
    /// Marker positions.
    public var points: [Point]
    /// Soft circles around vague places: centre and radius in metres.
    public var halos: [Point]

    public var isEmpty: Bool { rings.isEmpty && lines.isEmpty && points.isEmpty }
}

/// A label before placement: its anchor in the piece's space, or the line it follows.
public struct LabelSeed: Hashable, Sendable {
    public var id: String
    public var style: LabelStyle
    public var anchor: Point
    public var line: [Point]?
}

/// What a tap can hit: a feature's facts and its geometry in the piece's space.
public struct HitTarget: Hashable, Sendable {
    public var info: FeatureInfo
    public var type: VectorTile.GeometryType
    public var geometry: [[Point]]
    public var zIndex: Int
}

/// One layer's drawing for one tile (in tile units) or for a whole answer (in map metres).
public struct ScenePiece: Hashable, Sendable {
    public enum Space: Hashable, Sendable {
        /// Tile units, 0 to `extent`, y down.
        case tile(TileID, extent: Int)
        /// Map metres, y up.
        case metres
    }

    /// Names this drawing for the canvas's path cache: the same id means the same paths.
    public var id: String
    public var space: Space
    public var layerZ: Int
    public var groups: [StyledGroup]
    public var labels: [LabelSeed]
    public var hits: [HitTarget]
    /// The tiles this drawing may cover. A vector tile carries its features a little past its
    /// edges (the server's buffer) with polygons cut there, so drawn unclipped the cut edges
    /// show as straight lines and fills overlap the neighbours'. Nil means the piece's own tile
    /// for a tile piece and no limit for one in metres; a parent standing in for children that
    /// are still loading covers only those children.
    public var clip: [TileID]?

    public init(id: String = "", space: Space, layerZ: Int, groups: [StyledGroup], labels: [LabelSeed], hits: [HitTarget],
                clip: [TileID]? = nil) {
        self.id = id
        self.space = space
        self.layerZ = layerZ
        self.groups = groups
        self.labels = labels
        self.hits = hits
        self.clip = clip
    }

    public static func empty(_ space: Space, layerZ: Int = 0, id: String = "") -> ScenePiece {
        ScenePiece(id: id, space: space, layerZ: layerZ, groups: [], labels: [], hits: [])
    }

    /// The affine map from this piece's space to the screen: screen = (a·x + tx, d·y + ty).
    public func transform(in viewport: Viewport) -> (a: Double, d: Double, tx: Double, ty: Double) {
        switch space {
        case .tile(let t, let extent):
            let f = viewport.frame(of: t)
            let k = f.size.width / Double(extent)
            return (k, k, f.minX, f.minY)
        case .metres:
            let r = viewport.resolution
            return (1 / r, -1 / r, viewport.size.width / 2 - viewport.centre.x / r,
                    viewport.size.height / 2 + viewport.centre.y / r)
        }
    }

    /// The screen rectangles this piece is drawn in, or nil when it is not limited.
    public func clipRects(in viewport: Viewport) -> [Rect]? {
        switch space {
        case .tile(let t, _): return (clip ?? [t]).map { viewport.frame(of: $0) }
        case .metres: return clip.map { $0.map { viewport.frame(of: $0) } }
        }
    }

    /// Whether a screen point is this piece's to draw: inside one of its tiles, counting each
    /// shared edge once (left and top), so a point on the buffer is drawn by one tile only.
    public func owns(_ s: Point, clipRects rects: [Rect]?) -> Bool {
        guard let rects else { return true }
        return rects.contains { s.x >= $0.minX && s.x < $0.maxX && s.y >= $0.minY && s.y < $0.maxY }
    }

    /// The selection outline of one feature as this piece holds it, limited like the piece.
    public func highlight(of info: FeatureInfo, palette: MapPalette) -> ScenePiece? {
        let mine = hits.filter { $0.info.id == info.id && $0.info.layer == info.layer }
        guard !mine.isEmpty else { return nil }
        var g = StyledGroup(style: MapStyler.selection(palette), rings: [], lines: [], points: [], halos: [])
        for h in mine {
            switch h.type {
            case .polygon: g.rings += h.geometry
            case .line: g.lines += h.geometry
            case .point, .unknown: g.points += h.geometry.compactMap(\.first)
            }
        }
        return ScenePiece(id: "highlight|\(info.id)|\(id)|\(space)", space: space, layerZ: 10_000, groups: [g], labels: [],
                          hits: [], clip: clip)
    }

    /// A point of this piece on the screen.
    public func toScreen(_ p: Point, in viewport: Viewport) -> Point {
        let t = transform(in: viewport)
        return Point(t.a * p.x + t.tx, t.d * p.y + t.ty)
    }

    /// A screen point in this piece's space.
    public func fromScreen(_ s: Point, in viewport: Viewport) -> Point {
        let t = transform(in: viewport)
        return Point((s.x - t.tx) / t.a, (s.y - t.ty) / t.d)
    }

    /// Label candidates on the screen, lines turned into anchors where they are long enough.
    /// Labels whose anchor falls outside the piece's tiles are left to the tile that owns it.
    public func labelCandidates(in viewport: Viewport, selected: String? = nil) -> [LabelCandidate] {
        let rects = clipRects(in: viewport)
        return labels.compactMap { seed in
            let boosted = selected != nil && seed.id == selected
            if let line = seed.line {
                let pts = line.map { toScreen($0, in: viewport) }
                let width = LabelPlacer.size(of: seed.style).width
                guard let (anchor, angle) = LabelPlacer.lineAnchor(pts, minLength: width * 1.1),
                      owns(anchor, clipRects: rects) else { return nil }
                return LabelCandidate(id: seed.id, style: seed.style, anchor: anchor, angle: angle, boosted: boosted)
            }
            let anchor = toScreen(seed.anchor, in: viewport)
            guard owns(anchor, clipRects: rects) else { return nil }
            return LabelCandidate(id: seed.id, style: seed.style, anchor: anchor, boosted: boosted)
        }
    }
}

/// Turns tiles and GeoJSON answers into scene pieces with MapStyler's styles.
public enum SceneBuilder {
    /// One vector tile of one map layer at a zoom.
    public static func piece(tile: VectorTile, request: TileRequest, layer: MapLayers.Layer?, zoom: Double,
                             palette: MapPalette, id: String = "") -> ScenePiece {
        var b = Builder()
        for l in tile.layers {
            let extent = Double(l.extent)
            for (i, f) in l.features.enumerated() {
                let info = FeatureInfo(layer: request.layer, properties: f.properties,
                                       fallbackID: "\(request.tile):\(l.name):\(f.id.map(String.init) ?? String(i))")
                let styles = MapStyler.styles(info, geometry: f.type, zoom: zoom, layerStyle: layer?.style ?? [:], palette: palette)
                // metres to tile units for vague-place halos
                let unitsPerMetre = extent / (MapProjection.tileMetres / pow(2, Double(request.tile.z)))
                b.add(info: info, type: f.type, geometry: f.geometry, styles: styles, haloScale: unitsPerMetre)
            }
        }
        let extent = tile.layers.first?.extent ?? 4096
        return b.piece(.tile(request.tile, extent: extent), layerZ: layer?.zOrder ?? 0, id: id)
    }

    /// A GeoJSON answer (derived layers, territories) in map metres.
    public static func piece(collection: GeoJSONCollection, layer: MapLayers.Layer?, zoom: Double,
                             palette: MapPalette, id: String = "") -> ScenePiece {
        var b = Builder()
        for f in collection.features {
            guard let g = f.geometry else { continue }
            let key = f.layer ?? layer?.key ?? ""
            var props = f.properties
            if props["id"] == nil { props["id"] = .string(f.id) }
            let info = FeatureInfo(layer: key, properties: props, fallbackID: f.id)
            for (type, parts) in flatten(g) {
                let styles = MapStyler.styles(info, geometry: type, zoom: zoom, layerStyle: layer?.style ?? [:], palette: palette)
                b.add(info: info, type: type, geometry: parts, styles: styles, haloScale: 1)
            }
        }
        return b.piece(.metres, layerZ: layer?.zOrder ?? 0, id: id)
    }

    /// GeoJSON geometry as MVT-like parts in map metres.
    static func flatten(_ g: GeoJSONGeometry) -> [(VectorTile.GeometryType, [[Point]])] {
        func m(_ ps: [LonLat]) -> [Point] { ps.map(MapProjection.toMap) }
        switch g {
        case .point(let p): return [(.point, [[MapProjection.toMap(p)]])]
        case .multiPoint(let ps): return [(.point, ps.map { [MapProjection.toMap($0)] })]
        case .lineString(let ps): return [(.line, [m(ps)])]
        case .multiLineString(let ls): return [(.line, ls.map(m))]
        case .polygon(let rings): return [(.polygon, rings.map(m))]
        case .multiPolygon(let polys): return [(.polygon, polys.flatMap { $0.map(m) })]
        case .collection(let gs): return gs.flatMap(flatten)
        }
    }

    struct Builder {
        var groups: [FeatureStyle: StyledGroup] = [:]
        var order: [FeatureStyle] = []
        var labels: [LabelSeed] = []
        var hits: [HitTarget] = []

        mutating func add(info: FeatureInfo, type: VectorTile.GeometryType, geometry: [[Point]], styles: [FeatureStyle],
                          haloScale: Double) {
            guard !styles.isEmpty, !geometry.isEmpty else { return }
            for var style in styles {
                if let label = style.label {
                    labels.append(seed(info: info, type: type, geometry: geometry, label: label))
                    style.label = nil
                }
                let halo = style.uncertaintyMetres.map { $0 * haloScale }
                style.uncertaintyMetres = halo
                var g = groups[style] ?? StyledGroup(style: style, rings: [], lines: [], points: [], halos: [])
                if groups[style] == nil { order.append(style) }
                switch type {
                case .polygon:
                    if style.fill != nil || style.stroke != nil { g.rings += geometry }
                case .line:
                    if style.stroke != nil { g.lines += geometry }
                    if style.marker != nil, let mid = geometry.first.flatMap(Self.middle) { g.points.append(mid) }
                case .point, .unknown:
                    if style.marker != nil || style.uncertaintyMetres != nil {
                        let pts = geometry.compactMap(\.first)
                        g.points += pts
                        if halo != nil { g.halos += pts }
                    }
                }
                groups[style] = g
            }
            let z = styles.map(\.zIndex).max() ?? 0
            hits.append(HitTarget(info: info, type: type, geometry: geometry, zIndex: z))
        }

        func seed(info: FeatureInfo, type: VectorTile.GeometryType, geometry: [[Point]], label: LabelStyle) -> LabelSeed {
            switch type {
            case .line where label.alongLine:
                let longest = geometry.max { Self.length($0) < Self.length($1) } ?? []
                return LabelSeed(id: info.id, style: label, anchor: Self.middle(longest) ?? .zero, line: longest)
            case .polygon:
                let outer = geometry.max { abs(Self.area($0)) < abs(Self.area($1)) } ?? []
                return LabelSeed(id: info.id, style: label, anchor: Self.centroid(outer), line: nil)
            case .line:
                let longest = geometry.max { Self.length($0) < Self.length($1) } ?? []
                return LabelSeed(id: info.id, style: label, anchor: Self.middle(longest) ?? .zero, line: nil)
            case .point, .unknown:
                return LabelSeed(id: info.id, style: label, anchor: geometry.first?.first ?? .zero, line: nil)
            }
        }

        func piece(_ space: ScenePiece.Space, layerZ: Int, id: String) -> ScenePiece {
            let sorted = order.enumerated().sorted { a, b in
                a.element.zIndex != b.element.zIndex ? a.element.zIndex < b.element.zIndex : a.offset < b.offset
            }.compactMap { groups[$0.element] }.filter { !$0.isEmpty }
            return ScenePiece(id: id, space: space, layerZ: layerZ, groups: sorted, labels: labels, hits: hits)
        }

        static func length(_ line: [Point]) -> Double {
            zip(line, line.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        }

        /// The point halfway along a line.
        static func middle(_ line: [Point]) -> Point? {
            guard let first = line.first else { return nil }
            var target = length(line) / 2
            for (a, b) in zip(line, line.dropFirst()) {
                let d = a.distance(to: b)
                if target <= d, d > 0 { return a + (b - a) * (target / d) }
                target -= d
            }
            return line.last ?? first
        }

        /// Shoelace area (signed).
        static func area(_ ring: [Point]) -> Double {
            guard ring.count >= 3 else { return 0 }
            var s = 0.0
            for (a, b) in zip(ring, ring.dropFirst() + [ring[0]]) { s += a.x * b.y - b.x * a.y }
            return s / 2
        }

        /// The area-weighted centre of a ring, or its points' mean for a sliver.
        static func centroid(_ ring: [Point]) -> Point {
            let a = area(ring)
            guard abs(a) > 1e-9 else {
                guard !ring.isEmpty else { return .zero }
                let sx = ring.reduce(0) { $0 + $1.x }, sy = ring.reduce(0) { $0 + $1.y }
                return Point(sx / Double(ring.count), sy / Double(ring.count))
            }
            var cx = 0.0, cy = 0.0
            for (p, q) in zip(ring, ring.dropFirst() + [ring[0]]) {
                let f = p.x * q.y - q.x * p.y
                cx += (p.x + q.x) * f
                cy += (p.y + q.y) * f
            }
            return Point(cx / (6 * a), cy / (6 * a))
        }
    }
}

/// A feature a tap touched, and the space its geometry is in.
public struct MapHit: Hashable, Sendable {
    public var target: HitTarget
    public var space: ScenePiece.Space

    /// The feature drawn as the selection, in the same space.
    public func highlight(_ palette: MapPalette) -> ScenePiece {
        let style = MapStyler.selection(palette)
        var g = StyledGroup(style: style, rings: [], lines: [], points: [], halos: [])
        switch target.type {
        case .polygon: g.rings = target.geometry
        case .line: g.lines = target.geometry
        case .point, .unknown: g.points = target.geometry.compactMap(\.first)
        }
        return ScenePiece(id: "highlight|\(target.info.id)|\(space)", space: space, layerZ: 10_000, groups: [g], labels: [], hits: [])
    }

    /// Where the feature is, roughly: its point, or the middle of its first part.
    public var lonLat: LonLat? {
        guard let part = target.geometry.first, !part.isEmpty else { return nil }
        let p: Point
        switch target.type {
        case .polygon: p = SceneBuilder.Builder.centroid(part)
        case .line: p = SceneBuilder.Builder.middle(part) ?? part[0]
        case .point, .unknown: p = part[0]
        }
        switch space {
        case .metres:
            return MapProjection.toLonLat(p)
        case .tile(let t, let extent):
            let b = MapProjection.tileBounds(t)
            let k = (b.east - b.west) / Double(extent)
            return MapProjection.toLonLat(Point(b.west + p.x * k, b.north - p.y * k))
        }
    }
}

/// Finding what a tap touched.
public enum HitTester {
    /// The topmost feature under a screen point: markers first, then lines, then areas.
    public static func hit(_ pieces: [ScenePiece], at s: Point, in viewport: Viewport, tolerance: Double = 14) -> MapHit? {
        var best: (hit: MapHit, rank: Int, z: Int, d: Double)?
        // a tile's own buffer may answer a tap near its edge (it is the same feature), but a
        // parent standing in for loading children answers only inside them
        for piece in pieces where piece.clip == nil || piece.owns(s, clipRects: piece.clipRects(in: viewport)) {
            let p = piece.fromScreen(s, in: viewport)
            let scale = abs(piece.transform(in: viewport).a)
            let tol = tolerance / max(scale, 1e-12)
            for h in piece.hits {
                var rank = 0, d = 0.0
                switch h.type {
                case .point, .unknown:
                    guard let nearest = h.geometry.compactMap(\.first).map({ $0.distance(to: p) }).min(), nearest <= tol else { continue }
                    rank = 3
                    d = nearest
                case .line:
                    guard let nearest = h.geometry.map({ distance(p, toLine: $0) }).min(), nearest <= tol * 0.7 else { continue }
                    rank = 2
                    d = nearest
                case .polygon:
                    guard inside(p, rings: h.geometry) else { continue }
                    rank = 1
                }
                let z = piece.layerZ * 100 + h.zIndex
                if let b = best {
                    if rank < b.rank || (rank == b.rank && (z < b.z || (z == b.z && d >= b.d))) { continue }
                }
                best = (MapHit(target: h, space: piece.space), rank, z, d)
            }
        }
        return best?.hit
    }

    /// Even-odd point in polygon over all rings (holes included).
    static func inside(_ p: Point, rings: [[Point]]) -> Bool {
        var c = false
        for ring in rings where ring.count >= 3 {
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
                j = i
            }
        }
        return c
    }

    static func distance(_ p: Point, toLine line: [Point]) -> Double {
        guard line.count > 1 else { return line.first.map { $0.distance(to: p) } ?? .infinity }
        var best = Double.infinity
        for (a, b) in zip(line, line.dropFirst()) {
            let ab = b - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            let t = len2 > 0 ? max(0, min(1, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / len2)) : 0
            best = min(best, (a + ab * t).distance(to: p))
        }
        return best
    }
}
