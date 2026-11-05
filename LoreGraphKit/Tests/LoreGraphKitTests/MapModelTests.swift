import Foundation
import Testing
@testable import LoreGraphKit

/// A rebuilt world's painted atlas, waiting to be activated (listed before today's, as the
/// server's key order puts `next-painted` first).
private let nextAtlas = #"{"id": "r-next-atlas", "key": "next-painted", "title": "Painted atlas", "kind": "raster", "group": "Base maps", "generation": "next", "raster": {"key": "next-atlas-1", "native_zoom": 6}}"#

/// The Testmark layers plus a painted atlas (and the rebuilt world's), a relief without tiles,
/// and layers that test the zoom bands, the "Other" group and the next map generation.
private func layersWithRasters() throws -> MapLayers {
    var layers = try Fixture.decode(MapLayers.self, "map-layers")
    for json in [
        nextAtlas,
        #"{"id": "r-atlas", "key": "atlas", "title": "Painted atlas", "kind": "raster", "group": "Base maps", "raster": {"key": "atlas-1", "native_zoom": 6}}"#,
        #"{"id": "r-relief", "key": "relief", "title": "Relief", "kind": "raster", "group": "Base maps", "raster": {}}"#,
        #"{"id": "v-loose", "key": "loose", "title": "Loose", "kind": "vector", "source": {"shapes": {}}, "default_visible": true}"#,
        #"{"id": "v-deep", "key": "deep", "title": "Deep", "kind": "vector", "source": {"shapes": {}}, "default_visible": true, "min_zoom": 12}"#,
        #"{"id": "v-shallow", "key": "shallow", "title": "Shallow", "kind": "vector", "source": {"shapes": {}}, "default_visible": true, "max_zoom": 2}"#,
        #"{"id": "v-next", "key": "next-coast", "title": "Next coast", "kind": "vector", "generation": "next", "source": {"features": true}, "default_visible": true}"#,
    ] {
        layers.layers.append(try JSONCoding.decoder.decode(MapLayers.Layer.self, from: Data(json.utf8)))
    }
    return layers
}

private func tileZ(_ piece: ScenePiece) -> Int? {
    if case .tile(let t, _) = piece.space { return t.z }
    return nil
}

@Suite @MainActor struct MapModelLoadingTests {
    @Test func opensAtHomeWithTheDefaultLayers() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        m.derivedDelay = .zero
        m.update()
        #expect(m.version == 0 && m.neededTiles.isEmpty && stack.server.requests.isEmpty)
        await m.load()
        #expect(m.visible == ["places", "regions", "routes", "labels"])
        #expect(m.baseMap == .plain && m.availableBaseMaps == [.plain])
        #expect(m.viewport.zoom == 5 && m.version == 67)
        #expect(abs(m.camera.centre.lon - 26.06) < 1e-6 && abs(m.camera.centre.lat - 45.13) < 1e-6)
        #expect(m.camera.layers == ["labels", "places", "regions", "routes"])
        #expect(m.vectorLayers.first?.zOrder ?? 0 <= m.vectorLayers.last?.zOrder ?? 0)
        #expect(m.derivedLayers.map(\.key).sorted() == ["beliefs", "events", "journeys", "tellings", "territories"])
        #expect(m.layerGroups.map(\.group) == ["Base maps", "Places", "Political", "Events", "Stories", "CANARY-DESIGNER-LAYER-GROUP"])
        #expect(m.layerGroups[1].layers.map(\.key) == ["labels", "places", "routes", "regions"])
        #expect(await eventually { !m.pieces.isEmpty && m.pieces.count == m.neededTiles.count })
        #expect(!m.drawList.isEmpty)
        #expect(m.failedTiles == 0)
        _ = m.placedLabels()
        #expect(m.neededRasters.isEmpty && m.rasterList.isEmpty)
        #expect(m.neededTiles.allSatisfy { $0.year == 1131 && $0.version == 67 && $0.world == "main" })

