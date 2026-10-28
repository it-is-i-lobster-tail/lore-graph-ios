import Foundation
import Observation

/// The map (F-7): the viewport, which layers show, the tiles and derived features for the view,
/// what was tapped, and the measuring tool. The canvas draws `drawList` and `rasterList`.
@Observable
@MainActor
public final class MapModel {
    public enum Selection: Hashable, Sendable {
        /// A feature on the map; `ref` when it is a page.
        case feature(FeatureInfo, LonLat?)
        /// An empty spot: what is there comes from the server.
        case point(LonLat)
    }

    public private(set) var viewport: Viewport
    public private(set) var layers: Loader<MapLayers>
    public private(set) var visible: Set<String> = []
    public private(set) var baseMap: BaseMap = .plain
    public private(set) var palette: MapPalette = .light
    public private(set) var pieces: [TileRequest: ScenePiece] = [:]
    public private(set) var derived: [String: ScenePiece] = [:]
    public private(set) var rasters: [TileRequest: Data] = [:]
    public private(set) var selection: Selection?
    public private(set) var highlight: ScenePiece?
    public private(set) var placesAt: Loader<PlacesAt>?
    public private(set) var preview: Loader<EntityDetail>?
    public private(set) var measuring = false
    public private(set) var measurePoints: [LonLat] = []
    public private(set) var distance: Distance?
    /// Tiles that failed in this view; the map says it is showing what it has.
    public private(set) var failedTiles = 0
    public private(set) var lastError: APIError?
    public private(set) var context: ReadContext

    @ObservationIgnored var options: MapOptions
    @ObservationIgnored private var started = false
    @ObservationIgnored private var loaded: [TileRequest: VectorTile] = [:]
    @ObservationIgnored private var builtAt: [TileRequest: Int] = [:]
    @ObservationIgnored private var inFlight: Set<TileRequest> = []
    @ObservationIgnored private var derivedTask: Task<Void, Never>?
    @ObservationIgnored private var derivedGeneration = 0
    /// How long to wait after the view stops moving before asking for derived features.
    @ObservationIgnored public var derivedDelay: Duration = .milliseconds(350)

    public init(options: MapOptions = MapOptions(), camera: ReadingState.Camera? = nil, context: ReadContext,
                size: Size = Size(390, 700)) {
        self.options = options
        self.context = context
        layers = context.loader(API.mapLayers())
        let centre = options.centre ?? camera?.centre ?? LonLat(0, 45)
        viewport = Viewport(centre: centre, zoom: options.zoom ?? camera?.zoom ?? 3, size: size)
        if let l = options.layers ?? camera?.layers { visible = Set(l) }
        if let b = options.base { baseMap = b }
        measurePoints = options.points
        measuring = options.measuring || !options.points.isEmpty
    }

    // MARK: loading

    public func load() async {
        await layers.load()
        guard let info = layers.value else { return }
        if !started {
            started = true
            applyDefaults(info)
            update()
            if let ref = options.select {
                await flyTo(ref)
            } else if let place = options.place {
                await selectPoint(place)
            }
            if measurePoints.count >= 2 { await measure() }
        } else {
            update()
        }
    }

    /// The refresh button: layers and the map version again, then the tiles for the new version.
    public func refresh() async {
        await layers.refresh()
        failedTiles = 0
        update()
        scheduleDerived(immediately: true)
    }

    private func applyDefaults(_ info: MapLayers) {
        if options.layers == nil && visible.isEmpty {
            visible = Set(info.layers.filter { $0.defaultVisible == true && $0.isCurrent }.map(\.key))
        }
        if options.base == nil {
            baseMap = availableBaseMaps.contains(.atlas) ? .atlas : .plain
        }
        if options.centre == nil && options.zoom == nil && cameraWasDefault, let home = info.map?.home, home.center.count == 2 {
            viewport = Viewport(centre: LonLat(home.center[0], home.center[1]), zoom: home.zoom, size: viewport.size)
        }
        viewport.minZoom = Double(info.map?.minZoom ?? 0)
        viewport.maxZoom = Double(info.map?.maxZoom ?? MapProjection.maxZoom)
        viewport = viewport.clamped()
    }

