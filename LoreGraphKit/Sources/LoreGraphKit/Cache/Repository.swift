import Foundation

/// The server's current freshness marks, asked at most once per `ttl` per world: the newest
/// revision the reader can see (lore) and the map version (map).
public actor FreshnessTracker {
    public typealias Fetch = @Sendable (_ world: String?) async throws -> Int64

    let ttl: TimeInterval
    let now: @Sendable () -> Date
    let fetchLore: Fetch
    let fetchMap: Fetch
    private var memo: [String: (mark: Int64, at: Date)] = [:]
    private var inFlight: [String: Task<Int64, Error>] = [:]

    public init(ttl: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init, lore: @escaping Fetch,
                map: @escaping Fetch) {
        self.ttl = ttl
        self.now = now
        self.fetchLore = lore
        self.fetchMap = map
    }

    public func mark(_ kind: Freshness, world: String?) async throws -> Int64? {
        let fetch: Fetch
        switch kind {
        case .lore: fetch = fetchLore
        case .map: fetch = fetchMap
        case .live: return nil
        }
        let key = "\(kind.rawValue)|\(world ?? "")"
        if let m = memo[key], now().timeIntervalSince(m.at) < ttl { return m.mark }
        if let task = inFlight[key] { return try await task.value }
        let task = Task { try await fetch(world) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let mark = try await task.value
        memo[key] = (mark, now())
        return mark
    }

    /// Forget the marks (pull to refresh, Clear cache, switching reader).
    public func reset() {
        memo = [:]
    }
}

/// An answer for the screen, with where it came from.
public struct Cached<Value: Sendable>: Sendable {
    public var value: Value
    public var storedAt: Date
    public var mark: Int64?
    /// Read from the device rather than fetched just now.
    public var fromCache: Bool
}

/// Reads through the cache (Brendon's rule): show the cached answer at once, then ask the
/// server for its freshness mark and fetch again only when the cache is behind it. Pull to
/// refresh fetches regardless.
public struct Repository: Sendable {
    public let client: APIClient
    public let cache: DiskCache
    public let freshness: FreshnessTracker
    /// Even a current-looking entry is fetched again after this long (a change that hid a
    /// revision from the reader does not move the mark).
    public let maxAge: TimeInterval
    let now: @Sendable () -> Date

    public init(client: APIClient, cache: DiskCache, freshness: FreshnessTracker, maxAge: TimeInterval = 24 * 3600,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.cache = cache
        self.freshness = freshness
        self.maxAge = maxAge
        self.now = now
    }

    /// The cached answer, if there is one that still decodes.
    public func cached<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState) async -> Cached<T>? {
        guard endpoint.freshness != .live else { return nil }
        let key = endpoint.cacheKey(world: world, view: view)
        guard let entry = await cache.entry(for: key) else { return nil }
        guard let value = try? JSONCoding.decoder.decode(T.self, from: entry.data) else {
            await cache.remove(key)
            return nil
        }
        return Cached(value: value, storedAt: entry.storedAt, mark: entry.mark, fromCache: true)
    }

    /// Checks a cached answer against the server: nil when it is still current, else the new one.
    public func revalidate<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState, cached: Cached<T>?) async throws -> Cached<T>? {
        guard let cached, endpoint.freshness != .live else {
            return try await fetch(endpoint, world: world, view: view)
        }
        let current = try await freshness.mark(endpoint.freshness, world: world)
        let young = now().timeIntervalSince(cached.storedAt) < maxAge
        if young, let current, cached.mark == current { return nil }
        let (fresh, unchanged) = try await fetchAndStore(endpoint, world: world, view: view, mark: current)
        if unchanged { return nil }   // same bytes: the screen need not change
        return Cached(value: fresh.value, storedAt: now(), mark: current, fromCache: false)
    }

    /// Fetches regardless of the cache (pull to refresh, first load).
    public func fetch<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState) async throws -> Cached<T> {
        let mark = endpoint.freshness == .live ? nil : (try? await freshness.mark(endpoint.freshness, world: world)) ?? nil
        let (fresh, _) = try await fetchAndStore(endpoint, world: world, view: view, mark: mark)
        return Cached(value: fresh.value, storedAt: now(), mark: mark, fromCache: false)
    }

    /// The fetched answer, and whether its bytes equal the cached ones.
    private func fetchAndStore<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState,
                                  mark: Int64?) async throws -> (Fetched<T>, unchanged: Bool) {
        let key = endpoint.cacheKey(world: world, view: view)
        let previous = endpoint.freshness == .live ? nil : await cache.entry(for: key)
        let fresh = try await client.get(endpoint, world: world, view: view)
        guard endpoint.freshness != .live else { return (fresh, false) }
        if let previous, previous.data == fresh.data {
            await cache.restamp(key, mark: mark)
            return (fresh, true)
        }
        await cache.store(fresh.data, for: key, mark: mark)
        return (fresh, false)
    }
}