        // a second load only asks for what the view needs
        let layerReads = stack.server.count("/map/layers")
        await m.load()
        #expect(stack.server.count("/map/layers") == layerReads)
    }

    @Test func opensWhereALinkSays() async throws {
        let stack = Stack()
        let spot = LonLat(11, 45.5)
        let m = MapModel(options: MapOptions(centre: spot, zoom: 6, layers: ["places"], base: .plain, place: spot),
                         context: stack.context())
        #expect(m.visible == ["places"] && m.baseMap == .plain)
        await m.load()
        #expect(m.viewport.zoom == 6 && abs(m.viewport.centreLonLat.lon - 11) < 1e-6)
        guard case .point(let p) = m.selection else {
            Issue.record("no point selected")
            return
        }
        #expect(p == spot && m.placesAt?.value != nil && m.preview == nil && m.highlight != nil)
        let link = try #require(WebLink.parse(m.shareURL, server: testServer))
        guard case .map(let o) = link.route else {
            Issue.record("not a map link")
            return
        }
        #expect(o.place == spot && o.layers == ["places"] && o.base == .plain)
    }

    @Test func opensOnASelectedPage() async throws {
        let stack = Stack()
        let m = MapModel(options: MapOptions(select: "lampton"), context: stack.context())
        await m.load()
        guard case .feature(let info, _) = m.selection else {
            Issue.record("nothing selected")
            return
        }
        #expect(info.entityRef == "lampton" && m.viewport.zoom == 7)
        #expect(m.preview?.value?.entity.ref == "lampton")
        let link = try #require(WebLink.parse(m.shareURL, server: testServer))
        guard case .map(let o) = link.route else {
            Issue.record("not a map link")
            return
        }
        #expect(o.select == "lampton")
        _ = m.placedLabels()
    }

    @Test func opensMeasuringARoute() async {
        let stack = Stack()
        let m = MapModel(options: MapOptions(points: [LonLat(11, 45.5), LonLat(12, 45)]), context: stack.context())
        #expect(m.measuring && m.measurePoints.count == 2)
        await m.load()
        #expect(m.distance != nil && m.measuredKm > 50)
    }

    @Test func opensAtTheSavedCamera() async {
        let stack = Stack()
        let m = MapModel(camera: ReadingState.Camera(centre: LonLat(11, 45.5), zoom: 8, layers: ["regions"]), context: stack.context())
        await m.load()
        #expect(m.visible == ["regions"] && m.viewport.zoom == 8)
        #expect(abs(m.viewport.centreLonLat.lat - 45.5) < 1e-6)
    }

    @Test func refreshesAndChangesContext() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        m.derivedDelay = .zero
        await m.load()
        #expect(await eventually { m.pieces.count == m.neededTiles.count })
        let layerReads = stack.server.count("/map/layers")
        await m.refresh()
        #expect(stack.server.count("/map/layers") == layerReads + 1 && m.failedTiles == 0)

        // the map always shows the present: the reader's year (for pages) never moves it, while
        // the viewpoint still applies
        await m.setContext(stack.context(view: ViewState(asOf: 1020, viewpoint: .init(ref: "aldo", title: "Aldo"))))
        let lore = m.neededTiles.filter { $0.layer == "places" }
        #expect(!lore.isEmpty && lore.allSatisfy { $0.year == 1131 && $0.viewpoint == "aldo" })
        #expect(await eventually { m.neededTiles.allSatisfy { m.pieces[$0] != nil } })
        #expect(stack.server.requests.contains { $0.url.path.hasSuffix(".mvt") && $0.query["viewpoint"] == ["aldo"] })
        #expect(!stack.server.requests.contains { $0.query["year"] == ["1020"] || $0.query["as_of"] != nil })
        await m.selectPoint(LonLat(11, 45.5))
        #expect(await eventually { m.placesAt?.value != nil })
        #expect(!stack.server.requests.contains { $0.query["as_of"] != nil })
        let shared = m.shareURL.absoluteString
        #expect(shared.contains("vp=aldo") && !shared.contains("y=1020"))

        await m.selectPoint(LonLat(11, 45.5))
        await m.setContext(stack.context(world: "elsewhere"))
        #expect(m.context.world == "elsewhere" && m.selection == nil)
        #expect(m.visible == ["places", "regions", "routes", "labels"])
        #expect(m.neededTiles.allSatisfy { $0.world == "elsewhere" })
    }

    @Test func countsTilesThatFail() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        for r in m.neededTiles where r.layer == "places" {
            stack.server.status("/map/tiles/places/\(r.tile.z)/\(r.tile.x)/\(r.tile.y).mvt", 500)
        }
        await m.refresh()
        #expect(await eventually { m.failedTiles > 0 })
        #expect(m.lastError != nil)
    }
}

