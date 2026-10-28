import Foundation
import Observation

/// What the app is made of, swapped for fakes in tests.
public struct AppEnvironment: Sendable {
    public var transport: HTTPTransport
    public var tokenStore: TokenStore
    public var defaults: KeyValueStore
    /// The folder holding every reader's cache (inside the app's Caches folder).
    public var cacheRoot: URL
    public var cacheLimitBytes: Int
    public var tileCacheLimitBytes: Int
    /// How long a freshness mark is trusted before the server is asked again.
    public var freshnessTTL: TimeInterval
    public var now: @Sendable () -> Date

    public init(transport: HTTPTransport, tokenStore: TokenStore, defaults: KeyValueStore, cacheRoot: URL,
                cacheLimitBytes: Int = 150_000_000, tileCacheLimitBytes: Int = 300_000_000, freshnessTTL: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.tokenStore = tokenStore
        self.defaults = defaults
        self.cacheRoot = cacheRoot
        self.cacheLimitBytes = cacheLimitBytes
        self.tileCacheLimitBytes = tileCacheLimitBytes
        self.freshnessTTL = freshnessTTL
        self.now = now
    }
}

/// Everything a screen needs to read: the repository, the world and the view, and the present.
public struct ReadContext: Sendable {
    public let repository: Repository
    public let tiles: TileStore
    public let server: URL
    public let world: String?
    public let view: ViewState
    public let present: Double
    public let ceiling: Visibility

    public init(repository: Repository, tiles: TileStore, server: URL, world: String?, view: ViewState, present: Double,
                ceiling: Visibility) {
        self.repository = repository
        self.tiles = tiles
        self.server = server
        self.world = world
        self.view = view
        self.present = present
        self.ceiling = ceiling
    }

    /// Changes whenever a screen should read again (another world or view).
    public var key: String {
        let v = (try? JSONCoding.encoder.encode(view)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(server.absoluteString)|\(world ?? "")|\(v)|\(present)"
    }

    /// The year the screens show: the view's, else the present.
    public var year: Double { view.asOf ?? present }

    @MainActor
    public func loader<T>(_ endpoint: Endpoint<T>) -> Loader<T> {
        repository.loader(endpoint, world: world, view: view)
    }

    /// The web address of a screen, to share (F-11.3).
    public func shareURL(_ route: Route, selected: String? = nil) -> URL {
        WebLink(route: route, world: world, view: view, selected: selected).url(server: server)
    }
}

/// A sign-in waiting for the browser sheet to come back.
public struct PendingSignIn: Sendable {
    public let client: OAuthClient
    public let request: AuthorizationRequest
}

/// The app's state: who is signed in where, the world and view, and the settings (F-1, F-2,
/// F-3, F-11).
@Observable
@MainActor
public final class AppModel {
    public enum Phase: Hashable, Sendable { case starting, signedOut, signedIn }

    public private(set) var phase: Phase = .starting
    public private(set) var reader: ReaderIdentity?
    public private(set) var me: Me?
    public private(set) var about: About?
    public private(set) var state = ReadingState()
    public var settings: AppSettings {
        didSet { env.defaults.setValue(settings, forKey: Keys.settings) }
    }
    /// Why the reader is on the sign-in screen (the sign-in ended, say).
    public private(set) var signInMessage: APIError?
    /// A failure loading the world, shown over the home screen.
    public private(set) var worldError: APIError?
    public private(set) var isLocked = false
    public private(set) var cacheBytes = 0
    public private(set) var context: ReadContext?

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored public let auth: AuthSession
    @ObservationIgnored private var repository: Repository?
    @ObservationIgnored private var tiles: TileStore?
    @ObservationIgnored private var apiCache: DiskCache?
    @ObservationIgnored private var tileCache: DiskCache?
    @ObservationIgnored private var aboutCached: Cached<About>?

    enum Keys {
        static let settings = "settings"
        static let reader = "reader"
        static func state(_ r: ReaderIdentity) -> String { "state." + r.folder }
    }

