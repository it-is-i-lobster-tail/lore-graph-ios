import Foundation

/// A colour, red, green, blue and alpha from 0 to 1.
public struct RGBA: Hashable, Sendable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// "#3c6ea6" or "#3c6ea680".
    public init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        if s.count == 8 {
            self.init(Double((v >> 24) & 0xFF) / 255, Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255,
                      Double(v & 0xFF) / 255)
        } else {
            self.init(Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
        }
    }

    /// CSS colours as layers store them: #hex, rgb(), rgba() and hsl()/hsla().
    public init?(css: String) {
        let s = css.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") {
            self.init(hex: s)
            return
        }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let name = s[..<open]
        let parts = s[s.index(after: open)..<s.index(before: s.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "") }
        let n = parts.compactMap(Double.init)
        guard n.count == parts.count, n.count >= 3 else { return nil }
        let alpha = n.count > 3 ? n[3] : 1
        switch name {
        case "rgb", "rgba": self.init(n[0] / 255, n[1] / 255, n[2] / 255, alpha)
        case "hsl", "hsla": self = RGBA.hsl(n[0], n[1] / 100, n[2] / 100, alpha)
        default: return nil
        }
    }

    public static func hsl(_ h: Double, _ s: Double, _ l: Double, _ a: Double = 1) -> RGBA {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double)
        switch hp {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return RGBA(r + m, g + m, b + m, a)
    }

    public func opacity(_ a: Double) -> RGBA { RGBA(r, g, b, a) }
}

/// The map's colours for light and dark mode, the web app's palette (frontend styles.ts).
public struct MapPalette: Hashable, Sendable {
    public var ink, halo, land, sea, water, waterLabel, road, coast: RGBA
    public var designer, restricted, proposed, claim, danger, accent, event, telling, selected: RGBA

    public static let light = MapPalette(
        ink: RGBA(hex: "#1d2025"), halo: RGBA(1, 1, 1, 0.88), land: RGBA(hex: "#efe7d2"), sea: RGBA(hex: "#bdd3df"),
        water: RGBA(hex: "#3c6ea6"), waterLabel: RGBA(hex: "#2f5d91"), road: RGBA(hex: "#8a5a2b"), coast: RGBA(hex: "#506878"),
        designer: RGBA(hex: "#6d28d9"), restricted: RGBA(hex: "#a14d06"), proposed: RGBA(hex: "#15803d"),
        claim: RGBA(hex: "#c05f12"), danger: RGBA(hex: "#b42318"), accent: RGBA(hex: "#3f3fc4"), event: RGBA(hex: "#b42318"),
        telling: RGBA(hex: "#8a5a00"), selected: RGBA(hex: "#f59e0b"))

    public static let dark = MapPalette(
        ink: RGBA(hex: "#e7e4dc"), halo: RGBA(17 / 255, 19 / 255, 22 / 255, 0.85), land: RGBA(hex: "#25241f"),
        sea: RGBA(hex: "#16232c"), water: RGBA(hex: "#6f9fd6"), waterLabel: RGBA(hex: "#9cc0ea"), road: RGBA(hex: "#c39a6b"),
        coast: RGBA(hex: "#8fa3b0"), designer: RGBA(hex: "#a78bfa"), restricted: RGBA(hex: "#f59e0b"),
        proposed: RGBA(hex: "#4ade80"), claim: RGBA(hex: "#f0a35e"), danger: RGBA(hex: "#f87171"), accent: RGBA(hex: "#8b8bf5"),
        event: RGBA(hex: "#ff8f84"), telling: RGBA(hex: "#f2cf63"), selected: RGBA(hex: "#ffd166"))
}

/// The properties of a lore shape or generator feature, from a vector tile or map.features,
/// read the way the web app reads them (styles.ts featureInfo).
public struct FeatureInfo: Hashable, Sendable {
    public var layer: String
    public var id: String
    public var kindOf: String
    public var label: String?
    public var rank: Int
    public var role: String?
    public var type: String?
    public var kind: String?
    public var precision: String?
    public var canon: String?
    public var visibility: String?
    public var claimed: Bool
    public var uncertaintyM: Double?
    public var minZoom: Double?
    public var maxZoom: Double?
    public var cls: String?
    public var entityRef: String?
    public var entityId: String?
    public var generatorName: String?
    public var disputed: Bool
    public var ruler: String?
    public var stance: String?