@Suite @MainActor struct MapModelViewTests {
    @Test func movesResizesAndRedraws() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        #expect(await eventually { m.pieces.count == m.neededTiles.count })

        let size = m.viewport.size
        m.resize(size)
        m.resize(Size(0, 10))
        #expect(m.viewport.size == size)
        m.resize(Size(800, 600))
        #expect(m.viewport.size == Size(800, 600))

        var v = m.viewport
        v.zoom = 30
        m.setViewport(v)
        #expect(m.viewport.zoom == 16)

        v.zoom = 5
        m.setViewport(v)
        #expect(await eventually { m.pieces.count >= m.neededTiles.count && m.neededTiles.allSatisfy { m.pieces[$0] != nil } })
        v.zoom = 6
        m.setViewport(v)
        // while level 6 loads, level 5 stands in, only where level 6 is still missing
        let loading = m.drawList
        #expect(loading.contains { tileZ($0) == 5 })
        for standIn in loading where tileZ(standIn) == 5 {
            let clip = try #require(standIn.clip)
            #expect(!clip.isEmpty && clip.allSatisfy { $0.z == 6 })
            #expect(clip.allSatisfy { t in m.neededTiles.contains { $0.tile == t && m.pieces[$0] == nil } })
        }
        #expect(await eventually { m.neededTiles.allSatisfy { m.pieces[$0] != nil } })
        #expect(!m.drawList.contains { tileZ($0) == 5 })

