import Foundation
import Observation

/// One screen's data: shown from the cache at once, checked against the server, replaced only
/// when the server has something newer, and fetched again on pull to refresh.
@Observable
@MainActor
public final class Loader<Value: Sendable> {
    public private(set) var value: Value?
    /// The last failure. With a value present it is shown as a banner over the cached page.
    public private(set) var error: APIError?
    public private(set) var isLoading = false
    /// When the shown value was fetched from the server.
    public private(set) var updatedAt: Date?
    /// The shown value comes from the device and could not be checked (offline or failing).
    public private(set) var isStale = false

    public typealias CachedRead = @Sendable () async -> Cached<Value>?
    public typealias Revalidate = @Sendable (Cached<Value>?) async throws -> Cached<Value>?
    public typealias Fetch = @Sendable () async throws -> Cached<Value>

    private let readCache: CachedRead
    private let revalidate: Revalidate
    private let fetch: Fetch
    private var cached: Cached<Value>?
    private var generation = 0

    public init(cached: @escaping CachedRead, revalidate: @escaping Revalidate, fetch: @escaping Fetch) {
        self.readCache = cached
        self.revalidate = revalidate
        self.fetch = fetch
    }

    /// A loader with a fixed value (previews, tests, screens built from data already in hand).
    public convenience init(value: Value) {
        let c = Cached(value: value, storedAt: Date(), mark: nil, fromCache: false)
        self.init(cached: { c }, revalidate: { _ in nil }, fetch: { c })
        self.value = value
    }

    public var hasValue: Bool { value != nil }

    /// The optimistic load: the cached value first, then the server only if the cache is behind.
    public func load() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        if value == nil, let c = await readCache() {
            guard mine == generation else { return }
            apply(c)
            isStale = true
        }
        do {
            let fresh = try await revalidate(cached)
            guard mine == generation else { return }
            if let fresh { apply(fresh) }
            isStale = false
            error = nil
        } catch let e as APIError {
            guard mine == generation else { return }
            error = e
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            self.error = .offline(error.localizedDescription)
        }
    }

    /// Pull to refresh: fetch regardless of the cache.
    public func refresh() async {
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let fresh = try await fetch()
            guard mine == generation else { return }
            apply(fresh)
            isStale = false
            error = nil
        } catch let e as APIError {
            guard mine == generation else { return }
            error = e
            if value != nil { isStale = true }
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            self.error = .offline(error.localizedDescription)
        }
    }

    private func apply(_ c: Cached<Value>) {
        cached = c
        value = c.value
        updatedAt = c.storedAt
    }
}

extension Repository {
    /// A loader for one endpoint in a world, through a view.
    @MainActor
    public func loader<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState) -> Loader<T> {
        let repo = self
        return Loader(
            cached: { await repo.cached(endpoint, world: world, view: view) },
            revalidate: { try await repo.revalidate(endpoint, world: world, view: view, cached: $0) },
            fetch: {
                await repo.freshness.reset()
                return try await repo.fetch(endpoint, world: world, view: view)
            })
    }
}
