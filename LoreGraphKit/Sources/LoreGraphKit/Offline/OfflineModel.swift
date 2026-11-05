import Foundation
import Observation

/// Reading without a connection: the pages the reader downloaded (text, comments and images,
/// kept current whenever the server is reachable) and the comment changes waiting to be sent.
/// The app only reads lore, so a downloaded page is never edited here: when the world has moved
/// on it is simply fetched again. Comments written offline go out, in order, once it is back.
@Observable
@MainActor
public final class OfflineModel {
    public private(set) var downloads: [Download] = []
    /// Downloads being saved or refreshed (by `Download.identity`, or `ref|world|view` before the
    /// page's id is known).
    public private(set) var working: Set<String> = []
    public private(set) var pending: [QueuedChange] = []
    public private(set) var isSyncing = false
    /// When everything was last checked with the server.
    public private(set) var lastSync: Date?
    /// The last sync stopped because the server could not be reached.
    public private(set) var lastSyncOffline = false
    public private(set) var downloadBytes = 0
    /// A download that failed, with the reason.
    public var downloadError: APIError?
    /// The worlds kept downloaded whole, with the view they are read through ("" for no world key).
    public private(set) var wholeWorlds: [String: ViewState] = [:]
    /// A whole world being downloaded.
    public private(set) var bulk: BulkProgress?

    public struct BulkProgress: Hashable, Sendable {
        public var world: String?
        /// Pages looked at so far (already downloaded, saved or failed) of `total` (0 while the
        /// list of pages is read).
        public var done = 0
        public var total = 0
        public var failed = 0
    }

    @ObservationIgnored public let repository: Repository
    @ObservationIgnored public let store: DownloadStore
    @ObservationIgnored public let outbox: Outbox
    @ObservationIgnored let now: @Sendable () -> Date
    /// A downloaded page is checked again after this long even when the world has not moved (a
    /// change that hid a revision from the reader does not move the mark).
    @ObservationIgnored let maxAge: TimeInterval
    /// How often a current page's comments are fetched again.
    @ObservationIgnored let commentsAge: TimeInterval
    /// The least time between two syncs nothing asked for.
    @ObservationIgnored let syncInterval: TimeInterval
    @ObservationIgnored private var watchers: [WeakComments] = []
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var bulkCancelled = false

    private struct WeakComments {
        weak var model: CommentsModel?
    }

    public init(repository: Repository, store: DownloadStore, outbox: Outbox, maxAge: TimeInterval = 24 * 3600,
                commentsAge: TimeInterval = 600, syncInterval: TimeInterval = 120, now: @escaping @Sendable () -> Date = Date.init) {
        self.repository = repository
        self.store = store
        self.outbox = outbox
        self.maxAge = maxAge
        self.commentsAge = commentsAge
        self.syncInterval = syncInterval
        self.now = now
    }

    /// Reads what is on the phone.
    public func prepare() async {
        guard !prepared else { return }
        prepared = true
        await reload()
    }

    // MARK: downloads

    /// The download of a page in a world and view, if it has one.
    public func download(ref: String, entityId: String?, world: String?, view: ViewState) -> Download? {
        downloads.first { d in
            d.world == world && d.view == view && (d.entityId == entityId || d.refs.contains(ref))
        }
    }

    public func isWorking(ref: String, entityId: String?, world: String?, view: ViewState) -> Bool {
        if working.contains(Self.pendingKey(ref: ref, world: world, view: view)) { return true }
        guard let d = download(ref: ref, entityId: entityId, world: world, view: view) else { return false }
        return working.contains(d.id)
    }

    /// Downloads a page as the reader sees it now, with its comments and images.
    @discardableResult
    public func download(ref: String, world: String?, view: ViewState) async -> Download? {
        let key = Self.pendingKey(ref: ref, world: world, view: view)
        guard !working.contains(key) else { return nil }
        working.insert(key)
        defer { working.remove(key) }
        do {
            let d = try await save(refs: [ref], world: world, view: view,
                                   existing: download(ref: ref, entityId: nil, world: world, view: view))
            downloadError = nil
            await reload()
            return d
        } catch {
            downloadError = (error as? APIError) ?? .offline("")
            return nil
        }
    }

    public func remove(_ d: Download) async {
        await store.remove(d.id)
        await reload()
    }