    public init(layer: String, properties p: [String: JSONValue], fallbackID: String = "") {
        func str(_ k: String) -> String? {
            guard let s = p[k]?.string, !s.isEmpty else { return nil }
            return s
        }
        let entity = p["entity"] ?? p["traveller"] ?? p["ruler"]
        let base = layer.hasPrefix("base-") || layer.hasPrefix("next-") || str("kind_of") == "feature"
        self.layer = layer
        if let s = str("shape_id") { id = "shape:\(s)" } else if let f = str("feature_id") ?? (base ? str("id") : nil) {
            id = "feature:\(f)"
        } else { id = str("id") ?? fallbackID }
        kindOf = str("kind_of") ?? (base ? "feature" : "shape")
        label = base ? nil : str("label")
        rank = Int(p["rank"]?.number ?? 5)
        if rank <= 0 { rank = 5 }
        role = str("role")
        type = str("type") ?? entity?["type"]?.string
        kind = str("kind") ?? entity?["kind"]?.string
        precision = str("precision")
        canon = str("canon")
        visibility = str("visibility")
        claimed = p["claimed"]?.bool == true
        uncertaintyM = p["uncertainty_m"]?.number
        minZoom = p["min_zoom"]?.number
        maxZoom = p["max_zoom"]?.number
        cls = str("class")
        entityRef = str("slug") ?? entity?["ref"]?.string
        entityId = str("entity_id") ?? entity?["id"]?.string
        generatorName = base ? str("name") : nil
        disputed = p["disputed"]?.bool == true
        ruler = p["ruler"]?["title"]?.string
        stance = str("stance")
    }

    /// Inside its zoom band? Tiles already filter; map.features answers are filtered here.
    public func inZoomBand(_ z: Double) -> Bool {
        if let minZoom, z + 1e-6 < floor(minZoom) { return false }
        if let maxZoom, z > maxZoom + 1 { return false }
        return true
    }
}

public enum Marker: Hashable, Sendable {
    case circle
    case diamond
    case triangle
}

/// A label to place: its text, size by rank, and whether it follows a line.
public struct LabelStyle: Hashable, Sendable {
    public var text: String
    public var rank: Int
    public var alongLine: Bool
    public var italic: Bool
    public var serif: Bool
    public var colour: RGBA
    public var offsetY: Double
    public var fontSize: Double
    /// Realms and seas are letter-spaced capitals.
    public var spacedCapitals: Bool

    public var shownText: String { spacedCapitals ? text.uppercased().map(String.init).joined(separator: " ") : text }

    static func fontSize(rank: Int) -> Double {
        switch rank {
        case 1: 18
        case 2: 16
        case 3: 14
        case 4: 13
        case 5: 12
        default: 11
        }
    }
}

/// How to draw one feature: pure data the app's canvas turns into paths (DESIGN.md 13.3).
public struct FeatureStyle: Hashable, Sendable {
    public var fill: RGBA?
    public var stroke: RGBA?
    public var strokeWidth: Double = 1
    public var dash: [Double]?
    public var marker: Marker?
    public var markerRadius: Double = 4
    public var markerFill: RGBA?
    public var markerStroke: RGBA?
    public var markerStrokeWidth: Double = 1.5
    /// A soft circle sized by a vague place's uncertainty, in metres.
    public var uncertaintyMetres: Double?
    public var label: LabelStyle?
    public var zIndex: Int = 0

    public init() {}
}