    /// Whether the viewport is still the made-up starting one (no link, no saved camera).
    private var cameraWasDefault: Bool {
        viewport.centre == MapProjection.toMap(LonLat(0, 45)) && viewport.zoom == 3
    }

    /// Another year, viewpoint or world: tiles and features for it.
    public func setContext(_ c: ReadContext) async {
        let worldChanged = c.world != context.world || c.server != context.server
        context = c
        if worldChanged {
            layers = c.loader(API.mapLayers())
            started = false
            visible = []
            pieces = [:]
            loaded = [:]
            builtAt = [:]
            rasters = [:]
            derived = [:]
            clearSelection()
            await load()
        } else {
            update()
            scheduleDerived(immediately: true)
        }
    }

    // MARK: the view

    public func setViewport(_ v: Viewport) {
        var next = v
        next.minZoom = viewport.minZoom
        next.maxZoom = viewport.maxZoom
        viewport = next.clamped()
        update()
    }

    public func resize(_ size: Size) {
        guard size != viewport.size, size.width > 0, size.height > 0 else { return }
        viewport.size = size
        update()
    }

    public func setPalette(_ p: MapPalette) {
        guard p != palette else { return }
        palette = p
        builtAt = [:]
        rebuildPieces()
        scheduleDerived(immediately: true)
    }

    public var camera: ReadingState.Camera {
        ReadingState.Camera(centre: viewport.centreLonLat, zoom: viewport.zoom, layers: visible.sorted())
    }

    public var version: Int { layers.value?.mapVersion ?? 0 }

    var year: Int { Int(floor(context.year)) }

    var zoomBucket: Int { Int(floor(viewport.zoom)) }

    var maxTileZoom: Int { layers.value?.map?.maxZoom ?? MapProjection.maxZoom }

    // MARK: layers

    public var vectorLayers: [MapLayers.Layer] {
        (layers.value?.layers ?? []).filter { $0.isVectorTiled && $0.isCurrent }.sorted { ($0.zOrder ?? 0) < ($1.zOrder ?? 0) }
    }

    public var derivedLayers: [MapLayers.Layer] {
        (layers.value?.layers ?? []).filter(\.isDerived)
    }

    /// The layers the layer sheet lists, by group (base map rasters are picked separately).
    public var layerGroups: [(group: String, layers: [MapLayers.Layer])] {
        let list = (layers.value?.layers ?? []).filter { $0.isCurrent && !($0.isRaster && $0.baseMap != nil) && !$0.isRaster }
        var order: [String] = []
        var groups: [String: [MapLayers.Layer]] = [:]
        for l in list.sorted(by: { ($0.zOrder ?? 0) > ($1.zOrder ?? 0) }) {
            let g = l.group ?? "Other"
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(l)
        }
        let known = layers.value?.groups ?? []
        order.sort { (known.firstIndex(of: $0) ?? Int.max, $0) < (known.firstIndex(of: $1) ?? Int.max, $1) }
        return order.map { ($0, groups[$0]!) }
    }

    public var availableBaseMaps: [BaseMap] {
        let have = Set((layers.value?.layers ?? []).compactMap { $0.raster?.key != nil ? $0.baseMap : nil })
        return BaseMap.allCases.filter { $0 == .plain || have.contains($0) }
    }

    public func toggle(_ key: String) {
        if visible.contains(key) { visible.remove(key) } else { visible.insert(key) }
        update()
        scheduleDerived(immediately: true)
    }

    public func setBaseMap(_ b: BaseMap) {
        baseMap = b
        update()
    }

    func inBand(_ l: MapLayers.Layer) -> Bool {
        let z = viewport.zoom
        if let lo = l.minZoom, z < lo - 1e-6 { return false }
        if let hi = l.maxZoom, z > hi + 1 { return false }
        return true
    }

    // MARK: tiles

    /// The vector tiles the view needs, layer by layer, centre first.
    public var neededTiles: [TileRequest] {
        let z = viewport.tileZoom(limit: maxTileZoom)
        let tiles = viewport.tiles(at: z)
        let vp = context.view.viewpoint?.ref
        var out: [TileRequest] = []
        for l in vectorLayers where visible.contains(l.key) && inBand(l) {
            let base = l.isBaseGeometry
            for t in tiles {
                out.append(TileRequest(kind: .vector, layer: l.key, tile: t, year: base ? nil : year,
                                       viewpoint: base ? nil : vp, version: version, world: context.world))
            }
        }
        return out
    }

