import Foundation
import Testing
@testable import LoreGraphKit

@Suite struct DiskCacheTests {
    @Test func storesAndReads() async {
        let clock = TestClock()
        let cache = DiskCache(directory: temporaryFolder().appendingPathComponent("c"), limitBytes: 1000, now: clock.function)
        #expect(await cache.entry(for: "a") == nil)
        await cache.store(Data("hello".utf8), for: "a", mark: 7)
        let e = await cache.entry(for: "a")
        #expect(e?.data == Data("hello".utf8))
        #expect(e?.mark == 7)
        #expect(e?.storedAt == clock.now)
        #expect(await cache.count == 1)
        #expect(await cache.totalBytes == 5)
    }

    @Test func restampsWithoutRewriting() async {
        let clock = TestClock()
        let dir = temporaryFolder()
        let cache = DiskCache(directory: dir, limitBytes: 1000, now: clock.function)
        await cache.store(Data("x".utf8), for: "a", mark: 1)
        clock.advance(60)
        await cache.restamp("a", mark: 2)
        await cache.restamp("missing", mark: 2)
        // a second cache on the same folder reads the index from disk
        let again = DiskCache(directory: dir, limitBytes: 1000, now: clock.function)
        let e = await again.entry(for: "a")
        #expect(e?.mark == 2)
        #expect(e?.storedAt == clock.now)
    }

    @Test func dropsTheLeastRecentlyUsedPastTheLimit() async {
        let clock = TestClock()
        let cache = DiskCache(directory: temporaryFolder(), limitBytes: 100, now: clock.function)
        await cache.store(Data(repeating: 1, count: 40), for: "a", mark: nil)
        clock.advance(1)
        await cache.store(Data(repeating: 1, count: 40), for: "b", mark: nil)
        clock.advance(1)
        _ = await cache.entry(for: "a")   // a used after b
        clock.advance(1)
        await cache.store(Data(repeating: 1, count: 40), for: "c", mark: nil)
        #expect(await cache.entry(for: "b") == nil)
        #expect(await cache.entry(for: "a") != nil)
        #expect(await cache.entry(for: "c") != nil)
        #expect(await cache.totalBytes <= 100)
    }

    @Test func removesAndClears() async {
        let dir = temporaryFolder()
        let cache = DiskCache(directory: dir, limitBytes: 1000)
        await cache.store(Data("1".utf8), for: "a", mark: nil)
        await cache.store(Data("2".utf8), for: "b", mark: nil)
        await cache.remove("a")
        #expect(await cache.entry(for: "a") == nil)
        await cache.clear()
        #expect(await cache.count == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func survivesDamagedFiles() async throws {
        let dir = temporaryFolder()
        let cache = DiskCache(directory: dir, limitBytes: 1000)
        await cache.store(Data("1".utf8), for: "a", mark: nil)
        await cache.store(Data("2".utf8), for: "b", mark: nil)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        // a body gone missing, and a meta file that isn't JSON
        let body = try #require(files.first { $0.pathExtension == "body" })
        try FileManager.default.removeItem(at: body)
        try Data("junk".utf8).write(to: dir.appendingPathComponent("zz.meta"))
        let again = DiskCache(directory: dir, limitBytes: 1000)
        #expect(await again.count == 2)
        let entries = [await again.entry(for: "a"), await again.entry(for: "b")]
        #expect(entries.compactMap { $0 }.count == 1)
        #expect(await again.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("zz.meta").path))
    }

    @Test func aCacheThatCannotWriteIsOnlySlower() async throws {
        let file = temporaryFolder().appendingPathComponent("file")
        try Data().write(to: file)
        let cache = DiskCache(directory: file, limitBytes: 1000)
        await cache.store(Data("1".utf8), for: "a", mark: nil)
        #expect(await cache.entry(for: "a") == nil)
    }
}

@Suite struct FreshnessTests {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0
        var value: Int64 = 1
        func next() -> Int64 { lock.withLock { calls += 1; return value } }
    }

    @Test func asksOncePerTTL() async throws {
        let clock = TestClock()
        let lore = Counter(), map = Counter()
        map.value = 67
        let t = FreshnessTracker(ttl: 30, now: clock.function, lore: { _ in lore.next() }, map: { _ in map.next() })
        #expect(try await t.mark(.lore, world: "a") == 1)
        #expect(try await t.mark(.lore, world: "a") == 1)
        #expect(try await t.mark(.lore, world: "b") == 1)
        #expect(lore.calls == 2)
        #expect(try await t.mark(.map, world: "a") == 67)
        #expect(try await t.mark(.live, world: "a") == nil)
        clock.advance(31)
        lore.value = 2
        #expect(try await t.mark(.lore, world: "a") == 2)
        await t.reset()
        _ = try await t.mark(.lore, world: "a")
        #expect(lore.calls == 4)
    }

    @Test func sharesOneRequest() async throws {
        let counter = Counter()
        let t = FreshnessTracker(lore: { _ in
            try await Task.sleep(for: .milliseconds(50))
            return counter.next()
        }, map: { _ in 0 })
        async let a = t.mark(.lore, world: nil)
        async let b = t.mark(.lore, world: nil)
        _ = try await (a, b)
        #expect(counter.calls == 1)
    }
}