    public init(environment: AppEnvironment) {
        env = environment
        auth = AuthSession(store: environment.tokenStore, transport: environment.transport, now: environment.now)
        settings = environment.defaults.value(AppSettings.self, forKey: Keys.settings) ?? AppSettings()
    }

    // MARK: launch and sign-in

    /// At launch: open straight onto the cached world when signed in, then check with the server.
    public func start() async {
        guard phase == .starting else { return }
        guard let creds = await auth.credentials,
              let saved = env.defaults.value(ReaderIdentity.self, forKey: Keys.reader), saved.server == creds.server else {
            if await auth.credentials != nil { await auth.signOut() }
            phase = .signedOut
            return
        }
        isLocked = settings.requireUnlock
        become(saved)
        await checkReader()
        await loadWorld()
    }

    /// Checks an address and builds the browser sheet's address (F-1.2).
    public func prepareSignIn(server text: String) async throws -> PendingSignIn {
        let server = try Self.serverURL(text)
        let client = try await OAuthClient.discover(server: server, transport: env.transport)
        return PendingSignIn(client: client, request: client.authorizationRequest())
    }

    /// The browser sheet came back: swap the code for tokens and open the world.
    public func completeSignIn(_ pending: PendingSignIn, callback: URL) async throws {
        let code = try pending.client.code(from: callback, for: pending.request)
        let creds = try await pending.client.exchange(code: code, request: pending.request)
        try await finishSignIn(creds)
    }

    /// Signs in with a personal token made in the web app's settings (F-1.3).
    public func signIn(server text: String, personalToken token: String) async throws {
        let server = try Self.serverURL(text)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw APIError.problem(Problem(title: "No token", detail: "Paste a personal token from the web app's settings."))
        }
        try await finishSignIn(Credentials(kind: .personal, server: server, accessToken: trimmed))
    }

    func finishSignIn(_ creds: Credentials) async throws {
        try await auth.signIn(creds)
        let client = APIClient(server: creds.server, transport: env.transport, auth: auth)
        let me: Me
        do {
            me = try await client.get(API.me(), world: nil).value
        } catch {
            await auth.signOut()
            if case APIError.signedOut = error {
                throw APIError.problem(Problem(title: "Sign-in refused", detail: "The server didn't accept that sign-in. Check the token and try again."))
            }
            throw error
        }
        guard me.scopes.contains("lore:read") else {
            await auth.signOut()
            throw APIError.problem(Problem(title: "Can't read", detail: "That sign-in can't read lore (it has no lore:read scope)."))
        }
        self.me = me
        signInMessage = nil
        become(ReaderIdentity(server: creds.server, id: me.id, name: me.displayName ?? me.email, ceiling: me.ceiling))
        await loadWorld()
    }

    /// Signs out, revokes the tokens and forgets the cache (F-1.7).
    public func signOut() async {
        await auth.signOut()
        try? FileManager.default.removeItem(at: env.cacheRoot)
        if let reader { env.defaults.set(nil, forKey: Keys.state(reader)) }
        env.defaults.set(nil, forKey: Keys.reader)
        reset(to: .signedOut)
    }

    /// The server ended the sign-in (refresh refused, token revoked). The cache stays for the
    /// same reader's next sign-in.
    public func sessionEnded() {
        guard phase == .signedIn else { return }
        signInMessage = .signedOut
        reset(to: .signedOut)
    }

    private func reset(to phase: Phase) {
        self.phase = phase
        reader = nil
        me = nil
        about = nil
        aboutCached = nil
        state = ReadingState()
        repository = nil
        tiles = nil
        apiCache = nil
        tileCache = nil
        context = nil
        cacheBytes = 0
        isLocked = false
    }