    /// The base map's image tiles the view needs.
    public var neededRasters: [TileRequest] {
        guard let layer = (layers.value?.layers ?? []).first(where: { $0.baseMap == baseMap && baseMap != .plain }),
              let key = layer.raster?.key else { return [] }
        // past its native zoom the image has no more detail: its native tiles are drawn enlarged,
        // as the web app does (ADR D-77)
        let native = layer.raster?.nativeZoom ?? layers.value?.map?.rasterMaxZoom ?? 10
        let z = viewport.tileZoom(limit: native)
        return viewport.tiles(at: z).map {
            TileRequest(kind: .raster, layer: key, tile: $0, version: version, world: context.world)
        }
    }

    /// Asks for what the view needs and rebuilds styles when the zoom crosses a level.
    public func update() {
        guard layers.value != nil else { return }
        let needed = neededTiles
        for r in needed {
            if loaded[r] != nil {
                if builtAt[r] != zoomBucket { build(r) }
            } else if !inFlight.contains(r) {
                fetch(r)
            }
        }
        for r in neededRasters where rasters[r] == nil && !inFlight.contains(r) { fetch(r) }
        prune(keeping: needed)
        scheduleDerived()
    }

    private func fetch(_ r: TileRequest) {
        inFlight.insert(r)
        let store = context.tiles
        Task { [weak self] in
            do {
                let tile = try await store.tile(r)
                self?.arrived(r, tile)
            } catch let e as APIError {
                self?.failed(r, e)
            } catch {
                self?.failed(r, .offline(""))
            }
        }
    }

    private func arrived(_ r: TileRequest, _ tile: TileStore.Tile) {
        inFlight.remove(r)
        switch tile {
        case .vector(let v):
            loaded[r] = v
            build(r)
        case .raster(let data):
            rasters[r] = data
        case .empty:
            if r.kind == .vector {
                loaded[r] = VectorTile(layers: [])
                pieces[r] = .empty(.tile(r.tile, extent: 4096), id: r.cacheKey)
                builtAt[r] = zoomBucket
            } else {
                rasters[r] = Data()
            }
        }
    }

    private func failed(_ r: TileRequest, _ e: APIError) {
        inFlight.remove(r)
        failedTiles += 1
        lastError = e
    }

    private func build(_ r: TileRequest) {
        guard let tile = loaded[r] else { return }
        let bucket = zoomBucket
        builtAt[r] = bucket
        let layer = vectorLayers.first { $0.key == r.layer }
        let palette = self.palette
        // the zoom a level's styles are drawn at: the level itself
        pieces[r] = SceneBuilder.piece(tile: tile, request: r, layer: layer, zoom: Double(bucket), palette: palette,
                                       id: "\(r.cacheKey)|\(bucket)|\(palette == .dark ? "d" : "l")")
    }

    private func rebuildPieces() {
        for r in neededTiles where loaded[r] != nil { build(r) }
    }

    /// Keeps memory bounded: tiles far from the view go once there are many.
    private func prune(keeping needed: [TileRequest]) {
        guard pieces.count > 400 || rasters.count > 200 else { return }
        var keep = Set(needed)
        for r in needed {
            var p = r.parent
            while let q = p {
                keep.insert(q)
                p = q.parent
            }
        }
        let rasterKeep = Set(neededRasters)
        for r in pieces.keys where !keep.contains(r) {
            pieces[r] = nil
            loaded[r] = nil
            builtAt[r] = nil
        }
        for r in rasters.keys where !rasterKeep.contains(r) { rasters[r] = nil }
    }

