import Foundation
import Testing
@testable import LoreGraphKit

/// A connection that can be cut, in front of the fake server.
final class Connection: HTTPTransport, @unchecked Sendable {
    let server: FakeServer
    private let lock = NSLock()
    private var up = true

    init(_ server: FakeServer) {
        self.server = server
    }

    var online: Bool {
        get { lock.withLock { up } }
        set { lock.withLock { up = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard online else { throw TransportError(message: "offline", isOffline: true) }
        return try await server.send(request)
    }
}

let lamptonImage = URL(string: "https://assets.example.test/canary-designer-vault.png")!
let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

extension FakeServer {
    /// The Testmark server with Lampton's comments and its image (on another host).
    static func offline() -> FakeServer {
        let s = FakeServer.testmark()
        s.json("/comments", "comments-lampton", query: ["ref": "lampton"])
        let previous = s.fallback
        s.fallback = { request in
            if request.url.host == lamptonImage.host, request.url.path == lamptonImage.path {
                return HTTPResponse(status: 200, body: imageBytes)
            }
            return try previous(request)
        }
        return s
    }

    /// The world's newest revision, as the freshness check reads it.
    func newest(_ id: Int64) {
        json("/history", value: HistoryHead(groups: [HistoryHead.Group(revisions: [HistoryHead.Revision(id: id)])]))
    }
}

/// A reader's stack with downloads and a comment queue, over a connection that can be cut.
@MainActor
struct OfflineStack {
    let server: FakeServer
    let net: Connection
    let clock: TestClock
    let folder: URL
    let repository: Repository
    let store: DownloadStore
    let outbox: Outbox
    let offline: OfflineModel
    let tiles: TileStore

    init(server: FakeServer = .offline(), clock: TestClock = TestClock(), folder: URL = temporaryFolder()) {
        self.server = server
        self.clock = clock
        self.folder = folder
        let net = Connection(server)
        self.net = net
        let auth = AuthSession(store: MemoryTokenStore(Credentials(kind: .personal, server: testServer, accessToken: "token-1")),
                               transport: net, now: clock.function)
        let client = APIClient(server: testServer, transport: net, auth: auth)
        let freshness = FreshnessTracker(ttl: 0, now: clock.function,
                                         lore: { world in try await client.get(API.historyHead(), world: world).value.newest?.id ?? 0 },
                                         map: { world in Int64(try await client.get(API.mapVersion(), world: world).value.version) })
        store = DownloadStore(directory: folder.appendingPathComponent("downloads"), now: clock.function)
        outbox = Outbox(file: folder.appendingPathComponent("outbox.json"))
        repository = Repository(client: client, cache: DiskCache(directory: folder.appendingPathComponent("api"), limitBytes: 10_000_000,
                                                                 now: clock.function),
                                freshness: freshness, downloads: store, now: clock.function)
        tiles = TileStore(client: client, cache: DiskCache(directory: folder.appendingPathComponent("tiles"), limitBytes: 1_000_000))
        offline = OfflineModel(repository: repository, store: store, outbox: outbox, now: clock.function)
    }

    func context(view: ViewState = .default) -> ReadContext {
        ReadContext(repository: repository, tiles: tiles, server: testServer, world: "main", view: view, present: 1131.25,
                    ceiling: .designer, offline: offline)
    }

    /// The same phone opened again (the same folders, nothing in memory).
    func relaunched() -> OfflineStack { OfflineStack(server: server, clock: clock, folder: folder) }

    func requests(_ path: String, method: String = "GET") -> [HTTPRequest] {
        server.requests.filter { $0.method == method && $0.url.path == "/api/v1" + path }
    }
}

@MainActor
@Suite struct DownloadTests {
    @Test func downloadsAPageWithItsCommentsAndImageAndReadsItOffline() async throws {
        let s = OfflineStack()
        let page = PageModel(ref: "lampton", context: s.context())
        await page.load()
        #expect(page.canDownload && page.download == nil && !page.isDownloading)
        #expect(await page.toggleDownload() == nil)
        let d = try #require(page.download)
        #expect(d.title == "Lampton" && d.entityId == "00000000-0000-7000-8000-000000000031" && d.world == "main")
        #expect(d.refs == ["lampton"] && d.keys.count == 2 && d.media == [Repository.mediaKey(lamptonImage)])
        #expect(d.mark == 236 && d.bytes > imageBytes.count && !d.gone && d.problem == nil)
        #expect(s.offline.downloads == [d] && s.offline.downloadBytes > 0 && s.offline.downloadError == nil)
        // the image went to its own host without the token
        let image = try #require(s.server.requests.last { $0.url.host == lamptonImage.host })
        #expect(image.headers["Authorization"] == nil)

        // offline, with the cache cleared: the page, its comments and its image still read
        s.net.online = false
        await s.repository.cache.clear()
        let again = PageModel(ref: "lampton", context: s.context())
        await again.load()
        #expect(again.page.value?.entity.title == "Lampton" && again.page.isStale && again.page.error?.isOffline == true)
        #expect(again.comments.all.count == 5 && again.download == d)
        #expect(try await s.repository.media(lamptonImage) == imageBytes)
        await #expect(throws: APIError.self) { try await s.repository.media(URL(string: "https://lore.example.test/media/x.png")!) }

        // the same phone tomorrow: the downloads are still there
        let next = s.relaunched()
        await next.offline.prepare()
        #expect(next.offline.downloads.map(\.id) == [d.id])
        // another view of the page is another download
        #expect(next.offline.download(ref: "lampton", entityId: nil, world: "main", view: ViewState(asOf: 1020)) == nil)
        #expect(next.offline.download(ref: "lampton", entityId: nil, world: "other", view: .default) == nil)
        // a page that can't be fetched says why
        s.net.online = false
        let dirk = PageModel(ref: "dirk", context: s.context())
        #expect(await dirk.toggleDownload()?.isOffline == true)
        #expect(await PageModel(ref: "dirk", context: Stack().context()).toggleDownload() == nil)
        #expect(WebLink(route: .downloads, world: "main", view: .default).url(server: testServer).path == "/")
    }

    @Test func aPageThatCannotBeFetchedIsNotDownloaded() async throws {
        let s = OfflineStack()
        s.net.online = false
        #expect(await s.offline.download(ref: "lampton", world: "main", view: .default) == nil)
        #expect(s.offline.downloadError?.isOffline == true && s.offline.downloads.isEmpty)
        s.net.online = true
        #expect(await s.offline.download(ref: "nowhere", world: "main", view: .default) == nil)
        if case .notFound = s.offline.downloadError {} else { Issue.record("expected not found") }
        // a page whose image and comments the server refuses still downloads, without them
        s.server.status("/comments", 404, body: Fixture.data("not-found"))
        let d = try #require(await s.offline.download(ref: "dirk", world: "main", view: .default))
        #expect(d.keys.count == 1 && d.media.isEmpty && s.offline.downloadError == nil)
    }

    @Test func keepsItUnderEveryNameItIsReadBy() async throws {
        let s = OfflineStack()
        s.server.json("/entities/00000000-0000-7000-8000-000000000031", "entity-lampton")
        s.server.json("/comments", "comments-lampton", query: ["ref": "00000000-0000-7000-8000-000000000031"])
        let d = try #require(await s.offline.download(ref: "00000000-0000-7000-8000-000000000031", world: "main", view: .default))
        #expect(d.refs == ["00000000-0000-7000-8000-000000000031", "lampton"] && d.keys.count == 4)
        s.net.online = false
        await s.repository.cache.clear()
        let bySlug = PageModel(ref: "lampton", context: s.context())
        await bySlug.load()
        #expect(bySlug.page.value != nil && bySlug.download?.id == d.id && bySlug.comments.all.count == 5)
        // downloading it again by its slug keeps the one download
        s.net.online = true
        await s.offline.download(ref: "lampton", world: "main", view: .default)
        #expect(s.offline.downloads.count == 1 && s.offline.downloads[0].savedAt == d.savedAt)
    }

    @Test func refreshesOnlyWhatTheWorldHasMovedPast() async throws {
        let s = OfflineStack()
        let d = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        let pageReads = { s.requests("/entities/lampton").count }
        let commentReads = { s.requests("/comments").count }
        #expect(pageReads() == 1 && commentReads() == 1)

        // nothing changed and the copy is young: nothing is fetched
        #expect(await s.offline.refreshDownloads())
        #expect(pageReads() == 1 && commentReads() == 1)

        // ten minutes on: only the comments are read again
        s.clock.advance(601)
        #expect(await s.offline.refreshDownloads())
        #expect(pageReads() == 1 && commentReads() == 2 && s.offline.downloads[0].checkedAt == s.clock.now)

        // the world moved on: the page is fetched again and its new text kept
        s.server.newest(300)
        s.server.json("/entities/lampton", "entity-lampton-now")
        #expect(await s.offline.refreshDownloads())
        let fresh = s.offline.downloads[0]
        #expect(pageReads() == 2 && fresh.mark == 300 && fresh.media.isEmpty && fresh.savedAt == d.savedAt)
        let shown = await s.repository.cached(API.entity("lampton"), world: "main", view: .default)
        #expect(shown?.value == (try Fixture.decode(EntityDetail.self, "entity-lampton-now")))
        // the image it no longer shows is deleted from the downloads
        #expect(await s.store.file(Repository.mediaKey(lamptonImage)) == nil)

        // a day on, the page is checked even though the world has not moved
        s.clock.advance(24 * 3600)
        #expect(await s.offline.refreshDownloads())
        #expect(pageReads() == 3)
        // forced: every page
        #expect(await s.offline.refreshDownloads(force: true))
        #expect(pageReads() == 4)

        // out of reach: stops, and keeps what it has
        s.net.online = false
        #expect(await s.offline.refreshDownloads(force: true) == false)
        #expect(s.offline.downloads[0].problem == nil)
    }

    @Test func marksPagesTheServerNoLongerShowsOrRefuses() async throws {
        let s = OfflineStack()
        _ = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        s.server.status("/entities/lampton", 404, body: Fixture.data("not-found"))
        #expect(await s.offline.refreshDownloads(force: true))
        #expect(s.offline.downloads[0].gone && s.offline.downloads[0].problem == nil)
        s.server.status("/entities/lampton", 422, body: Fixture.data("problem-422"))
        #expect(await s.offline.refreshDownloads(force: true))
        #expect(s.offline.downloads[0].problem != nil)
        // the copy still reads
        #expect(await s.repository.cached(API.entity("lampton"), world: "main", view: .default) != nil)
        // the server failing for now counts as out of reach
        s.server.status("/entities/lampton", 503)
        #expect(await s.offline.refreshDownloads(force: true) == false)
        // and a history the server refuses still lets the pages be checked
        s.server.json("/entities/lampton", "entity-lampton")
        s.server.status("/history", 403, body: Fixture.data("problem-422"))
        #expect(await s.offline.refreshDownloads())
        #expect(s.offline.downloads[0].problem == nil && !s.offline.downloads[0].gone)
    }

    @Test func removesDownloadsAndTheFilesNoOtherPageUses() async throws {
        let s = OfflineStack()
        // Dirk shares Lampton's image here
        var dirk = try Fixture.decode(EntityDetail.self, "entity-lampton")
        dirk.entity.id = "dirk-id"
        dirk.entity.ref = "dirk"
        dirk.entity.slug = "dirk"
        dirk.entity.title = "Dirk"
        dirk.entity.displayTitle = nil
        s.server.json("/entities/dirk", value: dirk)
        let lampton = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        let d = try #require(await s.offline.download(ref: "dirk", world: "main", view: .default))
        #expect(s.offline.downloads.map(\.title) == ["Dirk", "Lampton"])
        let key = Repository.mediaKey(lamptonImage)
        await s.offline.remove(lampton)
        #expect(await s.store.file(key) != nil && s.offline.downloads == [d])
        #expect(await s.store.file(lampton.keys[0]) == nil)
        await s.offline.remove(d)
        #expect(await s.store.file(key) == nil && s.offline.downloads.isEmpty)
        _ = await s.offline.download(ref: "lampton", world: "main", view: .default)
        await s.offline.removeAll()
        #expect(s.offline.downloads.isEmpty && s.offline.downloadBytes == 0)
        // removing from the page
        let page = PageModel(ref: "lampton", context: s.context())
        await page.load()
        await page.toggleDownload()
        #expect(page.download != nil)
        await page.toggleDownload()
        #expect(page.download == nil && s.offline.downloads.isEmpty)
    }

    @Test func aPageRemovedWhileItRefreshesStaysRemoved() async throws {
        let s = OfflineStack()
        let d = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        // the reader removes it while the page is on its way back
        s.server.on("/entities/lampton") { _ in
            let body = Fixture.data("entity-lampton")
            Task { await s.store.remove(d.id) }
            Thread.sleep(forTimeInterval: 0.05)
            return HTTPResponse(status: 200, body: body)
        }
        #expect(await s.offline.refreshDownloads(force: true))
        #expect(await s.store.all.isEmpty)
    }

    @Test func aFetchOfADownloadedPageKeepsItsDownloadCurrent() async throws {
        let s = OfflineStack()
        _ = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        s.server.newest(400)
        s.server.json("/entities/lampton", "entity-lampton-now")
        let page = PageModel(ref: "lampton", context: s.context())
        await page.load()           // the cache is behind the mark: fetched, and the download too
        await s.repository.cache.clear()
        let key = API.entity("lampton").cacheKey(world: "main", view: .default)
        #expect(await s.store.entry(for: key)?.mark == 400)
        // the same bytes again only move the mark
        s.server.newest(401)
        await page.load()
        #expect(await s.store.entry(for: key)?.mark == 401)
        // a cached copy newer than the download is the one shown
        s.clock.advance(1)
        await s.repository.cache.store(Fixture.data("entity-dirk"), for: key, mark: 402)
        let shown = await s.repository.cached(API.entity("lampton"), world: "main", view: .default)
        #expect(shown?.value.entity.ref == "dirk")
    }

    @Test func storesFilesProtectedAndApartFromTheCache() async throws {
        let folder = temporaryFolder()
        let store = DownloadStore(directory: folder)
        await store.store(Data([1]), for: "k", mark: 3)
        #expect(await store.entry(for: "k") == nil)      // no page names it yet
        #expect(await store.file("k")?.mark == 3)
        await store.restamp("k", mark: 4)
        #expect(await store.file("k")?.mark == 4)
        let d = Download(entityId: "e", ref: "e", world: nil, view: .default, title: "E", type: nil, shortDescription: nil,
                         savedAt: Date(), checkedAt: Date(), mark: 4, refs: ["e"], keys: ["k"], media: [], bytes: 1, problem: nil, gone: false)
        await store.save(d)
        let entry = await store.entry(for: "k")
        let holds = await store.holds("k")
        let total = await store.totalBytes
        #expect(entry?.data == Data([1]) && holds && total == 1)
        #expect(await store.download(d.id) == d && d.card.title == "E")
        // a damaged manifest reads as no downloads
        try Data("nope".utf8).write(to: folder.appendingPathComponent("manifest.json"))
        #expect(await DownloadStore(directory: folder).all.isEmpty)
        await store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

@MainActor
@Suite struct CommentQueueTests {
    let picked = Anchors.Picked(quote: "The lamps of Lampton burn all night.", prefix: "", suffix: " Loïse and her daughters kept th")

    @Test func keepsCommentsWrittenOfflineAndSendsThemInOrder() async throws {
        let s = OfflineStack()
        s.server.change("POST", "/comments", "comment-add", status: 201)
        s.server.change("POST", "/comments/\(lampsComment)/replies", "comment-reply", status: 201)
        s.server.change("POST", "/comments/\(leadComment)/resolve", "comment-resolve")
        let page = PageModel(ref: "lampton", context: s.context())
        await page.load()
        #expect(page.comments.all.count == 5)
        s.net.online = false

        // a new comment on a passage: shown at once, highlighted, marked as waiting
        let added = try #require(await page.comments.add(section: "history", picked: picked, body: " Still true? "))
        #expect(QueuedChange.isLocal(added.id) && added.queued?.summary == "New comment" && added.queued?.onPassage == true)
        #expect(added.author.mine && added.canEdit && added.section.heading == "History" && added.anchor.isPlaced)
        #expect(page.comments.all.count == 6 && page.comments.highlights("history").contains { $0.id == added.id })
        #expect(page.comments.actionError == nil)
        // a reply to it, and an edit before anything is sent
        #expect(await page.comments.reply(to: added.id, body: "And the bridge?"))
        #expect(await page.comments.edit(added.id, body: "Still true after the fire?"))
        #expect(page.comments.comment(added.id)?.bodyMd == "Still true after the fire?")
        #expect(page.comments.comment(added.id)?.replies.first?.queued != nil)
        // resolving one that is on the server
        #expect(await page.comments.setResolved(leadComment, true))
        #expect(page.comments.comment(leadComment)?.status == .resolved && page.comments.comment(leadComment)?.queued?.summary == "Resolve")
        #expect(s.offline.pending.count == 3 && s.offline.hasUnsent)
        #expect(s.offline.pending.allSatisfy { $0.pageTitle == "Lampton" })

        // the phone restarts: they are still waiting
        let next = s.relaunched()
        await next.offline.prepare()
        #expect(next.offline.pending.map(\.kind) == [.add, .reply, .resolve])

        // back online: sent in order, the reply to the new comment by the id the server gave it
        s.net.online = true
        #expect(await s.offline.flush())
        #expect(s.offline.pending.isEmpty)
        let posted = try #require(s.requests("/comments", method: "POST").last)
        #expect(posted.json["body_md"] == "Still true after the fire?" && posted.json["quote"] == .string(picked.quote))
        let key = try #require(posted.headers["Idempotency-Key"])
        #expect(key.hasPrefix("ios-") && key.hasSuffix("-0"))
        #expect(s.requests("/comments/\(lampsComment)/replies", method: "POST").first?.json["body_md"] == "And the bridge?")
        #expect(s.requests("/comments/\(leadComment)/resolve", method: "POST").count == 1)
        // the page's comments are read again
        #expect(await eventually { s.requests("/comments").count >= 2 })
    }

    @Test func aChangeSentWhileOthersWaitGoesAfterThem() async throws {
        let s = OfflineStack()
        s.server.change("POST", "/comments/\(leadComment)/resolve", "comment-resolve")
        s.server.change("POST", "/comments/\(lampsComment)/replies", "comment-reply", status: 201)
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.net.online = false
        #expect(await c.reply(to: lampsComment, body: "First"))
        s.net.online = true
        // online again, but the first one is not sent yet: the second waits behind it
        #expect(await c.setResolved(leadComment, true))
        #expect(await eventually { s.offline.pending.isEmpty })
        let order = s.server.requests.filter { $0.method == "POST" }.map(\.url.path)
        #expect(order == ["/api/v1/comments/\(lampsComment)/replies", "/api/v1/comments/\(leadComment)/resolve"])
    }

    @Test func keepsRefusedChangesForTheReader() async throws {
        let s = OfflineStack()
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.net.online = false
        let added = try #require(await c.add(section: "history", picked: picked, body: "Gone?"))
        #expect(await c.reply(to: added.id, body: "Waits for it"))
        s.net.online = true
        s.server.change("POST", "/comments", "comment-error", status: 422)
        #expect(await s.offline.flush())
        let refused = try #require(s.offline.pending.first)
        #expect(refused.problem == "the quote is not in the text of Lampton, History" && s.offline.pending.count == 2)
        #expect(s.offline.hasUnsent)                    // the reply still waits for it
        #expect(c.comment(added.id)?.queued?.problem != nil)

        // retried on the whole section: the passage goes into the text, with a new key
        s.server.change("POST", "/comments", "comment-add", status: 201)
        s.server.change("POST", "/comments/\(lampsComment)/replies", "comment-reply", status: 201)
        await s.offline.retry(refused.id, wholeSection: true)
        let sent = try #require(s.requests("/comments", method: "POST").last)
        #expect(sent.json["quote"] == nil && sent.json["body_md"] == .string("> \(picked.quote)\n\nGone?"))
        #expect(sent.headers["Idempotency-Key"]?.hasSuffix("-1") == true)
        #expect(s.offline.pending.isEmpty)
        await s.offline.retry("nothing")
    }

    @Test func discardsAndDeletesOffline() async throws {
        let s = OfflineStack()
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.net.online = false
        let added = try #require(await c.add(section: "lead", picked: nil, body: "On the lead"))
        #expect(added.anchor.status == .section && !added.anchor.isPlaced && added.queued?.onPassage == false)
        #expect(await c.reply(to: added.id, body: "Reply"))
        let reply = try #require(c.comment(added.id)?.replies.first)
        #expect(await c.edit(added.id, reply: reply.id, body: "Better reply"))
        #expect(c.comment(added.id)?.replies.first?.bodyMd == "Better reply")
        #expect(await c.delete(added.id, reply: reply.id))
        #expect(c.comment(added.id)?.replies.isEmpty == true && s.offline.pending.count == 1)
        #expect(await c.reply(to: added.id, body: "Another"))
        // deleting the new comment drops it and its replies
        #expect(await c.delete(added.id))
        #expect(c.comment(added.id) == nil && s.offline.pending.isEmpty)

        // a server comment deleted offline goes from the list at once; one reply of it too
        let lamps = try #require(c.comment(lampsComment))
        #expect(await c.delete(leadComment))
        #expect(c.comment(leadComment) == nil)
        if let r = lamps.replies.first {
            #expect(await c.delete(lampsComment, reply: r.id))
            #expect(c.comment(lampsComment)?.replies.contains { $0.id == r.id } == false)
        }
        #expect(await c.edit(lampsComment, body: "Edited offline"))
        #expect(c.comment(lampsComment)?.bodyMd == "Edited offline" && c.comment(lampsComment)?.editedAt != nil)
        #expect(await c.setResolved(lampsComment, true))
        #expect(await c.setResolved(lampsComment, false))
        #expect(c.comment(lampsComment)?.isOpen == true)
        // back online: a delete of a comment already gone counts as done
        s.net.online = true
        s.server.change("PATCH", "/comments/\(lampsComment)", "comment-edit")
        s.server.change("POST", "/comments/\(lampsComment)/resolve", "comment-resolve")
        s.server.change("POST", "/comments/\(lampsComment)/reopen", "comment-edit")
        s.server.change("DELETE", "/comments/\(lampsComment)/replies/\(lamps.replies.first?.id ?? "-")", "comment-edit")
        #expect(await s.offline.flush())
        #expect(s.offline.pending.isEmpty)
        #expect(s.requests("/comments/\(leadComment)", method: "DELETE").first?.query["confirm"] == ["true"])
    }

    @Test func aSignInThatEndedStopsTheQueue() async throws {
        let s = OfflineStack()
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.net.online = false
        #expect(await c.setResolved(leadComment, true))
        s.net.online = true
        s.server.status("/comments/\(leadComment)/resolve", 401)
        #expect(await s.offline.flush() == false)
        #expect(s.offline.pending.count == 1 && s.offline.pending[0].problem == nil)
    }

    @Test func refusalsOnlineAreShownNotQueued() async throws {
        let s = OfflineStack()
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.server.change("POST", "/comments", "comment-error", status: 422)
        #expect(await c.add(section: "history", picked: picked, body: "x") == nil)
        #expect(c.actionError?.hint?.hasPrefix("Copy the passage") == true && s.offline.pending.isEmpty)
        // the server failing for now: kept for later instead
        s.server.status("/comments", 502)
        #expect(await c.add(section: "history", picked: nil, body: "Later") != nil)
        #expect(s.offline.pending.count == 1 && c.actionError == nil)
    }

    @Test func overlaysEveryKindOfChange() throws {
        let server = try Fixture.decode(CommentList.self, "comments-lampton").comments
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func q(_ kind: QueuedChange.Kind, comment: String? = nil, reply: String? = nil, body: String? = nil, resolve: Bool? = nil,
               page: String = "lampton") -> QueuedChange {
            QueuedChange(kind: kind, world: "main", page: page, comment: comment, reply: reply, section: "lead", body: body,
                         resolve: resolve, queuedAt: at)
        }
        let out = CommentsModel.overlay(server, [
            q(.add, body: "Elsewhere", page: "dirk"),       // another page's new comment stays out
            q(.reply, comment: lampsComment, body: "Done", resolve: true),
            q(.edit, comment: lampsComment, reply: "missing", body: "x"),
            q(.reopen, comment: "unknown"),
            q(.delete, comment: leadComment),
        ], page: "lampton")
        #expect(out.count == 4 && !out.contains { $0.id == leadComment })
        let lamps = try #require(out.first { $0.id == lampsComment })
        #expect(lamps.status == .resolved && lamps.resolvedBy == "you" && lamps.replies.last?.bodyMd == "Done")
        #expect(lamps.replies.last?.createdAt == "2027-01-15T08:00:00Z")
        #expect(QueuedChange(kind: .edit, world: nil, page: "p", reply: "r", queuedAt: at).summary == "Edit reply")
        #expect(QueuedChange(kind: .delete, world: nil, page: "p", queuedAt: at).summary == "Delete comment")
        #expect(QueuedChange(kind: .delete, world: nil, page: "p", reply: "r", queuedAt: at).summary == "Delete reply")
        #expect(QueuedChange(kind: .reopen, world: nil, page: "p", queuedAt: at).summary == "Reopen")
        #expect(QueuedChange(kind: .reply, world: nil, page: "p", queuedAt: at).summary == "Reply")
        // a change missing what it needs has no request, and is dropped when its turn comes
        for k in [QueuedChange.Kind.add, .reply, .resolve, .edit, .delete] {
            #expect(QueuedChange(kind: k, world: nil, page: "p", queuedAt: at).change == nil)
        }
    }

    @Test func dropsChangesThatCannotBeSent() async throws {
        let s = OfflineStack()
        await s.outbox.append(QueuedChange(kind: .reply, world: "main", page: "lampton", queuedAt: s.clock.now))
        await s.offline.prepare()
        #expect(s.offline.pending.count == 1)
        #expect(await s.offline.flush())
        #expect(s.offline.pending.isEmpty)
        await s.outbox.append(QueuedChange(kind: .resolve, world: "main", page: "lampton", comment: "c", queuedAt: s.clock.now))
        await s.outbox.removeAll()
        #expect(await s.outbox.all.isEmpty)
        await s.outbox.replace(QueuedChange(kind: .resolve, world: "main", page: "x", queuedAt: s.clock.now))
        #expect(await s.outbox.all.isEmpty)
    }
}

@MainActor
@Suite struct SyncTests {
    @Test func sendsThenRefreshesAndPacesItself() async throws {
        let s = OfflineStack()
        _ = try #require(await s.offline.download(ref: "lampton", world: "main", view: .default))
        s.server.change("POST", "/comments/\(leadComment)/resolve", "comment-resolve")
        let c = CommentsModel(ref: "lampton", context: s.context())
        await c.load()
        s.net.online = false
        #expect(await c.setResolved(leadComment, true))
        await s.offline.sync()
        #expect(s.offline.lastSyncOffline && s.offline.lastSync == nil && s.offline.pending.count == 1)
        s.net.online = true
        s.server.newest(500)
        await s.offline.sync()
        #expect(s.offline.pending.isEmpty && !s.offline.lastSyncOffline && s.offline.lastSync == s.clock.now)
        #expect(s.offline.downloads[0].mark == 500)
        // a minute later nothing new: no requests
        let before = s.server.requests.count
        s.clock.advance(60)
        await s.offline.sync()
        #expect(s.server.requests.count == before)
        await s.offline.sync(force: true)
        #expect(s.server.requests.count > before)
        // refresh fails on a world out of reach
        s.net.online = false
        s.clock.advance(1000)
        await s.offline.sync(force: true)
        #expect(s.offline.lastSyncOffline)
    }

    @Test func theAppSyncsAtLaunchAndWhenItComesBack() async throws {
        let server = FakeServer.offline()
        server.change("POST", "/comments/\(leadComment)/resolve", "comment-resolve")
        let app = try await TestApp(server: server).signedIn()
        let offline = try #require(app.model.offline)
        #expect(app.model.context?.offline === offline)
        let d = try #require(await offline.download(ref: "lampton", world: "main", view: .default))
        await offline.queue(QueuedChange(kind: .resolve, world: "main", page: "lampton", comment: leadComment, queuedAt: app.clock.now))
        await app.model.connectivityChanged(online: false)
        #expect(offline.pending.count == 1)
        await app.model.connectivityChanged(online: true)
        #expect(offline.pending.isEmpty)
        await app.model.didBecomeActive()

        // Clear cache keeps the downloads; a relaunch finds them
        await app.model.clearCache()
        let again = app.relaunched()
        await again.model.start()
        #expect(again.model.offline?.downloads.map(\.id) == [d.id])
        // sign-out deletes them
        await again.model.signOut()
        #expect(again.model.offline == nil)
        await again.model.didBecomeActive()
        await again.model.connectivityChanged(online: true)
        let third = try await again.relaunched().signedIn()
        await third.model.offline?.prepare()
        #expect(third.model.offline?.downloads.isEmpty == true)
    }

    @Test func tellsWhatCannotBeReached() {
        #expect(OfflineModel.unreachable(APIError.offline("")))
        #expect(OfflineModel.unreachable(APIError.problem(Problem(status: 503))))
        #expect(OfflineModel.unreachable(APIError.problem(Problem(status: 429))))
        #expect(!OfflineModel.unreachable(APIError.problem(Problem(status: 422))))
        #expect(!OfflineModel.unreachable(APIError.signedOut))
        #expect(!OfflineModel.unreachable(CancellationError()))
        #expect(OfflineModel.unreachable(URLError(.timedOut)))
        #expect(APIError.from(status: 500, body: Data()).problemStatus == 500)
    }
}

extension APIError {
    var problemStatus: Int? {
        if case .problem(let p) = self { return p.status }
        return nil
    }
}