    /// Opens the services for a reader and restores where they were.
    private func become(_ r: ReaderIdentity) {
        let folder = env.cacheRoot.appendingPathComponent(r.folder, isDirectory: true)
        let apiCache = DiskCache(directory: folder.appendingPathComponent("api"), limitBytes: env.cacheLimitBytes, now: env.now)
        let tileCache = DiskCache(directory: folder.appendingPathComponent("tiles"), limitBytes: env.tileCacheLimitBytes, now: env.now)
        let client = APIClient(server: r.server, transport: env.transport, auth: auth, onSignedOut: { [weak self] in
            Task { @MainActor in self?.sessionEnded() }
        })
        let freshness = FreshnessTracker(ttl: env.freshnessTTL, now: env.now,
                                         lore: { world in try await client.get(API.historyHead(), world: world).value.newest?.id ?? 0 },
                                         map: { world in Int64(try await client.get(API.mapVersion(), world: world).value.version) })
        reader = r
        env.defaults.setValue(r, forKey: Keys.reader)
        state = env.defaults.value(ReadingState.self, forKey: Keys.state(r)) ?? ReadingState()
        self.apiCache = apiCache
        self.tileCache = tileCache
        repository = Repository(client: client, cache: apiCache, freshness: freshness, now: env.now)
        tiles = TileStore(client: client, cache: tileCache)
        phase = .signedIn
        rebuildContext()
    }

    // MARK: the world

    /// Who you are, the worlds and the world's facts, fresh from the server (pull to refresh on
    /// the home screen).
    public func refresh() async {
        await checkReader()
        await loadWorld(forced: true)
    }

    /// Asks who the tokens read as; another reader or level means another cache.
    func checkReader() async {
        guard let repository, let reader else { return }
        do {
            let me = try await repository.client.get(API.me(), world: nil).value
            self.me = me
            if me.id != reader.id || me.ceiling != reader.ceiling {
                // the same tokens now read at another level: another cache
                become(ReaderIdentity(server: reader.server, id: me.id, name: me.displayName ?? me.email, ceiling: me.ceiling))
            }
        } catch let e as APIError {
            if case .signedOut = e { return }
            worldError = e
        } catch {
            worldError = .offline("")
        }
    }

    func loadWorld(forced: Bool = false) async {
        guard let repository else { return }
        do {
            let list = try await repository.client.get(API.worlds(), world: nil).value
            state.worlds = list.worlds
            if state.world == nil || !list.worlds.contains(where: { $0.key == state.world }) {
                state.world = list.current ?? list.worlds.first(where: { $0.isDefault == true })?.key ?? list.worlds.first?.key
            }
            persist()
            worldError = nil
        } catch let e as APIError {
            if case .signedOut = e { return }
            worldError = e
        } catch {
            worldError = .offline("")
        }
        await loadAbout(forced: forced)
    }

    func loadAbout(forced: Bool = false) async {
        guard let repository else { return }
        let world = state.world
        let endpoint = API.about()
        if aboutCached == nil, let c = await repository.cached(endpoint, world: world, view: .default) {
            aboutCached = c
            about = c.value
            rebuildContext()
        }
        do {
            let fresh: Cached<About>?
            if forced {
                await repository.freshness.reset()
                fresh = try await repository.fetch(endpoint, world: world, view: .default)
            } else {
                fresh = try await repository.revalidate(endpoint, world: world, view: .default, cached: aboutCached)
            }
            guard world == state.world else { return }
            if let fresh {
                aboutCached = fresh
                about = fresh.value
            }
            rebuildContext()
        } catch let e as APIError {
            if case .signedOut = e { return }
            if about == nil { worldError = e }
        } catch {
            if about == nil { worldError = .offline("") }
        }
    }

    public var worlds: [World] { state.worlds }

    public var world: World? { state.worlds.first { $0.key == state.world } }

    /// Whether to ask which world to open (several worlds, none picked yet).
    public var needsWorldChoice: Bool { state.worlds.count > 1 && state.worldChosen != true }

    /// Switches world: its own view, recent pages and map (F-2.2).
    public func selectWorld(_ key: String) async {
        guard state.worlds.contains(where: { $0.key == key }) else { return }
        state.worldChosen = true
        guard key != state.world else {
            persist()
            return
        }
        state.world = key
        about = nil
        aboutCached = nil
        persist()
        rebuildContext()
        await loadAbout()
    }

    // MARK: the view

    private var worldSlot: String { state.world ?? "" }

