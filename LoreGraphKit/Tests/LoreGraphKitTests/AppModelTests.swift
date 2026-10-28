import Foundation
import Testing
@testable import LoreGraphKit

/// An app over the fake server, with its own token store, settings and cache folder.
@MainActor
struct TestApp {
    let server: FakeServer
    let tokens: MemoryTokenStore
    let defaults: MemoryKeyValueStore
    let root: URL
    let clock: TestClock
    let model: AppModel

    init(server: FakeServer = .testmark(), tokens: MemoryTokenStore = MemoryTokenStore(),
         defaults: MemoryKeyValueStore = MemoryKeyValueStore(), root: URL = temporaryFolder().appendingPathComponent("caches"),
         clock: TestClock = TestClock()) {
        self.server = server
        self.tokens = tokens
        self.defaults = defaults
        self.root = root
        self.clock = clock
        model = AppModel(environment: AppEnvironment(transport: server, tokenStore: tokens, defaults: defaults, cacheRoot: root,
                                                     now: clock.function))
    }

    /// The same phone opened again: the same server, tokens, settings and caches.
    func relaunched() -> TestApp {
        TestApp(server: server, tokens: tokens, defaults: defaults, root: root, clock: clock)
    }

    func signedIn() async throws -> TestApp {
        try await model.signIn(server: "lore.example.test", personalToken: "token-1")
        return self
    }
}

/// The error a call threw, if it was an APIError.
@MainActor
func apiError(_ body: () async throws -> Void) async -> APIError? {
    do {
        try await body()
        return nil
    } catch let e as APIError {
        return e
    } catch {
        return nil
    }
}

