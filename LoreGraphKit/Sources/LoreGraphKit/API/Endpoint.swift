import Foundation

/// How a cached answer is checked before it is shown as current.
public enum Freshness: String, Sendable, Hashable, Codable {
    /// Lore that changes with revisions: current while the world's newest revision is the same.
    case lore
    /// Map answers: current while the map version is the same.
    case map
    /// Never cached (who you are, the newest revision itself, typed dates).
    case live
}

/// A read: path under /api/v1, its query, and how it is cached.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var path: String
    public var query: [URLQueryItem]
    /// Whether as_of, viewpoint, calendar and view_as are added.
    public var readsView: Bool
    /// Whether `world=` is added (everything but the list of worlds and who you are).
    public var worldScoped: Bool
    public var freshness: Freshness

    public init(_ path: String, query: [URLQueryItem] = [], readsView: Bool = true, worldScoped: Bool = true,
                freshness: Freshness = .lore) {
        self.path = path
        self.query = query
        self.readsView = readsView
        self.worldScoped = worldScoped
        self.freshness = freshness
    }

    /// The full address for a world and a view.
    public func url(base: URL, world: String?, view: ViewState) -> URL {
        var items = query.filter { $0.value != nil }
        if readsView { items += view.queryItems }
        if worldScoped, let world { items.append(URLQueryItem(name: "world", value: world)) }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let basePath = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
        c.percentEncodedPath = basePath + "/api/v1" + path
        c.percentEncodedQueryItems = items.isEmpty ? nil : items.map {
            URLQueryItem(name: Self.encode($0.name), value: $0.value.map(Self.encode))
        }
        return c.url!
    }

    /// The cache key: the address without the server, with the query sorted so the same read
    /// always lands on the same entry.
    public func cacheKey(world: String?, view: ViewState) -> String {
        let u = url(base: URL(string: "https://cache.invalid")!, world: world, view: view)
        let c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
        let q = (c.percentEncodedQueryItems ?? []).map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        return c.percentEncodedPath + (q.isEmpty ? "" : "?" + q)
    }

    static func encode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~,:;")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// A path segment from a ref (slug, id, `kind:key` or a name), percent-encoded.
func segment(_ ref: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~:")
    return ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref
}

func item(_ name: String, _ value: String?) -> URLQueryItem? {
    guard let value, !value.isEmpty else { return nil }
    return URLQueryItem(name: name, value: value)
}

func item(_ name: String, _ value: Int?) -> URLQueryItem? {
    value.map { URLQueryItem(name: name, value: String($0)) }
}

func item(_ name: String, _ value: Bool) -> URLQueryItem? {
    value ? URLQueryItem(name: name, value: "true") : nil
}

/// A list as repeated parameters (`layers=a&layers=b`), as the web app sends them.
func items(_ name: String, _ values: [String]?) -> [URLQueryItem] {
    (values ?? []).filter { !$0.isEmpty }.map { URLQueryItem(name: name, value: $0) }
}

/// Every read the app makes, one function per loregraph operation it uses.
public enum API {
    public static func me() -> Endpoint<Me> { Endpoint("/me", readsView: false, worldScoped: false, freshness: .live) }

    public static func worlds() -> Endpoint<WorldList> {
        Endpoint("/worlds", readsView: false, worldScoped: false, freshness: .live)
    }

    public static func about() -> Endpoint<About> { Endpoint("/about", readsView: false) }

    /// The newest visible revision: the world's freshness mark.
    public static func historyHead() -> Endpoint<HistoryHead> {
        Endpoint("/history", query: [URLQueryItem(name: "limit", value: "1")], readsView: false, freshness: .live)
    }

    public static func pageHistory(_ ref: String, limit: Int = 20) -> Endpoint<PageHistory> {
        Endpoint("/entities/\(segment(ref))/history", query: [URLQueryItem(name: "limit", value: String(limit))],
                 readsView: false)
    }

    public static func entities(type: EntityType? = nil, kind: String? = nil, category: String? = nil,
                                sort: String = "title", cursor: String? = nil, limit: Int = 50) -> Endpoint<Page<EntityListItem>> {
        Endpoint("/entities", query: [item("type", type?.rawValue), item("kind", kind), item("category", category),
                                      item("sort", sort), item("cursor", cursor), item("limit", limit)].compactMap { $0 })
    }

