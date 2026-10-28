import Foundation
@testable import LoreGraphKit

/// The made-up server every test talks to. Fixtures were recorded from the Testmark world.
let testServer = URL(string: "https://lore.example.test")!

enum Fixture {
    static func url(_ name: String, ext: String = "json") -> URL {
        let parts = name.split(separator: "/").map(String.init)
        let dir = (["Fixtures"] + parts.dropLast()).joined(separator: "/")
        guard let url = Bundle.module.url(forResource: parts.last!, withExtension: ext, subdirectory: dir) else {
            fatalError("missing fixture \(name).\(ext)")
        }
        return url
    }

    static func data(_ name: String, ext: String = "json") -> Data {
        try! Data(contentsOf: url(name, ext: ext))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: data(name))
    }

    static func tile(_ name: String) -> Data? {
        let parts = ["Fixtures", "tiles"].joined(separator: "/")
        return Bundle.module.url(forResource: name, withExtension: "mvt", subdirectory: parts).flatMap { try? Data(contentsOf: $0) }
    }
}

/// A scripted loregraph server: routes by path (and some query values) to fixtures or handlers,
/// and records every request. Later routes win over earlier ones.
final class FakeServer: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) throws -> HTTPResponse

    private struct Route {
        var path: String
        var query: [String: String]
        var method: String?
        var handler: Handler
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var log: [HTTPRequest] = []
    /// Answers for anything unrouted.
    var fallback: Handler = { _ in HTTPResponse(status: 404, body: Fixture.data("not-found")) }

    var requests: [HTTPRequest] { lock.withLock { log } }

    /// A route under /api/v1 (or a full path starting with "/." or "/oauth").
    func on(_ path: String, query: [String: String] = [:], method: String? = nil, _ handler: @escaping Handler) {
        let full = path.hasPrefix("/.") || path.hasPrefix("/oauth") || path.hasPrefix("/media") ? path : "/api/v1" + path
        lock.withLock { routes.append(Route(path: full, query: query, method: method, handler: handler)) }
    }

    func json(_ path: String, _ fixture: String, query: [String: String] = [:], status: Int = 200) {
        let body = Fixture.data(fixture)
        on(path, query: query) { _ in HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: body) }
    }

    func json<T: Encodable>(_ path: String, value: T, query: [String: String] = [:], status: Int = 200) {
        let body = try! JSONCoding.encoder.encode(value)
        on(path, query: query) { _ in HTTPResponse(status: status, body: body) }
    }

    func status(_ path: String, _ status: Int, body: Data = Data(), query: [String: String] = [:]) {
        on(path, query: query) { _ in HTTPResponse(status: status, body: body) }
    }

    func offline(_ path: String) {
        on(path) { _ in throw TransportError(message: "offline", isOffline: true) }
    }

    func count(_ path: String) -> Int {
        let full = path.hasPrefix("/.") || path.hasPrefix("/oauth") ? path : "/api/v1" + path
        return requests.filter { $0.url.path == full }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let q = Dictionary((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let route: Route? = lock.withLock {
            log.append(request)
            return routes.last { r in
                r.path == request.url.path && (r.method == nil || r.method == request.method)
                    && r.query.allSatisfy { q[$0.key] == $0.value }
            }
        }
        return try (route?.handler ?? fallback)(request)
    }

    /// The Testmark server with every fixture routed.
    static func testmark() -> FakeServer {
        let s = FakeServer()
        s.json("/.well-known/oauth-authorization-server", "oauth-metadata")
        s.json("/me", "me")
        s.json("/worlds", "worlds")
        s.json("/about", "about")
        s.json("/history", "history-latest")
        s.json("/entities", "entities-list")
        s.json("/entities", "entities-list-individual", query: ["type": "individual"])
        for (ref, file) in [("dirk", "entity-dirk"), ("lampton", "entity-lampton"), ("battle-at-the-ford", "entity-battle"),
                            ("testmark", "entity-testmark"), ("testmark-chronicle", "entity-chronicle")] {
            s.json("/entities/\(ref)", file)
        }
        s.json("/entities/dirk/backlinks", "backlinks-dirk")
        s.json("/entities/dirk/history", "history-dirk")
        s.json("/entities/battle-at-the-ford/accounts", "accounts-battle")
        s.json("/accounts/compare", "compare-battle")
        s.json("/search", "search-ford")
        s.json("/search/resolve", "resolve-lam")
        s.json("/statements", "statements-dirk")
        s.json("/timeline", "timeline")
        s.json("/timeline", "timeline-lanes", query: ["lanes": "type"])
        s.json("/timeline", "timeline-dirk", query: ["about": "dirk"])
        s.json("/people/dirk/family-tree", "family-dirk")
        s.json("/people/cato/family-tree", "family-cato")
        s.json("/people/kinship", "kinship")
        s.json("/graph/neighbourhood", "graph-dirk")
        s.json("/graph/path", "path")
        s.json("/holders/fenn/beliefs", "beliefs-fenn")
        s.json("/holders/dirk/beliefs", "beliefs-dirk")
        s.json("/holders/testmark/beliefs", "beliefs-testmark")
        s.json("/factions/testmark/tree", "faction-tree")
        s.json("/memberships", "memberships")
        s.json("/views", "views")
        s.json("/map/layers", "map-layers")
        s.json("/map/version", "map-version")
        s.json("/map/at", "map-at")
        s.json("/map/distance", "map-distance")
        s.json("/map/features", "features-derived")
        s.json("/map/features", "features-ref", query: ["refs": "lampton"])
        s.json("/map/territories", "territories")
        s.json("/dates/convert", "dates-convert")
        s.json("/dates/convert", "dates-convert-bad", query: ["text": "nonsense"], status: 422)
        s.json("/beliefs/holders", "holders-ford")
        s.json("/statements/00000000-0000-7000-8000-000000000120", "statement-one")
        s.json("/statements/00000000-0000-7000-8000-000000000120/who-knows", "who-knows")
        // vector tiles from the recorded ones; anything else is empty
        let previous = s.fallback
        s.fallback = { request in
            let path = request.url.path
            if path.hasPrefix("/api/v1/map/tiles/") {
                let parts = path.dropFirst("/api/v1/map/tiles/".count).replacingOccurrences(of: ".mvt", with: "").split(separator: "/")
                let name = parts.joined(separator: "-")
                if let data = Fixture.tile(name) { return HTTPResponse(status: 200, body: data) }
                return HTTPResponse(status: 204)
            }
            if path.hasPrefix("/api/v1/map/raster-tiles/") { return HTTPResponse(status: 200, body: Data([0x89, 0x50, 0x4E, 0x47])) }
            return try previous(request)
        }
        return s
    }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    var function: @Sendable () -> Date { { [self] in now } }
}

/// A fresh folder under the system's temporary folder.
func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lgk-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A signed-in reading stack over a fake server.
struct Stack {
    let server: FakeServer
    let clock: TestClock
    let folder: URL
    let auth: AuthSession
    let client: APIClient
    let repository: Repository
    let tiles: TileStore

    init(server: FakeServer = .testmark(), clock: TestClock = TestClock(), ttl: TimeInterval = 30,
         credentials: Credentials = Credentials(kind: .personal, server: testServer, accessToken: "token-1")) {
        self.server = server
        self.clock = clock
        folder = temporaryFolder()
        auth = AuthSession(store: MemoryTokenStore(credentials), transport: server, now: clock.function)
        let client = APIClient(server: testServer, transport: server, auth: auth)
        self.client = client
        let freshness = FreshnessTracker(ttl: ttl, now: clock.function,
                                         lore: { world in try await client.get(API.historyHead(), world: world).value.newest?.id ?? 0 },
                                         map: { world in Int64(try await client.get(API.mapVersion(), world: world).value.version) })
        repository = Repository(client: client, cache: DiskCache(directory: folder.appendingPathComponent("api"), limitBytes: 10_000_000,
                                                                 now: clock.function),
                                freshness: freshness, now: clock.function)
        tiles = TileStore(client: client, cache: DiskCache(directory: folder.appendingPathComponent("tiles"), limitBytes: 10_000_000,
                                                           now: clock.function))
    }

    func context(world: String? = "main", view: ViewState = .default, present: Double = 1131.25,
                 ceiling: Visibility = .designer) -> ReadContext {
        ReadContext(repository: repository, tiles: tiles, server: testServer, world: world, view: view, present: present,
                    ceiling: ceiling)
    }
}

/// Waits until a condition holds, giving tasks the main actor needs a chance to run.
@MainActor
func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let end = clock.now + timeout
    while clock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

extension HTTPRequest {
    var query: [String: [String]] {
        var out: [String: [String]] = [:]
        for i in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[i.name, default: []].append(i.value ?? "") }
        return out
    }

    var form: [String: String] {
        let text = String(decoding: body ?? Data(), as: UTF8.self)
        var out: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }
}

// Literal syntax for building tile properties and styles in tests.
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
