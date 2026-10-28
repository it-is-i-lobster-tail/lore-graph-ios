import Foundation

/// One tile of one layer as the map asks for it: vector tiles of lore shapes depend on the year
/// and viewpoint, everything on the map version, so a key never goes stale (DESIGN.md 13.5).
public struct TileRequest: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Hashable, Sendable { case vector, raster }

    public var kind: Kind
    public var layer: String
    public var tile: TileID
    /// Lore shapes only: the whole year shown (the web app floors it too) and the viewpoint.
    public var year: Int?
    public var viewpoint: String?
    public var version: Int
    public var world: String?

    public init(kind: Kind = .vector, layer: String, tile: TileID, year: Int? = nil, viewpoint: String? = nil,
                version: Int, world: String? = nil) {
        self.kind = kind
        self.layer = layer
        self.tile = tile
        self.year = year
        self.viewpoint = viewpoint
        self.version = version
        self.world = world
    }

    public var path: String {
        let l = segment(layer)
        switch kind {
        case .vector: return "/map/tiles/\(l)/\(tile.z)/\(tile.x)/\(tile.y).mvt"
        case .raster: return "/map/raster-tiles/\(l)/\(tile.z)/\(tile.x)/\(tile.y)"
        }
    }

    public var query: [URLQueryItem] {
        var q: [URLQueryItem] = []
        if let year { q.append(URLQueryItem(name: "year", value: String(year))) }
        if let viewpoint { q.append(URLQueryItem(name: "viewpoint", value: viewpoint)) }
        q.append(URLQueryItem(name: "v", value: String(version)))
        return q
    }

    /// The disk cache key.
    public var cacheKey: String {
        Endpoint<JSONValue>(path, query: query, readsView: false, worldScoped: true, freshness: .map)
            .cacheKey(world: world, view: .default)
    }

    /// The same tile one level up, for drawing while this one loads.
    public var parent: TileRequest? {
        guard let p = tile.parent else { return nil }
        var r = self
        r.tile = p.tile
        return r
    }

    public var description: String { "\(kind.rawValue):\(layer)/\(tile)" }
}

/// A small least-recently-used store.
struct LRU<Key: Hashable, Value> {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }

    mutating func get(_ key: Key) -> Value? {
        guard let v = values[key] else { return nil }
        touch(key)
        return v
    }

    func peek(_ key: Key) -> Value? { values[key] }

    mutating func set(_ key: Key, _ value: Value) {
        if values[key] == nil, values.count >= capacity, let oldest = order.first {
            order.removeFirst()
            values[oldest] = nil
        }
        values[key] = value
        touch(key)
    }

    mutating func removeAll() {
        values = [:]
        order = []
    }

    private mutating func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// Fetches tiles once: from memory, else the disk cache, else the server, one request per tile
/// however many screens ask. An empty tile (204) is remembered as empty.
public actor TileStore {
    public enum Tile: Sendable {
        case vector(VectorTile)
        case raster(Data)
        case empty
    }

    let client: APIClient
    nonisolated let cache: DiskCache
    private var memory: LRU<TileRequest, Tile>
    private var inFlight: [TileRequest: Task<Tile, Error>] = [:]

    public init(client: APIClient, cache: DiskCache, memoryTiles: Int = 600) {
        self.client = client
        self.cache = cache
        self.memory = LRU(capacity: memoryTiles)
    }

    /// The tile if it is already in memory.
    public func peek(_ r: TileRequest) -> Tile? { memory.peek(r) }

    public func tile(_ r: TileRequest) async throws -> Tile {
        if let t = memory.get(r) { return t }
        if let task = inFlight[r] { return try await task.value }
        let task = Task<Tile, Error> { [client, cache] in
            if let entry = await cache.entry(for: r.cacheKey) {
                if let t = try? Self.decode(entry.data, kind: r.kind) { return t }
                await cache.remove(r.cacheKey)
            }
            let data = try await client.bytes(path: r.path, query: r.query, world: r.world) ?? Data()
            let t = try Self.decode(data, kind: r.kind)
            await cache.store(data, for: r.cacheKey, mark: Int64(r.version))
            return t
        }
        inFlight[r] = task
        defer { inFlight[r] = nil }
        let t = try await task.value
        memory.set(r, t)
        return t
    }

    static func decode(_ data: Data, kind: TileRequest.Kind) throws -> Tile {
        guard !data.isEmpty else { return .empty }
        switch kind {
        case .vector: return .vector(try VectorTile(data: data))
        case .raster: return .raster(data)
        }
    }

    /// Settings' Clear cache.
    public func clear() async {
        memory.removeAll()
        await cache.clear()
    }

    public var memoryCount: Int { memory.count }
}