    public static func entity(_ ref: String) -> Endpoint<EntityDetail> {
        Endpoint("/entities/\(segment(ref))", query: [
            URLQueryItem(name: "detail", value: "full"),
            URLQueryItem(name: "include", value: "html"),
            URLQueryItem(name: "include", value: "media"),
            URLQueryItem(name: "include", value: "shapes"),
        ])
    }

    /// A short preview of a page for the long-press card (F-4.6).
    public static func preview(_ ref: String) -> Endpoint<EntityDetail> {
        Endpoint("/entities/\(segment(ref))", query: [URLQueryItem(name: "detail", value: "brief"),
                                                      URLQueryItem(name: "include", value: "html"),
                                                      URLQueryItem(name: "include", value: "media"),
                                                      URLQueryItem(name: "sections", value: "lead")])
    }

    public static func backlinks(_ ref: String, cursor: String? = nil) -> Endpoint<Backlinks> {
        Endpoint("/entities/\(segment(ref))/backlinks", query: [item("limit", 100), item("cursor", cursor)].compactMap { $0 })
    }

    public static func views() -> Endpoint<ViewsAndTrails> {
        Endpoint("/views", query: [URLQueryItem(name: "trails", value: "true")], readsView: false)
    }

    public static func search(_ q: String, types: [EntityType] = [], cursor: String? = nil) -> Endpoint<SearchResults> {
        Endpoint("/search", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "passages", value: "2"),
                                    URLQueryItem(name: "limit", value: "20")]
                    + items("types", types.map(\.rawValue)) + [item("cursor", cursor)].compactMap { $0 })
    }

    public static func suggest(_ q: String, types: [EntityType] = [], limit: Int = 8) -> Endpoint<Suggestions> {
        Endpoint("/search/resolve", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "mode", value: "suggest"),
                                            URLQueryItem(name: "limit", value: String(limit))] + items("types", types.map(\.rawValue)))
    }

    public static func statements(entity: String, predicate: String? = nil, family: String? = nil,
                                  cursor: String? = nil) -> Endpoint<StatementList> {
        Endpoint("/statements", query: [item("entity", entity), item("predicate", predicate), item("family", family),
                                        item("limit", 200), item("cursor", cursor)].compactMap { $0 })
    }

    public static func statement(_ id: String) -> Endpoint<StatementDetail> { Endpoint("/statements/\(segment(id))") }

    public static func whoKnows(_ id: String) -> Endpoint<WhoKnows> { Endpoint("/statements/\(segment(id))/who-knows") }

    public static func accounts(_ ref: String) -> Endpoint<AccountList> { Endpoint("/entities/\(segment(ref))/accounts") }

    public static func compare(_ ref: String) -> Endpoint<AccountsCompared> {
        Endpoint("/accounts/compare", query: [URLQueryItem(name: "ref", value: ref)])
    }

    public static func beliefs(of holder: String, includeOverridden: Bool = true) -> Endpoint<BeliefsOf> {
        Endpoint("/holders/\(segment(holder))/beliefs", query: [item("include_overridden", includeOverridden)].compactMap { $0 })
    }

    public static func lineage(_ beliefId: String) -> Endpoint<BeliefLineage> { Endpoint("/beliefs/\(segment(beliefId))/lineage") }

    public static func holders(question key: String) -> Endpoint<BeliefHolders> {
        Endpoint("/beliefs/holders", query: [URLQueryItem(name: "key", value: key)])
    }

    public static func factionTree(_ ref: String) -> Endpoint<FactionTree> { Endpoint("/factions/\(segment(ref))/tree") }

    public static func memberships(group: String) -> Endpoint<Memberships> {
        Endpoint("/memberships", query: [URLQueryItem(name: "group", value: group), URLQueryItem(name: "limit", value: "200")])
    }

    public static func timeline(about: [String] = [], from: String? = nil, to: String? = nil, lanes: String? = nil,
                                claims: Bool = false, cursor: String? = nil) -> Endpoint<Timeline> {
        Endpoint("/timeline", query: items("about", about) + [item("from", from), item("to", to), item("lanes", lanes),
                                                             item("claims", claims), item("limit", 500),
                                                             item("cursor", cursor)].compactMap { $0 })
    }

    /// The world's eras (the timeline's first item only), for the map's time slider.
    public static func eras() -> Endpoint<Timeline> {
        Endpoint("/timeline", query: [URLQueryItem(name: "limit", value: "1")])
    }

    public static func familyTree(_ ref: String, up: Int = 2, down: Int = 2, mode: String = "hourglass",
                                  account: String? = nil) -> Endpoint<FamilyTree> {
        Endpoint("/people/\(segment(ref))/family-tree", query: [item("up", up), item("down", down), item("mode", mode),
                                                                item("account", account)].compactMap { $0 })
    }

    public static func kinship(_ a: String, _ b: String) -> Endpoint<Kinship> {
        Endpoint("/people/kinship", query: [URLQueryItem(name: "a", value: a), URLQueryItem(name: "b", value: b)])
    }

    public static func neighbourhood(roots: [String], depth: Int = 1, families: [String] = [], types: [EntityType] = [],
                                     claims: Bool = false, maxNodes: Int = 60) -> Endpoint<Neighbourhood> {
        Endpoint("/graph/neighbourhood", query: items("roots", roots) + [item("depth", depth)] .compactMap { $0 }
                    + items("families", families) + items("types", types.map(\.rawValue))
                    + [item("claims", claims ? "all" : nil), item("max_nodes", maxNodes)].compactMap { $0 })
    }

    public static func paths(from a: String, to b: String) -> Endpoint<GraphPaths> {
        Endpoint("/graph/path", query: [URLQueryItem(name: "from", value: a), URLQueryItem(name: "to", value: b),
                                        URLQueryItem(name: "limit", value: "5")])
    }

    public static func mapLayers() -> Endpoint<MapLayers> { Endpoint("/map/layers", readsView: false, freshness: .map) }

    public static func mapVersion() -> Endpoint<MapVersion> {
        Endpoint("/map/version", readsView: false, freshness: .live)
    }

    public static func placesAt(lon: Double, lat: Double) -> Endpoint<PlacesAt> {
        Endpoint("/map/at", query: [URLQueryItem(name: "lon", value: coordinate(lon)),
                                    URLQueryItem(name: "lat", value: coordinate(lat)),
                                    URLQueryItem(name: "limit", value: "6")], freshness: .map)
    }

    public static func distance(_ waypoints: [String]) -> Endpoint<Distance> {
        Endpoint("/map/distance", query: [URLQueryItem(name: "waypoints", value: waypoints.joined(separator: ";"))],
                 freshness: .map)
    }

    /// Derived layers (events, journeys, tellings, beliefs) for the visible area.
    public static func features(layers: [String], bbox: (Double, Double, Double, Double), zoom: Int,
                                windowYears: Int = 25, question: String? = nil) -> Endpoint<GeoJSONCollection> {
        Endpoint("/map/features", query: items("layers", layers)
                    + [bbox.0, bbox.1, bbox.2, bbox.3].map { URLQueryItem(name: "bbox", value: coordinate($0)) }
                    + [item("zoom", zoom), item("window_years", windowYears), item("question", question),
                       item("limit", 2000)].compactMap { $0 }, freshness: .map)
    }

    /// Where a page is on the map, to fly there (F-7.7).
    public static func shapes(of ref: String) -> Endpoint<GeoJSONCollection> {
        Endpoint("/map/features", query: [URLQueryItem(name: "refs", value: ref), URLQueryItem(name: "limit", value: "50")],
                 freshness: .map)
    }

    public static func territories(bbox: (Double, Double, Double, Double), zoom: Int) -> Endpoint<GeoJSONCollection> {
        Endpoint("/map/territories", query: [bbox.0, bbox.1, bbox.2, bbox.3].map { URLQueryItem(name: "bbox", value: coordinate($0)) }
                    + [item("zoom", zoom)].compactMap { $0 }, freshness: .map)
    }

    public static func convertDate(_ text: String) -> Endpoint<DateConversion> {
        Endpoint("/dates/convert", query: [URLQueryItem(name: "text", value: text)], readsView: false, freshness: .live)
    }

    static func coordinate(_ v: Double) -> String { String(format: "%.5f", v) }
}