    public var view: ViewState { state.views[worldSlot] ?? .default }

    /// Changes the year, viewpoint, calendar or preview level for this world (F-3).
    public func setView(_ view: ViewState) {
        var v = view
        if let ceiling = reader?.ceiling, let a = v.viewAs, a >= ceiling { v.viewAs = nil }
        state.views[worldSlot] = v.isDefault ? nil : v
        persist()
        rebuildContext()
    }

    public func resetView() { setView(.default) }

    private func rebuildContext() {
        guard let repository, let tiles, let reader, phase == .signedIn else {
            context = nil
            return
        }
        let next = ReadContext(repository: repository, tiles: tiles, server: reader.server, world: state.world, view: view,
                               present: about?.presentYear ?? 1131.25, ceiling: reader.ceiling)
        if context?.key != next.key { context = next }
    }

    // MARK: recent pages and searches

    public var recentPages: [EntityCard] { state.recentPages[worldSlot] ?? [] }

    /// Notes a page opened, for the home screen's recent list (F-4.1).
    public func visited(_ card: EntityCard) {
        var list = state.recentPages[worldSlot] ?? []
        list.removeAll { $0.ref == card.ref || $0.id == card.id }
        list.insert(card, at: 0)
        state.recentPages[worldSlot] = Array(list.prefix(ReadingState.recentLimit))
        persist()
    }

    public var recentSearches: [String] { state.recentSearches }

    public func searched(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        state.recentSearches.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        state.recentSearches.insert(t, at: 0)
        state.recentSearches = Array(state.recentSearches.prefix(10))
        persist()
    }

    public func clearHistory() {
        state.recentPages[worldSlot] = nil
        state.recentSearches = []
        persist()
    }

    public var camera: ReadingState.Camera? { state.cameras[worldSlot] }

    public func setCamera(_ camera: ReadingState.Camera) {
        state.cameras[worldSlot] = camera
        persist()
    }

    private func persist() {
        guard let reader else { return }
        env.defaults.setValue(state, forKey: Keys.state(reader))
    }

    // MARK: links

    /// Opens a loregraph link (a shared web address or a loregraph:// link): switches world and
    /// view as the link says and returns the screen to show (F-11.3).
    public func open(_ url: URL) async -> Route? {
        guard phase == .signedIn, let link = WebLink.parse(url, server: reader?.server) else { return nil }
        if let w = link.world, w != state.world { await selectWorld(w) }
        if !link.view.isDefault { setView(link.view) }
        return link.route
    }

    // MARK: the cache

    /// Settings' Clear cache: every stored answer and tile, for every reader on this phone.
    public func clearCache() async {
        await repository?.cache.clear()
        await tiles?.clear()
        await repository?.freshness.reset()
        try? FileManager.default.removeItem(at: env.cacheRoot)
        await updateCacheSize()
    }

    public func updateCacheSize() async {
        let a = await apiCache?.totalBytes ?? 0
        let t = await tileCache?.totalBytes ?? 0
        cacheBytes = a + t
    }

    // MARK: the lock

    /// The app went to the background: lock it when Face ID is required (F-1.5).
    public func didEnterBackground() {
        if settings.requireUnlock, phase == .signedIn { isLocked = true }
    }

    public func unlock() { isLocked = false }

    /// Whether the app switcher should show a blurred snapshot: anything above public can be on
    /// screen (F-1.6).
    public var hidesInSwitcher: Bool { phase == .signedIn && (reader?.ceiling ?? .public) > .public }

    // MARK: helpers

    /// A typed server address, checked.
    public static func serverURL(_ text: String) throws -> URL {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t.contains("://") ? t : "https://" + t), u.host != nil else {
            throw APIError.notLoregraph("Type the address of your loregraph server, such as lore.example.com.")
        }
        let n = OAuthClient.normalised(u)
        guard n.scheme == "https" || (n.scheme == "http" && Self.isLocal(n)) else {
            throw APIError.notLoregraph("Use an https address. Plain http only works for this device's own network.")
        }
        return n
    }

    static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }
}