    public func removeAll() async {
        bulkCancelled = true
        await store.removeAll()
        await reload()
    }

    // MARK: a whole world

    public func keepsWholeWorld(_ world: String?) -> Bool { wholeWorlds[world ?? ""] != nil }

    /// Keeps every page of a world downloaded (through a view), new pages included, or stops.
    /// Turning it off keeps the pages already downloaded.
    public func keepWholeWorld(_ world: String?, view: ViewState, on: Bool) async {
        await store.setWhole(world: world, view: on ? view : nil)
        await reload()
        if on {
            await downloadAll(world: world, view: view)
        } else if bulk?.world == world {
            bulkCancelled = true
        }
    }

    /// Stops a whole-world download for now; the next sync goes on with it.
    public func stopBulk() { bulkCancelled = true }

    /// Downloads every page of a world not downloaded yet. Pages the server refuses are counted
    /// and left out; it stops when the server is out of reach (returns false) or it is stopped.
    @discardableResult
    public func downloadAll(world: String?, view: ViewState) async -> Bool {
        guard bulk == nil else { return true }
        bulkCancelled = false
        var progress = BulkProgress(world: world)
        bulk = progress
        defer { bulk = nil }
        var items: [EntityListItem] = []
        var cursor: String?
        repeat {
            do {
                let page = try await repository.client.get(API.entities(cursor: cursor, limit: 200), world: world, view: view).value
                items += page.items
                cursor = page.nextCursor
            } catch {
                return !Self.unreachable(error)
            }
            if bulkCancelled { return true }
        } while cursor != nil
        progress.total = items.count
        bulk = progress
        var reached = true
        for item in items {
            if bulkCancelled { break }
            if download(ref: item.ref, entityId: item.id, world: world, view: view) == nil {
                let key = Self.pendingKey(ref: item.ref, world: world, view: view)
                working.insert(key)
                do {
                    _ = try await save(refs: [item.ref], world: world, view: view, existing: nil)
                } catch {
                    if Self.unreachable(error) { reached = false } else { progress.failed += 1 }
                }
                working.remove(key)
                if !reached { break }
            }
            progress.done += 1
            bulk = progress
            if progress.done % 10 == 0 { await reload() }
        }
        await reload()
        return reached
    }


    /// Checks every downloaded page with the server and fetches again the ones the world has moved
    /// past (`force`: every page). Stops at the first sign the server is out of reach.
    /// Returns false when it could not reach the server.
    @discardableResult
    public func refreshDownloads(force: Bool = false) async -> Bool {
        var marks: [String: Int64?] = [:]
        for d in downloads {
            let world = d.world ?? ""
            if marks[world] == nil {
                do {
                    marks[world] = .some(try await repository.freshness.mark(.lore, world: d.world))
                } catch {
                    if Self.unreachable(error) { return false }
                    marks[world] = .some(nil)
                }
            }
            let current = marks[world] ?? nil
            let age = now().timeIntervalSince(d.checkedAt)
            let stale = force || d.problem != nil || d.gone || current == nil || d.mark != current || age >= maxAge
            guard stale || age >= commentsAge else { continue }
            working.insert(d.id)
            defer { working.remove(d.id) }
            do {
                if stale {
                    _ = try await save(refs: d.refs, world: d.world, view: d.view, existing: d)
                } else {
                    try await saveComments(d)
                }
            } catch {
                if Self.unreachable(error) {
                    await reload()
                    return false
                }
                var failed = d
                failed.checkedAt = now()
                if case APIError.notFound = error {
                    failed.gone = true
                    failed.problem = nil
                } else {
                    failed.problem = ((error as? APIError) ?? .offline("")).message
                }
                if await store.download(d.id) != nil { await store.save(failed) }
            }
        }
        await reload()
        return true
    }