        m.setPalette(.light)
        m.setPalette(.dark)
        #expect(m.palette == .dark)
        #expect(m.neededTiles.allSatisfy { m.pieces[$0]?.id.hasSuffix("|d") == true })
    }

    @Test func dropsFarTilesWhenThereAreMany() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context(), size: Size(3000, 3000))
        await m.load()
        var v = m.viewport
        v.zoom = 7
        m.setViewport(v)
        #expect(m.neededTiles.count > 400)
        #expect(await eventually(.seconds(20)) { m.neededTiles.allSatisfy { m.pieces[$0] != nil } })
        #expect(m.pieces.count > 400)
        v.centre = MapProjection.toMap(LonLat(-120, -40))
        m.setViewport(v)
        let keep = Set(m.neededTiles)
        #expect(m.pieces.keys.allSatisfy { keep.contains($0) || $0.tile.z < 7 })
    }

    @Test func baseMapsAndLayerGroups() async throws {
        let stack = Stack()
        stack.server.json("/map/layers", value: try layersWithRasters())
        let m = MapModel(context: stack.context())
        await m.load()
        #expect(m.baseMap == .atlas && m.availableBaseMaps == [.atlas, .plain])
        #expect(m.visible == ["places", "regions", "routes", "labels", "loose", "deep", "shallow"])
        #expect(Set(m.neededTiles.map(\.layer)) == ["places", "regions", "routes", "labels", "loose"])
        #expect(m.layerGroups.last?.group == "Other")
        #expect(m.layerGroups.last?.layers.map(\.key).sorted() == ["deep", "loose", "shallow"])
        #expect(!m.layerGroups.flatMap(\.layers).contains { $0.isRaster || !$0.isCurrent })

        #expect(!m.neededRasters.isEmpty && m.neededRasters.allSatisfy { $0.kind == .raster && $0.layer == "atlas-1" && $0.tile.z == 5 })
        #expect(await eventually { m.rasterList.count == m.neededRasters.count })
        #expect(m.rasterList.allSatisfy { $0.tile.z == 5 })

        // level 6 has no images: level 5 keeps standing in
        var v = m.viewport
        v.zoom = 6
        for t in v.tiles(at: 6) { stack.server.status("/map/raster-tiles/atlas-1/6/\(t.x)/\(t.y)", 204) }
        m.setViewport(v)
        #expect(!m.rasterList.isEmpty && m.rasterList.allSatisfy { $0.tile.z == 5 })
        #expect(await eventually { m.neededRasters.allSatisfy { m.rasters[$0] != nil } })
        #expect(m.rasterList.allSatisfy { $0.tile.z == 5 })

        // past the native zoom the native tiles are drawn enlarged, however far in
        v.zoom = 11
        m.setViewport(v)
        #expect(!m.neededRasters.isEmpty && m.neededRasters.allSatisfy { $0.layer == "atlas-1" && $0.tile.z == 6 })
        m.setBaseMap(.plain)
        #expect(m.baseMap == .plain && m.neededRasters.isEmpty && m.rasterList.isEmpty)
    }

    @Test func aRebuiltWorldsImagesAreNotTodaysBaseMap() async throws {
        // a world whose only map is still the rebuilt one: today's map has no images
        let stack = Stack()
        var layers = try Fixture.decode(MapLayers.self, "map-layers")
        layers.layers.append(try JSONCoding.decoder.decode(MapLayers.Layer.self, from: Data(nextAtlas.utf8)))
        stack.server.json("/map/layers", value: layers)
        let m = MapModel(context: stack.context())
        await m.load()
        #expect(layers.layers.last?.baseMap == nil)
        #expect(m.baseMap == .plain && m.availableBaseMaps == [.plain])
        m.setBaseMap(.atlas)
        #expect(m.neededRasters.isEmpty)
        #expect(!m.layerGroups.flatMap(\.layers).contains { $0.key == "next-painted" })
    }

    @Test func togglesLayersAndLoadsDerivedFeatures() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        m.derivedDelay = .zero
        await m.load()
        m.toggle("places")
        #expect(!m.visible.contains("places") && !m.neededTiles.contains { $0.layer == "places" })
        m.toggle("places")
        #expect(m.visible.contains("places"))

        m.toggle("events")
        m.toggle("territories")
        #expect(await eventually { m.derived["events"] != nil && m.derived["territories"] != nil })
        let ids = Set(m.drawList.map(\.id))
        #expect(ids.contains(m.derived["events"]!.id) && ids.contains(m.derived["territories"]!.id))
        let reads = stack.server.count("/map/features")
        await m.loadDerived()
        #expect(stack.server.count("/map/features") == reads)

        m.toggle("events")
        m.toggle("territories")
        #expect(await eventually { m.derived.isEmpty })
    }

    @Test func aFailedDerivedLayerIsReported() async throws {
        let stack = Stack()
        stack.server.status("/map/territories", 500)
        let m = MapModel(context: stack.context())
        await m.load()
        m.toggle("territories")
        #expect(await eventually { m.lastError != nil })
        #expect(m.derived["territories"] == nil)
    }
}

@Suite @MainActor struct MapModelTapTests {
    @Test func tapsSelectAndClear() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        #expect(await m.flyTo("lampton"))
        #expect(await eventually { m.neededTiles.allSatisfy { m.pieces[$0] != nil } })
        #expect(m.pieces.values.contains { !$0.groups.isEmpty })
        m.clearSelection()
        #expect(m.selection == nil && m.highlight == nil && m.preview == nil && m.placesAt == nil)

        let centre = Point(m.viewport.size.width / 2, m.viewport.size.height / 2)
        await m.tap(at: centre)
        guard case .feature(let info, let at) = m.selection else {
            Issue.record("nothing under the tap")
            return
        }
        #expect(info.entityRef == "lampton" && at != nil)
        #expect(m.highlight != nil && m.preview?.value?.entity.ref == "lampton")

        await m.whatsHere(at: centre)
        guard case .point = m.selection else {
            Issue.record("no point selected")
            return
        }
        #expect(m.placesAt?.value != nil && m.preview == nil)