@Suite struct RepositoryTests {
    @Test func fetchesStoresAndRevalidates() async throws {
        let stack = Stack()
        let repo = stack.repository
        #expect(await repo.cached(API.about(), world: "main", view: .default) == nil)
        let first = try await repo.revalidate(API.about(), world: "main", view: .default, cached: nil)
        #expect(first?.fromCache == false)
        #expect(first?.mark == 236)
        let cached = try #require(await repo.cached(API.about(), world: "main", view: .default))
        #expect(cached.fromCache)
        #expect(cached.mark == 236)
        // current: nothing to do, and the server is not asked again
        let before = stack.server.count("/about")
        #expect(try await repo.revalidate(API.about(), world: "main", view: .default, cached: cached) == nil)
        #expect(stack.server.count("/about") == before)
    }

    @Test func refetchesWhenTheServerMovedOn() async throws {
        let stack = Stack(ttl: 0)
        let repo = stack.repository
        _ = try await repo.fetch(API.about(), world: "main", view: .default)
        var head = try Fixture.decode(HistoryHead.self, "history-latest")
        head.groups[0].revisions[0].id = 300
        stack.server.json("/history", value: head)
        // same bytes from the server: the screen keeps what it has
        let cached = try #require(await repo.cached(API.about(), world: "main", view: .default))
        #expect(try await repo.revalidate(API.about(), world: "main", view: .default, cached: cached) == nil)
        #expect(await repo.cached(API.about(), world: "main", view: .default)?.mark == 300)
        // new bytes: the new answer
        var about = try Fixture.decode(About.self, "about")
        about.version = "2.0.0"
        stack.server.json("/about", value: about)
        head.groups[0].revisions[0].id = 301
        stack.server.json("/history", value: head)
        let fresh = try await repo.revalidate(API.about(), world: "main", view: .default, cached: cached)
        #expect(fresh?.value.version == "2.0.0")
        #expect(fresh?.mark == 301)
    }

    @Test func oldEntriesAreFetchedAgain() async throws {
        let stack = Stack()
        _ = try await stack.repository.fetch(API.views(), world: "main", view: .default)
        let cached = try #require(await stack.repository.cached(API.views(), world: "main", view: .default))
        stack.clock.advance(25 * 3600)
        let before = stack.server.count("/views")
        _ = try await stack.repository.revalidate(API.views(), world: "main", view: .default, cached: cached)
        #expect(stack.server.count("/views") == before + 1)
    }

    @Test func liveReadsAreNeverCached() async throws {
        let stack = Stack()
        let me = try await stack.repository.revalidate(API.me(), world: nil, view: .default, cached: nil)
        #expect(me?.mark == nil)
        #expect(await stack.repository.cached(API.me(), world: nil, view: .default) == nil)
        let fetched = try await stack.repository.fetch(API.convertDate("spring 1020"), world: "main", view: .default)
        #expect(fetched.value.parsed.from != nil)
    }

    @Test func dropsEntriesThatNoLongerDecode() async throws {
        let stack = Stack()
        let key = API.about().cacheKey(world: "main", view: .default)
        await stack.repository.cache.store(Data("[1]".utf8), for: key, mark: 1)
        #expect(await stack.repository.cached(API.about(), world: "main", view: .default) == nil)
        #expect(await stack.repository.cache.entry(for: key) == nil)
    }

    @Test func mapAnswersFollowTheMapVersion() async throws {
        let stack = Stack()
        let layers = try await stack.repository.fetch(API.mapLayers(), world: "main", view: .default)
        #expect(layers.mark == 67)
    }

    @Test func aFailingMarkStillFetches() async throws {
        let stack = Stack()
        stack.server.status("/history", 500)
        let about = try await stack.repository.fetch(API.about(), world: "main", view: .default)
        #expect(about.mark == nil)
    }
}

final class LoaderScript: @unchecked Sendable {
    let lock = NSLock()
    var cached: Cached<String>?
    var revalidate: Result<Cached<String>?, Error> = .success(nil)
    var fetch: Result<Cached<String>, Error> = .failure(APIError.offline(""))
    var delay: Duration?
}

@MainActor
@Suite struct LoaderTests {
    typealias Script = LoaderScript

    func loader(_ s: Script) -> Loader<String> {
        Loader(cached: { s.lock.withLock { s.cached } },
               revalidate: { _ in
                   if let d = s.lock.withLock({ s.delay }) { try await Task.sleep(for: d) }
                   return try s.lock.withLock { s.revalidate }.get()
               },
               fetch: { try s.lock.withLock { s.fetch }.get() })
    }