    /// What to draw, bottom first: for each needed tile its piece, or while it loads the
    /// nearest level above that has one; then the derived layers and the selection.
    public var drawList: [ScenePiece] {
        var out: [ScenePiece] = []
        var fallback = Set<TileRequest>()
        for r in neededTiles {
            if let p = pieces[r] {
                out.append(p)
                continue
            }
            var a = r.parent
            while let q = a {
                if let p = pieces[q] {
                    if fallback.insert(q).inserted { out.insert(p, at: 0) }
                    break
                }
                a = q.parent
            }
        }
        for l in derivedLayers where visible.contains(l.key) {
            if let p = derived[l.key] { out.append(p) }
        }
        let sorted = out.enumerated().sorted { a, b in
            a.element.layerZ != b.element.layerZ ? a.element.layerZ < b.element.layerZ : a.offset < b.offset
        }.map(\.element)
        return highlight.map { sorted + [$0] } ?? sorted
    }

    /// The base map images to draw, with a parent standing in while a tile loads.
    public var rasterList: [(tile: TileID, data: Data)] {
        var out: [(TileID, Data)] = []
        var seen = Set<TileRequest>()
        for r in neededRasters {
            var q: TileRequest? = r
            while let c = q {
                if let d = rasters[c], !d.isEmpty {
                    if seen.insert(c).inserted { c == r ? out.append((c.tile, d)) : out.insert((c.tile, d), at: 0) }
                    break
                }
                q = c.parent
            }
        }
        return out
    }

    /// Labels placed for this frame.
    public func placedLabels() -> [PlacedLabel] {
        let selectedID: String? = {
            if case .feature(let info, _) = selection { return info.id }
            return nil
        }()
        let candidates = drawList.flatMap { $0.labelCandidates(in: viewport, selected: selectedID) }
        let bounds = Rect(x: 0, y: 0, width: viewport.size.width, height: viewport.size.height)
        return LabelPlacer.place(candidates, in: bounds)
    }

    // MARK: derived layers