        for key in m.visible { m.toggle(key) }
        await m.tap(at: centre)
        #expect(m.selection == nil)
    }

    /// A shape cut across tiles is outlined in every tile that holds it, not just the tapped one.
    @Test func outlinesTheWholeShapeAcrossTiles() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        let info = FeatureInfo(layer: "regions", properties: ["id": "shape:r"])
        let ring = [Point(0, 0), Point(4160, 0), Point(4160, 4096)]
        func tilePiece(_ x: Int, holds: Bool) -> ScenePiece {
            let other = FeatureInfo(layer: "regions", properties: ["id": "shape:other"])
            return ScenePiece(id: "t\(x)", space: .tile(TileID(z: 5, x: x, y: 5), extent: 4096), layerZ: 1, groups: [], labels: [],
                              hits: [HitTarget(info: holds ? info : other, type: .polygon, geometry: [ring], zIndex: 0)])
        }
        let pieces = [tilePiece(16, holds: true), tilePiece(17, holds: true), tilePiece(18, holds: false), .empty(.metres)]
        await m.select(MapHit(target: pieces[0].hits[0], space: pieces[0].space))
        let outlines = m.highlights(over: pieces)
        #expect(outlines.map(\.space) == [pieces[0].space, pieces[1].space])
        #expect(outlines.allSatisfy { $0.layerZ == 10_000 && $0.clip == nil })

        // a tapped tile that has since gone keeps its own outline
        #expect(m.highlights(over: []) == [try #require(m.highlight)])
        // so does a shape in metres, and a spot
        await m.select(MapHit(target: pieces[0].hits[0], space: .metres))
        #expect(m.highlights(over: pieces) == [try #require(m.highlight)])
        m.clearSelection()
        #expect(m.highlights(over: pieces).isEmpty)
    }

    @Test func selectsFeaturesWithoutAPage() async {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        let info = FeatureInfo(layer: "base-rivers", properties: ["id": "4", "class": "river"], fallbackID: "f")
        let p = MapProjection.toMap(LonLat(11, 45.5))
        await m.select(MapHit(target: HitTarget(info: info, type: .line, geometry: [[p, Point(p.x + 1000, p.y)]], zIndex: 0),
                              space: .metres))
        guard case .feature(let selected, _) = m.selection else {
            Issue.record("nothing selected")
            return
        }
        #expect(selected.id == "feature:4" && m.preview == nil && m.highlight != nil)
        let link = WebLink.parse(m.shareURL, server: testServer)
        guard case .map(let o) = link?.route else {
            Issue.record("not a map link")
            return
        }
        #expect(o.select == nil)
    }

    @Test func fliesToPagesAndAreas() async {
        let stack = Stack()
        stack.server.raw("/map/features", #"{"type": "FeatureCollection", "features": []}"#, query: ["refs": "ghost"])
        stack.server.status("/map/features", 500, query: ["refs": "broken"])
        stack.server.json("/map/features", "territories", query: ["refs": "testmark"])
        let m = MapModel(context: stack.context())
        await m.load()
        #expect(await m.flyTo("ghost") == false)
        #expect(await m.flyTo("broken") == false)
        let before = m.viewport
        #expect(await m.flyTo("testmark"))
        #expect(m.viewport != before && m.selection != nil)
    }

    @Test func measuresARoute() async throws {
        let stack = Stack()
        let m = MapModel(context: stack.context())
        await m.load()
        await m.selectPoint(LonLat(11, 45.5))
        m.setMeasuring(true)
        #expect(m.measuring && m.selection == nil)
        await m.tap(at: Point(100, 100))
        #expect(m.measurePoints.count == 1 && m.distance == nil && m.measuredKm == 0)
        await m.tap(at: Point(250, 400))
        #expect(m.measurePoints.count == 2 && m.distance != nil && m.measuredKm > 0)
        let link = try #require(WebLink.parse(m.shareURL, server: testServer))
        guard case .map(let o) = link.route else {
            Issue.record("not a map link")
            return
        }
        #expect(o.points.count == 2 && o.measuring)

        await m.undoMeasurePoint()
        #expect(m.measurePoints.count == 1 && m.distance == nil)
        m.clearMeasure()
        await m.undoMeasurePoint()
        #expect(m.measurePoints.isEmpty)
        await m.addMeasurePoint(LonLat(11, 45.5))
        m.setMeasuring(false)
        #expect(!m.measuring && m.measurePoints.isEmpty && m.distance == nil)
    }
}