    /// Fetches the page under its first reference and keeps it (and its comments) under every
    /// reference, then its images; images it no longer shows are deleted.
    private func save(refs: [String], world: String?, view: ViewState, existing: Download?) async throws -> Download {
        let mark: Int64?
        do {
            mark = try await repository.freshness.mark(.lore, world: world)
        } catch {
            if Self.unreachable(error) { throw error }
            mark = nil      // checked again at the next sync
        }
        let fetched = try await repository.client.get(API.entity(refs[0]), world: world, view: view)
        let page = fetched.value
        var all = refs
        for r in [page.entity.slug, page.entity.ref].compactMap({ $0 }) where !all.contains(r) { all.append(r) }
        var bytes = 0
        var keys: [String] = []
        for r in all {
            let key = API.entity(r).cacheKey(world: world, view: view)
            await keep(fetched.data, key: key, mark: mark)
            keys.append(key)
            bytes += fetched.data.count
        }
        let comments = try await fetchComments(refs: all, world: world, view: view)
        keys += comments.keys
        bytes += comments.bytes
        var media: [String] = []
        for url in Self.imageAddresses(page, server: repository.client.server) {
            let key = Repository.mediaKey(url)
            if let have = await store.file(key) {
                media.append(key)
                bytes += have.data.count
                continue
            }
            let data: Data
            if let cached = await repository.cache.entry(for: key) {
                data = cached.data
            } else {
                do {
                    data = try await repository.client.bytes(at: url)
                } catch {
                    if Self.unreachable(error) { throw error }
                    continue   // an image the server won't give stays out; the page still reads
                }
                await repository.cache.store(data, for: key, mark: nil)
            }
            await store.store(data, for: key, mark: nil)
            media.append(key)
            bytes += data.count
        }
        let at = now()
        let d = Download(entityId: page.entity.id, ref: refs[0], world: world, view: view,
                         title: page.entity.displayTitle ?? page.entity.title, type: page.entity.type,
                         shortDescription: page.entity.shortDescription, savedAt: existing?.savedAt ?? at, checkedAt: at,
                         mark: mark, refs: all, keys: keys, media: media, bytes: bytes, problem: nil, gone: false)
        // a page removed while it was being refreshed stays removed
        let wanted = existing == nil ? true : await store.download(existing!.id) != nil
        if let existing, existing.id != d.id { await store.remove(existing.id) }
        await store.save(d)
        if !wanted { await store.remove(d.id) }
        return d
    }

    /// The page's comments, kept under each of its references. A server without comments (or one
    /// that refuses them) leaves the page without; only being out of reach is an error.
    private func fetchComments(refs: [String], world: String?, view: ViewState) async throws -> (keys: [String], bytes: Int) {
        let endpoint = API.comments(on: refs[0], viewAs: view.viewAs)
        let fetched: Fetched<CommentList>
        do {
            fetched = try await repository.client.get(endpoint, world: world, view: view)
        } catch {
            if Self.unreachable(error) { throw error }
            return ([], 0)
        }
        var keys: [String] = []
        for r in refs {
            let key = API.comments(on: r, viewAs: view.viewAs).cacheKey(world: world, view: view)
            await keep(fetched.data, key: key, mark: nil)
            keys.append(key)
        }
        return (keys, fetched.data.count * refs.count)
    }

    private func saveComments(_ d: Download) async throws {
        let comments = try await fetchComments(refs: d.refs, world: d.world, view: d.view)
        var next = d
        let entityKeys = d.keys.filter { !$0.hasPrefix("/api/v1/comments") }
        next.keys = entityKeys + comments.keys
        next.checkedAt = now()
        if await store.download(d.id) != nil { await store.save(next) }
    }

    private func keep(_ data: Data, key: String, mark: Int64?) async {
        await store.store(data, for: key, mark: mark)
        await repository.cache.store(data, for: key, mark: mark)
    }

    /// The images a page shows: its media that are pictures.
    public static func imageAddresses(_ page: EntityDetail, server: URL) -> [URL] {
        var seen = Set<URL>()
        return (page.media ?? []).filter(\.isImage).compactMap { $0.address(base: server) }.filter { seen.insert($0).inserted }
    }

    static func pendingKey(ref: String, world: String?, view: ViewState) -> String {
        "pending|" + Download.identity(world: world, entityId: ref, view: view)
    }

    // MARK: comments waiting to be sent

    /// Keeps a change for later and tries to send it straight away.
    func queue(_ c: QueuedChange) async {
        await outbox.append(c)
        pending = await outbox.all
    }

    /// The changes waiting for a world.
    public func pending(world: String?) -> [QueuedChange] { pending.filter { $0.world == world } }

