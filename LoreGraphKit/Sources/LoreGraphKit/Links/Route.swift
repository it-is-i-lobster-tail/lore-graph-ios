import Foundation

public struct FamilyOptions: Hashable, Sendable, Codable {
    public enum Mode: String, Codable, Sendable, CaseIterable { case hourglass, ancestors, descendants }

    public var up: Int
    public var down: Int
    public var mode: Mode
    public var account: String?

    public init(up: Int = 2, down: Int = 2, mode: Mode = .hourglass, account: String? = nil) {
        self.up = up
        self.down = down
        self.mode = mode
        self.account = account
    }
}

public struct GraphOptions: Hashable, Sendable, Codable {
    public var focus: [String]
    public var depth: Int
    public var path: [String]

    public init(focus: [String] = [], depth: Int = 1, path: [String] = []) {
        self.focus = focus
        self.depth = depth
        self.path = path
    }
}

public struct TimelineOptions: Hashable, Sendable, Codable {
    public var about: [String]
    public var from: String?
    public var to: String?
    public var lanes: String?
    public var claims: Bool

    public init(about: [String] = [], from: String? = nil, to: String? = nil, lanes: String? = nil, claims: Bool = false) {
        self.about = about
        self.from = from
        self.to = to
        self.lanes = lanes
        self.claims = claims
    }
}

public struct MapOptions: Hashable, Sendable, Codable {
    public var centre: LonLat?
    public var zoom: Double?
    public var layers: [String]?
    public var base: BaseMap?
    public var place: LonLat?
    public var points: [LonLat]
    public var measuring: Bool
    /// A page to fly to and select.
    public var select: String?

    public init(centre: LonLat? = nil, zoom: Double? = nil, layers: [String]? = nil, base: BaseMap? = nil,
                place: LonLat? = nil, points: [LonLat] = [], measuring: Bool = false, select: String? = nil) {
        self.centre = centre
        self.zoom = zoom
        self.layers = layers
        self.base = base
        self.place = place
        self.points = points
        self.measuring = measuring
        self.select = select
    }
}

/// A screen of the app, named like the web app's routes (DESIGN.md 12.3) so web links open the
/// same view (F-11.2) and every screen can be shared as a web link (F-11.3).
public enum Route: Hashable, Sendable, Codable {
    case home
    case browse(type: EntityType?)
    case page(String)
    case records(String)
    case links(String)
    case history(String)
    case record(String)
    case compare(String)
    case beliefs(String)
    case beliefQuestion(String)
    case beliefTrace(String)
    case faction(String)
    case family(String, FamilyOptions)
    case graph(GraphOptions)
    case timeline(TimelineOptions)
    case map(MapOptions)
    case search(String)
    case trail(String)
    case savedView(String)
}

/// A web link read into a route with its world and view.
public struct WebLink: Hashable, Sendable {
    public var route: Route
    public var world: String?
    public var view: ViewState
    /// The selected item (`sel`), such as the second person for kinship.
    public var selected: String?

    public init(route: Route, world: String? = nil, view: ViewState = .default, selected: String? = nil) {
        self.route = route
        self.world = world
        self.view = view
        self.selected = selected
    }