/// The web app's default styles (styles.ts layerStyle), with a layer's stored style keys
/// overriding them.
public enum MapStyler {
    public static func styles(_ info: FeatureInfo, geometry: VectorTile.GeometryType, zoom z: Double,
                              layerStyle stored: [String: JSONValue] = [:], palette pal: MapPalette,
                              selected: String? = nil) -> [FeatureStyle] {
        guard info.inZoomBand(z) else { return [] }
        let isSelected = selected != nil && (selected == info.id || selected == info.entityRef)
        func num(_ k: String) -> Double? { stored[k]?.number }
        func colour(_ k: String) -> RGBA? { stored[k]?.string.flatMap(RGBA.init(css:)) }
        func dash() -> [Double]? { (stored["stroke-dash"] ?? stored["stroke-line-dash"])?.array?.compactMap(\.number) }
        func label(_ text: String, _ rank: Int, line: Bool = false, italic: Bool = false, colour c: RGBA? = nil,
                   offsetY: Double = 0) -> LabelStyle {
            LabelStyle(text: text, rank: rank, alongLine: line, italic: italic, serif: rank <= 3, colour: c ?? pal.ink,
                       offsetY: offsetY, fontSize: LabelStyle.fontSize(rank: rank), spacedCapitals: rank == 1 && !line)
        }
        var out: [FeatureStyle] = []

        // generator geometry: land, sea, lakes, coasts, rivers, roads
        if info.kindOf == "feature" {
            var s = FeatureStyle()
            let cls = info.cls ?? ""
            switch cls {
            case "land": s.fill = colour("fill-color") ?? pal.land
            case "sea", "ocean": s.fill = colour("fill-color") ?? pal.sea
            case "lake", "pond":
                s.fill = pal.sea
                s.stroke = pal.water
                s.strokeWidth = 0.8
            case "coast", "coastline":
                s.stroke = pal.coast
                s.strokeWidth = 1.2
            case "river", "stream", "creek":
                s.stroke = colour("stroke-color") ?? pal.water
                s.strokeWidth = num("stroke-width") ?? max(0.6, 3.2 - Double(info.rank) * 0.35)
            case "road", "track", "path":
                s.stroke = pal.road
                s.strokeWidth = cls == "road" ? 1.6 : 1
                s.dash = cls == "road" ? nil : [3, 3]
            default:
                s.stroke = pal.coast
                s.fill = RGBA(0, 0, 0, 0.04)
                s.marker = .circle
                s.markerRadius = 2.5
                s.markerFill = pal.coast
            }
            out.append(s)
            if isSelected { out.append(selection(pal)) }
            return out
        }

        switch info.kindOf {
        case "territory":
            let hue = Double(hash(info.ruler ?? info.label ?? "") % 360)
            var s = FeatureStyle()
            s.fill = RGBA.hsl(hue, 0.55, 0.5, num("fill-opacity") ?? 0.22)
            s.stroke = RGBA.hsl(hue, 0.45, 0.38)
            s.strokeWidth = 1.5
            s.dash = info.disputed ? [5, 4] : nil
            if z >= 3, z < 9, let l = info.label { s.label = label(l, 2) }
            s.zIndex = 1
            return [s]
        case "event":
            var s = FeatureStyle()
            if geometry == .line {
                s.stroke = pal.event
                s.strokeWidth = 2
                s.dash = [6, 4]
            }
            s.marker = .diamond
            s.markerRadius = 7
            s.markerFill = pal.event
            s.markerStroke = pal.halo
            if let l = info.label, z >= 5 { s.label = label(l, 5, colour: pal.event, offsetY: -14) }
            s.zIndex = 6
            return [s]
        case "journey":
            var s = FeatureStyle()
            s.stroke = pal.accent
            s.strokeWidth = 2.5
            s.dash = [8, 5]
            if let l = info.label { s.label = label(l, 5, line: true, colour: pal.accent) }
            s.zIndex = 3
            return [s]
        case "telling":
            var s = FeatureStyle()
            s.marker = .triangle
            s.markerRadius = 7
            s.markerFill = pal.telling
            s.markerStroke = pal.halo
            if let l = info.label, z >= 5 { s.label = label(l, 6, colour: pal.telling, offsetY: 14) }
            s.zIndex = 5
            return [s]
        case "belief":
            let fills: [String: RGBA] = ["believes": RGBA(21 / 255, 128 / 255, 61 / 255, 0.35),
                                         "suspects": RGBA(202 / 255, 138 / 255, 4 / 255, 0.35),
                                         "doubts": RGBA(234 / 255, 88 / 255, 12 / 255, 0.35),
                                         "denies": RGBA(180 / 255, 35 / 255, 24 / 255, 0.35),
                                         "unaware": RGBA(100 / 255, 100 / 255, 100 / 255, 0.2)]
            var s = FeatureStyle()
            let f = fills[info.stance ?? ""] ?? RGBA(63 / 255, 63 / 255, 196 / 255, 0.25)
            s.fill = f
            s.marker = .circle
            s.markerRadius = 9
            s.markerFill = f
            s.markerStroke = pal.ink
            s.markerStrokeWidth = 0.8
            if let l = info.label { s.label = label(l, 6, offsetY: -15) }
            s.zIndex = 4
            return [s]
        default:
            break
        }

        // lore shapes: points, footprints, extents, routes, fronts, labels
        let rank = info.rank
        let zIndex = 10 - rank
        let showLabel = info.label != nil && !(info.role == "extent" && z >= 9) && !(info.role == "territory" && z >= 9)
        if info.role == "label" {
            guard let l = info.label else { return [] }
            var s = FeatureStyle()
            s.label = label(l, rank, line: geometry == .line)
            s.zIndex = zIndex
            return [s]
        }
        func statusStroke(_ base: RGBA, _ width: Double, into s: inout FeatureStyle) {
            s.stroke = base
            s.strokeWidth = width
            if info.canon == "proposed" || info.canon == "draft" {
                s.stroke = pal.proposed
                s.dash = [6, 4]
            } else if info.claimed {
                s.stroke = pal.claim
                s.dash = [4, 4]
            } else if info.visibility == "designer" {
                s.stroke = pal.designer
                s.strokeWidth = width + 0.5
            } else if info.visibility == "restricted" {
                s.stroke = pal.restricted
                s.strokeWidth = width + 0.5
            }
        }
        var s = FeatureStyle()
        switch geometry {
        case .point, .unknown:
            let vague = ["region", "disputed", "rumoured"].contains(info.precision ?? "")
            if (vague || info.uncertaintyM != nil), let u = info.uncertaintyM, u > 0 { s.uncertaintyMetres = u }
            let r = num("circle-radius") ?? max(2.5, 7.5 - Double(rank))
            s.marker = .circle
            s.markerRadius = r
            s.markerFill = info.type == "event" ? pal.event : pal.ink
            var ring = FeatureStyle()
            statusStroke(pal.halo, 1.5, into: &ring)
            s.markerStroke = ring.stroke
            s.markerStrokeWidth = ring.strokeWidth
            if showLabel, let l = info.label { s.label = label(l, rank, offsetY: -(r + 9)) }
            s.zIndex = zIndex
        case .polygon:
            let width = num("stroke-width") ?? (info.role == "extent" ? 1.5 : 1.2)
            let strokeColour = colour("stroke-color") ?? (info.role == "footprint" ? pal.ink : pal.ink.opacity(0.55))
            s.fill = colour("fill-color") ?? (info.role == "footprint" ? pal.ink.opacity(0.12) : nil)
            statusStroke(strokeColour, width, into: &s)
            if showLabel, info.role == "extent" || info.role == "territory", let l = info.label { s.label = label(l, min(rank, 2)) }
            s.zIndex = info.role == "footprint" ? zIndex : 0
        case .line:
            statusStroke(colour("stroke-color") ?? (info.role == "front" ? pal.danger : pal.road), num("stroke-width") ?? 2, into: &s)
            if s.dash == nil { s.dash = dash() }
            if showLabel, let l = info.label { s.label = label(l, max(rank, 4), line: true) }
            s.zIndex = 2
        }
        out.append(s)
        if isSelected { out.append(selection(pal)) }
        return out
    }

    static func selection(_ pal: MapPalette) -> FeatureStyle {
        var s = FeatureStyle()
        s.stroke = pal.selected
        s.strokeWidth = 4
        s.marker = .circle
        s.markerRadius = 12
        s.markerStroke = pal.selected
        s.markerStrokeWidth = 3
        s.zIndex = 20
        return s
    }

    /// A stable number for a name (the web app's hue hash).
    public static func hash(_ text: String) -> Int {
        var h: Int32 = 0
        for unit in text.utf16 { h = h &* 31 &+ Int32(unit) }
        return abs(Int(h))
    }
}