    /// Whether changes are waiting that a new change must go after (so they reach the server in
    /// the order they were made).
    public var hasUnsent: Bool { pending.contains { $0.problem == nil } }

    /// New text for a change not sent yet (a queued comment or reply).
    public func edit(_ id: String, body: String) async {
        guard var c = pending.first(where: { $0.id == id }) else { return }
        c.body = body
        await outbox.replace(c)
        pending = await outbox.all
    }

    /// Drops a change not sent yet, with every change waiting on it.
    public func discard(_ id: String) async {
        await outbox.discard(id)
        pending = await outbox.all
    }

    /// Sends a refused change again (`wholeSection`: a new comment whose passage is gone goes on
    /// its whole section, the passage quoted at the top of its text).
    public func retry(_ id: String, wholeSection: Bool = false) async {
        guard var c = pending.first(where: { $0.id == id }) else { return }
        if wholeSection, c.kind == .add, let quote = c.quote {
            c.body = "> " + quote + "\n\n" + (c.body ?? "")
            c.quote = nil
            c.prefix = nil
            c.suffix = nil
        }
        c.problem = nil
        c.attempt += 1
        await outbox.replace(c)
        pending = await outbox.all
        await flush()
    }

    /// Sends what is waiting, oldest first. A change on a comment not sent yet goes once that one
    /// has its id; a change the server refuses is kept with the reason. Returns false when the
    /// server could not be reached.
    @discardableResult
    public func flush() async -> Bool {
        var tried = Set<String>()
        var sent = false
        defer {
            if sent { for w in watchers { if let m = w.model { Task { await m.refresh() } } } }
        }
        while let next = await outbox.all.first(where: { !tried.contains($0.id) && $0.problem == nil && !$0.waitsForAnother }) {
            tried.insert(next.id)
            guard let change = next.change else {
                await outbox.remove(next.id)
                continue
            }
            do {
                let r = try await repository.client.send(change, world: next.world)
                await outbox.sent(next.id, as: next.kind == .add ? r.comment?.id : nil)
                sent = true
            } catch {
                if case APIError.notFound = error, next.kind == .delete {
                    await outbox.sent(next.id, as: nil)    // already gone
                    sent = true
                    continue
                }
                if Self.unreachable(error) || Self.isSignedOut(error) {
                    pending = await outbox.all
                    return false
                }
                var refused = next
                refused.problem = ((error as? APIError) ?? .offline("")).message
                await outbox.replace(refused)
            }
        }
        pending = await outbox.all
        return true
    }

    /// Comment models on screen, refreshed after their changes are sent.
    func watch(_ model: CommentsModel) {
        watchers.removeAll { $0.model == nil }
        watchers.append(WeakComments(model: model))
    }

    // MARK: sync

    /// Sends waiting comments, then refreshes stale downloads. Runs at launch, when the app comes
    /// back to the front and when the connection returns; between those, at most every
    /// `syncInterval` unless something is waiting, the last try found no server, or `force`.
    public func sync(force: Bool = false) async {
        guard !isSyncing else { return }
        await prepare()
        if !force, !lastSyncOffline, pending.isEmpty, let last = lastSync, now().timeIntervalSince(last) < syncInterval { return }
        isSyncing = true
        defer { isSyncing = false }
        guard await flush() else {
            lastSyncOffline = true
            return
        }
        var reached = await refreshDownloads(force: false)
        // whole worlds: pages made since the last check
        for (key, view) in wholeWorlds.sorted(by: { $0.key < $1.key }) where reached {
            reached = await downloadAll(world: key.isEmpty ? nil : key, view: view)
        }
        lastSyncOffline = !reached
        if reached { lastSync = now() }
    }

    private func reload() async {
        downloads = await store.all.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        downloadBytes = await store.totalBytes
        pending = await outbox.all
        wholeWorlds = await store.wholeWorlds
    }

    // MARK: errors

    /// The server is out of reach (or failing for now): try again later.
    nonisolated static func unreachable(_ error: Error) -> Bool {
        guard let e = error as? APIError else { return !(error is CancellationError) }
        switch e {
        case .offline: return true
        case .problem(let p): return (p.status ?? 0) >= 500 || p.status == 429
        default: return false
        }
    }

    nonisolated static func isSignedOut(_ error: Error) -> Bool {
        if case APIError.signedOut = error { return true }
        return false
    }
}