    func value(_ v: String) -> Cached<String> { Cached(value: v, storedAt: Date(timeIntervalSince1970: 5), mark: 1, fromCache: false) }

    @Test func showsTheCacheThenTheServer() async {
        let s = Script()
        s.cached = value("old")
        s.revalidate = .success(value("new"))
        let l = loader(s)
        #expect(!l.hasValue)
        await l.load()
        #expect(l.value == "new")
        #expect(!l.isStale)
        #expect(l.error == nil)
        #expect(!l.isLoading)
        #expect(l.updatedAt == Date(timeIntervalSince1970: 5))
    }

    @Test func keepsTheCacheWhenCurrent() async {
        let s = Script()
        s.cached = value("old")
        let l = loader(s)
        await l.load()
        #expect(l.value == "old")
        #expect(!l.isStale)
    }

    @Test func marksTheCacheStaleWhenOffline() async {
        let s = Script()
        s.cached = value("old")
        s.revalidate = .failure(APIError.offline(""))
        let l = loader(s)
        await l.load()
        #expect(l.value == "old")
        #expect(l.isStale)
        #expect(l.error == .offline(""))
        s.revalidate = .failure(URLErrorLike())
        await l.load()
        #expect(l.error?.isOffline == true)
    }

    @Test func pullToRefreshFetches() async {
        let s = Script()
        s.fetch = .success(value("fetched"))
        let l = loader(s)
        await l.refresh()
        #expect(l.value == "fetched")
        s.fetch = .failure(APIError.signedOut)
        await l.refresh()
        #expect(l.value == "fetched")
        #expect(l.isStale)
        #expect(l.error == .signedOut)
        s.fetch = .failure(URLErrorLike())
        await l.refresh()
        #expect(l.error?.isOffline == true)
        s.fetch = .failure(CancellationError())
        await l.refresh()
        #expect(l.error?.isOffline == true)
        s.revalidate = .failure(CancellationError())
        await l.load()
        #expect(l.value == "fetched")
    }

    @Test func aRefreshFailureWithoutAValueIsNotStale() async {
        let s = Script()
        s.fetch = .failure(APIError.signedOut)
        let l = loader(s)
        await l.refresh()
        #expect(!l.isStale)
        #expect(l.value == nil)
    }

    @Test func aLaterLoadWins() async {
        let s = Script()
        s.delay = .milliseconds(80)
        s.revalidate = .success(value("slow"))
        let l = loader(s)
        let slow = Task { await l.load() }
        try? await Task.sleep(for: .milliseconds(10))
        s.lock.withLock {
            s.delay = nil
            s.revalidate = .success(value("fast"))
        }
        await l.load()
        await slow.value
        #expect(l.value == "fast")
        // an older failing load doesn't overwrite a newer answer either
        s.lock.withLock {
            s.delay = .milliseconds(60)
            s.revalidate = .failure(APIError.signedOut)
        }
        let failing = Task { await l.load() }
        try? await Task.sleep(for: .milliseconds(10))
        s.lock.withLock {
            s.delay = nil
            s.fetch = .success(value("refreshed"))
        }
        await l.refresh()
        await failing.value
        #expect(l.value == "refreshed")
        #expect(l.error == nil)
        // an older load with a cache read races a refresh
        s.lock.withLock {
            s.cached = value("cache")
            s.delay = .milliseconds(60)
            s.revalidate = .failure(URLErrorLike())
        }
        let l2 = loader(s)
        let racing = Task { await l2.load() }
        try? await Task.sleep(for: .milliseconds(10))
        await l2.refresh()
        await racing.value
        #expect(l2.value == "refreshed")
        #expect(l2.error == nil)
    }

    @Test func aStaleCacheReadIsDropped() async {
        let gate = Gate()
        let l = Loader<String>(cached: {
            await gate.wait()
            return Cached(value: "late cache", storedAt: Date(), mark: nil, fromCache: true)
        }, revalidate: { _ in nil }, fetch: { Cached(value: "fresh", storedAt: Date(), mark: nil, fromCache: false) })
        let first = Task { await l.load() }
        try? await Task.sleep(for: .milliseconds(10))
        await l.refresh()
        await gate.open()
        await first.value
        #expect(l.value == "fresh")
    }

    @Test func aFixedValue() async {
        let l = Loader(value: "fixed")
        #expect(l.value == "fixed")
        await l.load()
        await l.refresh()
        #expect(l.value == "fixed")
    }

    @Test func repositoryLoadersReadThroughTheCache() async throws {
        let stack = Stack()
        let l = stack.repository.loader(API.about(), world: "main", view: .default)
        await l.load()
        #expect(l.value?.world?.key == "main")
        await l.refresh()
        #expect(l.value != nil)
        let again = stack.repository.loader(API.about(), world: "main", view: .default)
        await again.load()
        #expect(again.value?.present?.label == "spring YV 1131")
    }
}

struct URLErrorLike: Error {}

actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