    /// Reads a loregraph web address (https on the reader's server) or an app link
    /// (`loregraph://wiki/dirk`). Returns nil for anything else, including other servers.
    public static func parse(_ url: URL, server: URL?) -> WebLink? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var path: String
        if c.scheme == OAuthClient.callbackScheme {
            guard let host = c.host, host != "oauth" else { return nil }
            path = "/" + host + c.path
        } else {
            guard c.scheme == "https" || c.scheme == "http", let server else { return nil }
            let s = URLComponents(url: server, resolvingAgainstBaseURL: false)
            guard c.host?.lowercased() == s?.host?.lowercased(), c.port == s?.port else { return nil }
            path = c.path
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let q = Dictionary((c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        var view = ViewState()
        if let y = q["y"].flatMap(Double.init) { view.asOf = y }
        if let vp = q["vp"], !vp.isEmpty { view.viewpoint = .init(ref: vp, title: vp) }
        if let cal = q["cal"], !cal.isEmpty { view.calendar = cal }
        if let a = q["as"].flatMap(Visibility.init(rawValue:)), a != .designer { view.viewAs = a }
        guard let route = route(path: path, q) else { return nil }
        return WebLink(route: route, world: q["w"].flatMap { $0.isEmpty ? nil : $0 }, view: view, selected: q["sel"])
    }

    static func list(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func lonLat(_ s: String?) -> LonLat? {
        guard let s else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, abs(parts[0]) <= 180, abs(parts[1]) <= 90 else { return nil }
        return LonLat(parts[0], parts[1])
    }

    static func route(path: String, _ q: [String: String]) -> Route? {
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch parts.count {
        case 0:
            return .home
        case 1:
            switch parts[0] {
            case "wiki": return .browse(type: q["type"].flatMap(EntityType.init(rawValue:)))
            case "graph":
                return .graph(GraphOptions(focus: list(q["focus"]), depth: q["depth"].flatMap(Int.init).map { max(1, min(3, $0)) } ?? 1,
                                           path: list(q["path"])))
            case "timeline":
                return .timeline(TimelineOptions(about: list(q["about"]), from: q["from"], to: q["to"], lanes: q["lanes"],
                                                 claims: ["1", "true", "yes"].contains((q["claims"] ?? "").lowercased())))
            case "map":
                let pts = (q["pts"] ?? "").split(separator: ";").compactMap { lonLat(String($0)) }
                return .map(MapOptions(centre: lonLat(q["c"]), zoom: q["z"].flatMap(Double.init),
                                       layers: q["l"].map { list($0) }, base: q["base"].flatMap(BaseMap.init(rawValue:)),
                                       place: lonLat(q["place"]), points: pts, measuring: q["tool"] == "measure",
                                       select: q["sel"]))
            case "search": return .search(q["q"] ?? "")
            case "family", "factions", "beliefs": return .home
            default: return nil
            }
        case 2:
            let ref = parts[1]
            switch parts[0] {
            case "wiki": return .page(ref)
            case "records": return .record(ref)
            case "compare": return .compare(ref)
            case "beliefs": return .beliefs(ref)
            case "factions": return .faction(ref)
            case "family":
                let mode = q["mode"].flatMap(FamilyOptions.Mode.init(rawValue:)) ?? .hourglass
                return .family(ref, FamilyOptions(up: q["up"].flatMap(Int.init).map { max(0, min(10, $0)) } ?? 2,
                                                  down: q["down"].flatMap(Int.init).map { max(0, min(10, $0)) } ?? 2,
                                                  mode: mode, account: q["account"]))
            case "trails": return .trail(ref)
            case "v": return .savedView(ref)
            default: return nil
            }
        case 3:
            switch (parts[0], parts[2]) {
            case ("wiki", "records"): return .records(parts[1])
            case ("wiki", "links"): return .links(parts[1])
            case ("wiki", "history"): return .history(parts[1])
            case ("beliefs", _) where parts[1] == "q": return .beliefQuestion(parts[2])
            case ("beliefs", _) where parts[1] == "trace": return .beliefTrace(parts[2])
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The web address of this link on a server, for sharing (F-11.3). Defaults are left out,
    /// as the server's own links leave them out.
    public func url(server: URL) -> URL {
        var path = "/"
        var q: [(String, String)] = []
        func esc(_ s: String) -> String { segment(s) }
        switch route {
        case .home: path = "/"
        case .browse(let type):
            path = "/wiki"
            if let type { q.append(("type", type.rawValue)) }
        case .page(let r): path = "/wiki/\(esc(r))"
        case .records(let r): path = "/wiki/\(esc(r))/records"
        case .links(let r): path = "/wiki/\(esc(r))/links"
        case .history(let r): path = "/wiki/\(esc(r))/history"
        case .record(let id): path = "/records/\(esc(id))"
        case .compare(let r): path = "/compare/\(esc(r))"
        case .beliefs(let r): path = "/beliefs/\(esc(r))"
        case .beliefQuestion(let k): path = "/beliefs/q/\(esc(k))"
        case .beliefTrace(let id): path = "/beliefs/trace/\(esc(id))"
        case .faction(let r): path = "/factions/\(esc(r))"
        case .family(let r, let o):
            path = "/family/\(esc(r))"
            if o.up != 2 { q.append(("up", String(o.up))) }
            if o.down != 2 { q.append(("down", String(o.down))) }
            if o.mode != .hourglass { q.append(("mode", o.mode.rawValue)) }
            if let a = o.account { q.append(("account", a)) }
        case .graph(let o):
            path = "/graph"
            if !o.focus.isEmpty { q.append(("focus", o.focus.joined(separator: ","))) }
            if o.depth != 1 { q.append(("depth", String(o.depth))) }
            if !o.path.isEmpty { q.append(("path", o.path.joined(separator: ","))) }
        case .timeline(let o):
            path = "/timeline"
            if !o.about.isEmpty { q.append(("about", o.about.joined(separator: ","))) }
            if let f = o.from { q.append(("from", f)) }
            if let t = o.to { q.append(("to", t)) }
            if let l = o.lanes { q.append(("lanes", l)) }
            if o.claims { q.append(("claims", "1")) }
        case .map(let o):
            path = "/map"
            func ll(_ p: LonLat) -> String { String(format: "%.4f,%.4f", p.lon, p.lat) }
            if let c = o.centre { q.append(("c", ll(c))) }
            if let z = o.zoom { q.append(("z", ViewState.yearText((z * 100).rounded() / 100))) }
            if let l = o.layers { q.append(("l", l.joined(separator: ","))) }
            if let b = o.base { q.append(("base", b.rawValue)) }
            if let p = o.place { q.append(("place", ll(p))) }
            if !o.points.isEmpty { q.append(("pts", o.points.map(ll).joined(separator: ";"))) }
            if o.measuring { q.append(("tool", "measure")) }
            if let s = o.select { q.append(("sel", s)) }
        case .search(let text):
            path = "/search"
            if !text.isEmpty { q.append(("q", text)) }
        case .trail(let s): path = "/trails/\(esc(s))"
        case .savedView(let s): path = "/v/\(esc(s))"
        }
        if let world { q.append(("w", world)) }
        if let y = view.asOf { q.append(("y", ViewState.yearText(y))) }
        if let vp = view.viewpoint { q.append(("vp", vp.ref)) }
        if let cal = view.calendar { q.append(("cal", cal)) }
        if let a = view.viewAs, a != .designer { q.append(("as", a.rawValue)) }
        if let selected, !q.contains(where: { $0.0 == "sel" }) { q.append(("sel", selected)) }
        var c = URLComponents(url: OAuthClient.normalised(server), resolvingAgainstBaseURL: false)!
        c.percentEncodedPath = path
        if !q.isEmpty {
            c.percentEncodedQueryItems = q.map { URLQueryItem(name: $0.0, value: Endpoint<JSONValue>.encode($0.1)) }
        }
        return c.url!
    }
}