private let tokenAnswer = Data(#"{"access_token": "a-1", "token_type": "Bearer", "refresh_token": "r-1", "expires_in": 3600, "scope": "lore:read lore:secrets"}"#.utf8)

@Suite @MainActor struct AppSignInTests {
    @Test func startsSignedOutWithoutTokens() async {
        let app = TestApp()
        #expect(app.model.phase == .starting)
        await app.model.start()
        #expect(app.model.phase == .signedOut && app.model.context == nil)
        await app.model.start()
        #expect(app.model.phase == .signedOut)
    }

    @Test func forgetsTokensWithoutTheirReader() async throws {
        let tokens = MemoryTokenStore(Credentials(kind: .personal, server: testServer, accessToken: "token-1"))
        let app = TestApp(tokens: tokens)
        await app.model.start()
        #expect(app.model.phase == .signedOut)
        #expect(try tokens.load() == nil)
    }

    @Test func signsInWithAPersonalToken() async throws {
        let app = TestApp()
        try await app.model.signIn(server: " lore.example.test/ ", personalToken: " token-1 ")
        let m = app.model
        #expect(m.phase == .signedIn && m.me?.displayName == "Owner")
        #expect(m.reader == ReaderIdentity(server: testServer, id: "00000000-0000-7000-8000-00000000a001", name: "Owner", ceiling: .designer))
        #expect(m.worlds.count == 3 && m.world?.key == "main" && m.needsWorldChoice)
        #expect(m.about?.presentYear == 1131.25)
        let c = try #require(m.context)
        #expect(c.world == "main" && c.present == 1131.25 && c.ceiling == .designer && c.year == 1131.25)
        #expect(c.key.contains("main"))
        #expect(m.hidesInSwitcher && m.signInMessage == nil && m.worldError == nil)
        #expect(app.server.requests.allSatisfy { $0.headers["Authorization"] == "Bearer token-1" || $0.url.path.hasPrefix("/.") })
    }

    @Test func refusesBadSignIns() async throws {
        let app = TestApp()
        let empty = await apiError { try await app.model.signIn(server: "lore.example.test", personalToken: "  ") }
        #expect(empty?.title == "No token")
        let address = await apiError { try await app.model.signIn(server: "not a server", personalToken: "t") }
        #expect(address == .notLoregraph("Type the address of your loregraph server, such as lore.example.com."))

        app.server.status("/me", 401)
        let refused = await apiError { try await app.model.signIn(server: "lore.example.test", personalToken: "t") }
        #expect(refused?.title == "Sign-in refused")
        #expect(try app.tokens.load() == nil && app.model.phase == .starting)

        app.server.status("/me", 503)
        let down = await apiError { try await app.model.signIn(server: "lore.example.test", personalToken: "t") }
        #expect(down != nil && down?.title != "Sign-in refused")

        app.server.raw("/me", #"{"id": "u-2", "scopes": ["lore:write"], "ceiling": "public"}"#)
        let cannotRead = await apiError { try await app.model.signIn(server: "lore.example.test", personalToken: "t") }
        #expect(cannotRead?.title == "Can't read")
        #expect(try app.tokens.load() == nil && app.model.reader == nil)
    }

    @Test func checksTypedAddresses() throws {
        #expect(try AppModel.serverURL("lore.example.test") == testServer)
        #expect(try AppModel.serverURL("http://localhost:8000").absoluteString == "http://localhost:8000")
        #expect(try AppModel.serverURL("http://mac.local").host == "mac.local")
        // a bare local address is this device's own server, which serves plain http
        #expect(try AppModel.serverURL("localhost:8000").absoluteString == "http://localhost:8000")
        #expect(try AppModel.serverURL("mac.local").scheme == "http")
        #expect(try AppModel.serverURL("https://localhost:8443").scheme == "https")
        #expect(throws: APIError.self) { try AppModel.serverURL("http://lore.example.test") }
        #expect(throws: APIError.self) { try AppModel.serverURL("") }
        #expect(AppModel.isLocal(URL(string: "http://127.0.0.1")!) && AppModel.isLocal(URL(string: "http://[::1]")!))
        #expect(!AppModel.isLocal(URL(string: "file:///tmp")!))
    }

    @Test func signsInThroughTheServersPage() async throws {
        let app = TestApp()
        app.server.on("/oauth/token") { _ in HTTPResponse(status: 200, body: tokenAnswer) }
        let pending = try await app.model.prepareSignIn(server: "lore.example.test")
        #expect(pending.request.url.host == "lore.example.test")
        let callback = URL(string: "loregraph://oauth/callback?code=abc&state=\(pending.request.state)&iss=https://lore.example.test")!
        try await app.model.completeSignIn(pending, callback: callback)
        #expect(app.model.phase == .signedIn)
        #expect(try app.tokens.load()?.accessToken == "a-1")
        #expect(app.server.requests.last { $0.url.path == "/api/v1/me" }?.headers["Authorization"] == "Bearer a-1")

        let wrong = await apiError {
            try await app.model.completeSignIn(pending, callback: URL(string: "loregraph://oauth/callback?code=abc&state=nope")!)
        }
        #expect(wrong != nil)
    }

    @Test func opensStraightOntoTheCachedWorld() async throws {
        let first = try await TestApp().signedIn()
        first.model.settings.requireUnlock = true
        first.model.setView(ViewState(asOf: 1020))

        let again = first.relaunched()
        #expect(again.model.settings.requireUnlock)
        again.server.offline("/me")
        again.server.offline("/worlds")
        again.server.offline("/about")
        again.server.offline("/history")
        await again.model.start()
        let m = again.model
        #expect(m.phase == .signedIn && m.isLocked)
        #expect(m.view.asOf == 1020 && m.world?.key == "main")
        #expect(m.about?.presentYear == 1131.25)
        #expect(m.worldError?.isOffline == true)
        m.unlock()
        #expect(!m.isLocked)
        m.didEnterBackground()
        #expect(m.isLocked)
    }

    @Test func aRefusedTokenEndsTheSession() async throws {
        let app = try await TestApp().signedIn()
        app.model.sessionEnded()
        #expect(app.model.phase == .signedOut && app.model.signInMessage == .signedOut && app.model.reader == nil)
        let fresh = try await TestApp().signedIn()
        fresh.server.status("/me", 401)
        await fresh.model.refresh()
        #expect(await eventually { fresh.model.phase == .signedOut })
        #expect(fresh.model.signInMessage == .signedOut && fresh.model.context == nil)
        fresh.model.sessionEnded()
        #expect(fresh.model.phase == .signedOut)
    }

    @Test func signsOutAndForgets() async throws {
        let app = try await TestApp().signedIn()
        let folder = try #require(app.model.reader?.folder)
        await app.model.signOut()
        #expect(app.model.phase == .signedOut && app.model.reader == nil && app.model.me == nil)
        #expect(!FileManager.default.fileExists(atPath: app.root.path))
        #expect(app.defaults.data(forKey: "reader") == nil && app.defaults.data(forKey: "state." + folder) == nil)
        #expect(try app.tokens.load() == nil)
        await app.model.start()
        #expect(app.model.phase == .signedOut)
    }
}

@Suite @MainActor struct AppWorldTests {
    @Test func choosesWorlds() async throws {
        let app = try await TestApp().signedIn()
        let m = app.model
        await m.selectWorld("nowhere")
        #expect(m.needsWorldChoice)
        await m.selectWorld("main")
        #expect(!m.needsWorldChoice && m.world?.key == "main")
        await m.selectWorld("elsewhere")
        #expect(m.world?.key == "elsewhere" && m.context?.world == "elsewhere")
        #expect(app.server.requests.last { $0.url.path == "/api/v1/about" }?.query["world"] == ["elsewhere"])
        #expect(m.about != nil)
    }

    @Test func keepsTheChosenWorldWhenItStillExists() async throws {
        let app = try await TestApp().signedIn()
        await app.model.selectWorld("elsewhere")
        await app.model.refresh()
        #expect(app.model.world?.key == "elsewhere")
        app.server.json("/worlds", "worlds.public")
        app.server.raw("/worlds", #"{"current": null, "worlds": [{"key": "solo", "name": "Solo", "is_default": true, "visibility": "public"}]}"#)
        await app.model.refresh()
        #expect(app.model.world?.key == "solo" && !app.model.needsWorldChoice)
    }

    @Test func showsWhyTheWorldDidNotLoad() async throws {
        let app = TestApp()
        app.server.status("/worlds", 500)
        app.server.status("/about", 500)
        try await app.model.signIn(server: "lore.example.test", personalToken: "token-1")
        #expect(app.model.worldError != nil && app.model.about == nil)
        #expect(app.model.context?.present == 1131.25)
    }

    @Test func changesTheView() async throws {
        let app = try await TestApp().signedIn()
        let m = app.model
        m.setView(ViewState(asOf: 1020, viewpoint: .init(ref: "dirk", title: "Dirk")))
        #expect(m.view.asOf == 1020 && m.context?.view.viewpoint?.ref == "dirk" && m.context?.year == 1020)
        m.setView(ViewState(viewAs: .designer))
        #expect(m.view.isDefault)
        m.setView(ViewState(viewAs: .public))
        #expect(m.view.viewAs == .public)
        m.resetView()
        #expect(m.view == .default)
        // each world keeps its own view
        m.setView(ViewState(asOf: 1050))
        await m.selectWorld("elsewhere")
        #expect(m.view.isDefault)
        await m.selectWorld("main")
        #expect(m.view.asOf == 1050)
    }

    @Test func aLowerCeilingMeansAnotherCache() async throws {
        let app = try await TestApp().signedIn()
        let before = try #require(app.model.reader?.folder)
        app.server.json("/me", "me.public")
        await app.model.refresh()
        #expect(app.model.reader?.ceiling == .public && app.model.reader?.folder != before)
        #expect(!app.model.hidesInSwitcher && app.model.context?.ceiling == .public)
        app.model.setView(ViewState(viewAs: .restricted))
        #expect(app.model.view.viewAs == nil)
    }

    @Test func remembersPagesSearchesAndTheMap() async throws {
        let app = try await TestApp().signedIn()
        let m = app.model
        for i in 0..<25 { m.visited(EntityCard(ref: "page-\(i)", id: "id-\(i)", title: "Page \(i)")) }
        m.visited(EntityCard(ref: "page-24", id: "id-24", title: "Page 24"))
        #expect(m.recentPages.count == ReadingState.recentLimit && m.recentPages.first?.ref == "page-24")
        #expect(Set(m.recentPages.map(\.ref)).count == m.recentPages.count)

        m.searched("   ")
        #expect(m.recentSearches.isEmpty)
        for i in 0..<12 { m.searched("query \(i)") }
        m.searched("FORD")
        m.searched(" ford ")
        #expect(m.recentSearches.count == 10 && m.recentSearches.first == "ford")
        #expect(m.recentSearches.filter { $0.lowercased() == "ford" }.count == 1)

        let camera = ReadingState.Camera(centre: LonLat(11, 45.5), zoom: 7, layers: ["places"])
        #expect(m.camera == nil)
        m.setCamera(camera)
        #expect(m.camera == camera)

        let again = app.relaunched()
        await again.model.start()
        #expect(again.model.recentPages.first?.ref == "page-24" && again.model.camera == camera)

        m.clearHistory()
        #expect(m.recentPages.isEmpty && m.recentSearches.isEmpty)
    }

    @Test func opensSharedLinks() async throws {
        let signedOut = TestApp()
        #expect(await signedOut.model.open(URL(string: "https://lore.example.test/wiki/dirk")!) == nil)

        let app = try await TestApp().signedIn()
        let link = WebLink(route: .page("aldo"), world: "elsewhere", view: ViewState(asOf: 1020)).url(server: testServer)
        #expect(await app.model.open(link) == .page("aldo"))
        #expect(app.model.world?.key == "elsewhere" && app.model.view.asOf == 1020)
        let plain = WebLink(route: .page("dirk")).url(server: testServer)
        #expect(await app.model.open(plain) == .page("dirk"))
        #expect(app.model.view.asOf == 1020)
        #expect(await app.model.open(URL(string: "https://elsewhere.test/wiki/dirk")!) == nil)
    }

    @Test func clearsTheCache() async throws {
        let app = try await TestApp().signedIn()
        let c = try #require(app.model.context)
        let page = c.loader(API.entity("dirk"))
        await page.load()
        _ = try await c.tiles.tile(TileRequest(layer: "places", tile: TileID(z: 5, x: 16, y: 5), year: 1131, version: 67, world: "main"))
        await app.model.updateCacheSize()
        #expect(app.model.cacheBytes > 0)
        await app.model.clearCache()
        #expect(app.model.cacheBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: app.root.path))
        #expect(await c.repository.cached(API.entity("dirk"), world: "main", view: .default) == nil)
    }

    @Test func settingsAreKept() async {
        let app = TestApp()
        app.model.settings = AppSettings(requireUnlock: false, baseMap: .relief)
        #expect(app.relaunched().model.settings.baseMap == .relief)
        app.model.didEnterBackground()
        #expect(!app.model.isLocked && !app.model.hidesInSwitcher)
    }
}

@Suite struct AppEnvironmentTests {
    @Test func defaults() {
        let env = AppEnvironment(transport: FakeServer(), tokenStore: MemoryTokenStore(), defaults: MemoryKeyValueStore(),
                                 cacheRoot: temporaryFolder())
        #expect(env.cacheLimitBytes == 150_000_000 && env.tileCacheLimitBytes == 300_000_000 && env.freshnessTTL == 30)
        #expect(abs(env.now().timeIntervalSinceNow) < 5)
    }
}