    func scheduleDerived(immediately: Bool = false) {
        derivedTask?.cancel()
        let delay = derivedDelay
        derivedTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.loadDerived()
        }
    }

    func loadDerived() async {
        let shown = derivedLayers.filter { visible.contains($0.key) && inBand($0) }
        guard !shown.isEmpty else {
            derived = [:]
            return
        }
        let bbox = viewport.bbox
        let zoom = Int(viewport.zoom.rounded(.down))
        var next: [String: ScenePiece] = [:]
        derivedGeneration += 1
        let generation = derivedGeneration
        let featureKeys = shown.filter { $0.key != "territories" }.map(\.key)
        let repo = context.repository
        do {
            if !featureKeys.isEmpty {
                let answer = try await read(API.features(layers: featureKeys, bbox: bbox, zoom: zoom), repo)
                for key in featureKeys {
                    let layer = shown.first { $0.key == key }
                    let mine = GeoJSONCollection(features: answer.features.filter { ($0.layer ?? key) == key })
                    next[key] = SceneBuilder.piece(collection: mine, layer: layer, zoom: viewport.zoom, palette: palette,
                                                   id: "derived|\(key)|\(generation)")
                }
            }
            if let t = shown.first(where: { $0.key == "territories" }) {
                let answer = try await read(API.territories(bbox: bbox, zoom: zoom), repo)
                next[t.key] = SceneBuilder.piece(collection: answer, layer: t, zoom: viewport.zoom, palette: palette,
                                                 id: "derived|\(t.key)|\(generation)")
            }
            guard !Task.isCancelled else { return }
            derived = next
        } catch is CancellationError {
            return
        } catch let e as APIError {
            lastError = e
        } catch {
            lastError = .offline("")
        }
    }

    /// A derived answer: the cached one if it is current, else the server's.
    private func read(_ e: Endpoint<GeoJSONCollection>, _ repo: Repository) async throws -> GeoJSONCollection {
        let cached = await repo.cached(e, world: context.world, view: context.view)
        if let fresh = try await repo.revalidate(e, world: context.world, view: context.view, cached: cached) {
            return fresh.value
        }
        if let cached { return cached.value }
        return try await repo.fetch(e, world: context.world, view: context.view).value
    }

    // MARK: taps and selection

    /// A tap: measure, or select the feature under it, or clear the selection (F-7.8).
    public func tap(at s: Point) async {
        let lonLat = viewport.toLonLat(s)
        if measuring {
            await addMeasurePoint(lonLat)
            return
        }
        if let hit = HitTester.hit(drawList.filter { $0.layerZ < 10_000 }, at: s, in: viewport) {
            await select(hit)
        } else {
            clearSelection()
        }
    }

    /// A long press: what is at the spot (F-7.9).
    public func whatsHere(at s: Point) async {
        await selectPoint(viewport.toLonLat(s))
    }

    func select(_ hit: MapHit) async {
        selection = .feature(hit.target.info, hit.lonLat)
        highlight = hit.highlight(palette)
        placesAt = nil
        if let ref = hit.target.info.entityRef ?? hit.target.info.entityId {
            let p = context.loader(API.preview(ref))
            preview = p
            await p.load()
        } else {
            preview = nil
        }
    }

    public func selectPoint(_ p: LonLat) async {
        selection = .point(p)
        highlight = ScenePiece(id: "point|\(p.lon)|\(p.lat)", space: .metres, layerZ: 10_000, groups: [
            StyledGroup(style: MapStyler.selection(palette), rings: [], lines: [], points: [MapProjection.toMap(p)], halos: []),
        ], labels: [], hits: [])
        preview = nil
        let l = context.loader(API.placesAt(lon: p.lon, lat: p.lat))
        placesAt = l
        await l.load()
    }

    public func clearSelection() {
        selection = nil
        highlight = nil
        preview = nil
        placesAt = nil
    }

    /// Flies to a page's shapes and selects it (F-7.7). False when it has none on the map.
    @discardableResult
    public func flyTo(_ ref: String) async -> Bool {
        guard let answer = try? await read(API.shapes(of: ref), context.repository) else { return false }
        let points = answer.features.compactMap(\.geometry).flatMap(\.positions).map(MapProjection.toMap)
        guard let box = Rect.bounding(points) else { return false }
        if box.size.width < 1 && box.size.height < 1 {
            let minZoom = answer.features.compactMap { $0.properties["min_zoom"]?.number }.min() ?? 4
            var v = viewport
            v.centre = box.centre
            v.zoom = max(viewport.zoom, minZoom + 2, 7)
            setViewport(v)
        } else {
            setViewport(viewport.fitting(box))
        }
        if let f = answer.features.first, let g = f.geometry {
            let parts = SceneBuilder.flatten(g)
            if let (type, geometry) = parts.first {
                let info = FeatureInfo(layer: f.layer ?? "", properties: f.properties.merging(["slug": .string(ref)]) { a, _ in a },
                                       fallbackID: f.id)
                await select(MapHit(target: HitTarget(info: info, type: type, geometry: geometry, zIndex: 0), space: .metres))
            }
        }
        return true
    }

    // MARK: measuring

    public func setMeasuring(_ on: Bool) {
        measuring = on
        if !on { clearMeasure() } else { clearSelection() }
    }

    public func addMeasurePoint(_ p: LonLat) async {
        measurePoints.append(p)
        await measure()
    }

    public func undoMeasurePoint() async {
        guard !measurePoints.isEmpty else { return }
        measurePoints.removeLast()
        await measure()
    }

    public func clearMeasure() {
        measurePoints = []
        distance = nil
    }

    /// The great-circle length of the drawn route, known without the server.
    public var measuredKm: Double {
        zip(measurePoints, measurePoints.dropFirst()).reduce(0) { $0 + MapProjection.greatCircleKm($1.0, $1.1) }
    }

    /// Travel times for the route from the server (F-7.10).
    func measure() async {
        guard measurePoints.count >= 2 else {
            distance = nil
            return
        }
        let pts = measurePoints.map { String(format: "%.5f,%.5f", $0.lon, $0.lat) }
        let wanted = measurePoints
        let answer = try? await context.repository.client.get(API.distance(pts), world: context.world, view: context.view).value
        guard wanted == measurePoints else { return }
        distance = answer
    }

    // MARK: sharing

    public var shareURL: URL {
        var place: LonLat?
        var select: String?
        switch selection {
        case .point(let p): place = p
        case .feature(let info, _): select = info.entityRef
        case nil: break
        }
        return context.shareURL(.map(MapOptions(centre: viewport.centreLonLat, zoom: viewport.zoom, layers: visible.sorted(),
                                                base: baseMap, place: place, points: measurePoints, measuring: measuring,
                                                select: select)))
    }
}
