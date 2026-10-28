import Foundation
import Testing
@testable import LoreGraphKit

private func metadata() throws -> AuthorizationServerMetadata {
    try Fixture.decode(AuthorizationServerMetadata.self, "oauth-metadata")
}

private func tokenJSON(_ access: String, refresh: String? = "r-2", expiresIn: Double? = 3600, scope: String? = "lore:read") -> Data {
    var o: [String: Any] = ["access_token": access, "token_type": "Bearer"]
    if let refresh { o["refresh_token"] = refresh }
    if let expiresIn { o["expires_in"] = expiresIn }
    if let scope { o["scope"] = scope }
    return try! JSONSerialization.data(withJSONObject: o)
}

private func oauthCredentials(access: String = "a-1", refresh: String? = "r-1", expiresAt: Date? = nil) -> Credentials {
    Credentials(kind: .oauth, server: testServer, accessToken: access, refreshToken: refresh, expiresAt: expiresAt,
                scope: "lore:read lore:secrets", tokenEndpoint: URL(string: "https://lore.example.test/oauth/token"),
                revocationEndpoint: URL(string: "https://lore.example.test/oauth/revoke"))
}

@Suite struct CredentialsTests {
    @Test func refreshesAMinuteBeforeExpiry() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(oauthCredentials(expiresAt: now.addingTimeInterval(30)).needsRefresh(now: now))
        #expect(!oauthCredentials(expiresAt: now.addingTimeInterval(300)).needsRefresh(now: now))
        #expect(!oauthCredentials(refresh: nil, expiresAt: now).needsRefresh(now: now))
        #expect(!oauthCredentials(expiresAt: nil).needsRefresh(now: now))
        #expect(!Credentials(kind: .personal, server: testServer, accessToken: "x").needsRefresh(now: now))
    }

    @Test func listsScopes() {
        #expect(oauthCredentials().scopes == ["lore:read", "lore:secrets"])
        #expect(Credentials(kind: .personal, server: testServer, accessToken: "x").scopes.isEmpty)
    }

    @Test func memoryStore() throws {
        let s = MemoryTokenStore()
        #expect(try s.load() == nil)
        try s.save(oauthCredentials())
        #expect(try s.load()?.accessToken == "a-1")
        try s.delete()
        #expect(try s.load() == nil)
    }

    #if canImport(Security)
    @Test func keychainStore() throws {
        let s = KeychainTokenStore(service: "net.loregraph.tests.\(UUID().uuidString)", account: "test")
        defer { try? s.delete() }
        do {
            #expect(try s.load() == nil)
            try s.save(oauthCredentials())
            try s.save(oauthCredentials(access: "a-2"))
            #expect(try s.load()?.accessToken == "a-2")
            try s.delete()
            #expect(try s.load() == nil)
        } catch let e as KeychainError {
            // a test host without a keychain (CI) can't store items; the error must say so
            #expect(e.status != 0)
        }
    }
    #endif
}

@Suite struct OAuthClientTests {
    @Test func normalisesTypedAddresses() {
        #expect(OAuthClient.normalised(URL(string: "Lore.Example.Test")!).absoluteString == "https://lore.example.test")
        #expect(OAuthClient.normalised(URL(string: "HTTP://localhost:8000/x?y#z")!).absoluteString == "http://localhost:8000")
    }

    @Test func discoversALoregraphServer() async throws {
        let server = FakeServer.testmark()
        let client = try await OAuthClient.discover(server: URL(string: "https://lore.example.test/wiki")!, transport: server)
        #expect(client.server == testServer)
        #expect(client.resource == "https://lore.example.test/api")
        #expect(client.metadata.tokenEndpoint.hasSuffix("/oauth/token"))
    }

    @Test func refusesOtherServers() async {
        let offline = FakeServer()
        offline.offline("/.well-known/oauth-authorization-server")
        await #expect(throws: APIError.offline("Can't reach lore.example.test.")) {
            try await OAuthClient.discover(server: testServer, transport: offline)
        }
        let failing = FakeServer()
        failing.on("/.well-known/oauth-authorization-server") { _ in throw TransportError(message: "TLS", isOffline: false) }
        await #expect(throws: APIError.offline("TLS")) { try await OAuthClient.discover(server: testServer, transport: failing) }

        let notOurs = FakeServer()
        notOurs.status("/.well-known/oauth-authorization-server", 404)
        do {
            _ = try await OAuthClient.discover(server: testServer, transport: notOurs)
            Issue.record("expected a refusal")
        } catch let e as APIError {
            if case .notLoregraph = e {} else { Issue.record("wrong error \(e)") }
        } catch {}

        var meta = try! metadata()
        meta.issuer = "https://elsewhere.test"
        let other = FakeServer()
        other.json("/.well-known/oauth-authorization-server", value: meta)
        do {
            _ = try await OAuthClient.discover(server: testServer, transport: other)
            Issue.record("expected a refusal")
        } catch let e as APIError {
            #expect(e.message.contains("elsewhere.test"))
        } catch {}

        meta = try! metadata()
        meta.codeChallengeMethodsSupported = ["plain"]
        let weak = FakeServer()
        weak.json("/.well-known/oauth-authorization-server", value: meta)
        do {
            _ = try await OAuthClient.discover(server: testServer, transport: weak)
            Issue.record("expected a refusal")
        } catch let e as APIError {
            #expect(e.message.contains("PKCE"))
        } catch {}
    }

    @Test func authorizationAddressAsksForReading() throws {
        let client = OAuthClient(server: testServer, metadata: try metadata(), transport: FakeServer())
        let request = client.authorizationRequest(pkce: PKCE(verifier: "v"), state: "s")
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(request.url.path == "/oauth/authorize")
        #expect(q["client_id"] == "loregraph-ios")
        #expect(q["redirect_uri"] == "loregraph://oauth/callback")
        #expect(q["scope"] == "lore:read lore:secrets offline_access")
        #expect(q["state"] == "s")
        #expect(q["code_challenge"] == PKCE(verifier: "v").challenge)
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["resource"] == "https://lore.example.test/api")
        let random = client.authorizationRequest()
        #expect(random.state != client.authorizationRequest().state)
    }

    @Test func readsTheCallback() throws {
        let client = OAuthClient(server: testServer, metadata: try metadata(), transport: FakeServer())
        let request = client.authorizationRequest(pkce: PKCE(verifier: "v"), state: "s")
        func code(_ s: String) throws -> String { try client.code(from: URL(string: s)!, for: request) }
        #expect(try code("loregraph://oauth/callback?code=abc&state=s&iss=https://lore.example.test") == "abc")
        func message(_ s: String) -> String {
            do {
                _ = try code(s)
                return ""
            } catch let e as APIError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        #expect(message("https://evil.test/?code=abc&state=s").contains("wrong place"))
        #expect(message("loregraph://oauth/callback?code=abc&state=x").contains("didn't match"))
        #expect(message("loregraph://oauth/callback?code=abc&state=s&iss=https://evil.test").contains("another server"))
        #expect(message("loregraph://oauth/callback?error=access_denied&state=s").contains("chose not"))
        #expect(message("loregraph://oauth/callback?error=invalid_target&state=s").contains("REST API"))
        #expect(message("loregraph://oauth/callback?error=server_error&error_description=Boom&state=s") == "Boom")
        #expect(message("loregraph://oauth/callback?error=server_error&state=s") == "server_error")
        #expect(message("loregraph://oauth/callback?state=s").contains("no sign-in code"))
    }

    @Test func exchangesTheCodeAndRefreshes() async throws {
        let server = FakeServer()
        let clock = TestClock()
        server.on("/oauth/token") { req in
            let form = req.form
            if form["grant_type"] == "authorization_code" {
                #expect(form["code"] == "abc")
                #expect(form["code_verifier"] == "v")
                #expect(form["client_id"] == "loregraph-ios")
                #expect(form["resource"] == "https://lore.example.test/api")
                return HTTPResponse(status: 200, body: tokenJSON("a-1", refresh: "r-1"))
            }
            #expect(form["refresh_token"] == "r-1")
            return HTTPResponse(status: 200, body: tokenJSON("a-2", refresh: nil, expiresIn: nil, scope: nil))
        }
        let client = OAuthClient(server: testServer, metadata: try metadata(), transport: server, now: clock.function)
        let request = client.authorizationRequest(pkce: PKCE(verifier: "v"), state: "s")
        let creds = try await client.exchange(code: "abc", request: request)
        #expect(creds.kind == .oauth)
        #expect(creds.accessToken == "a-1")
        #expect(creds.refreshToken == "r-1")
        #expect(creds.expiresAt == clock.now.addingTimeInterval(3600))
        #expect(creds.revocationEndpoint?.path == "/oauth/revoke")
        let fresh = try await client.refresh(creds)
        #expect(fresh.accessToken == "a-2")
        #expect(fresh.refreshToken == "r-1")
        #expect(fresh.scope == "lore:read")
        #expect(fresh.expiresAt == nil)
        await #expect(throws: APIError.signedOut) {
            try await client.refresh(Credentials(kind: .oauth, server: testServer, accessToken: "x"))
        }
    }

    @Test func tokenFailures() async throws {
        let request = AuthorizationRequest(url: testServer, state: "s", pkce: PKCE(verifier: "v"), resource: "r")
        func client(_ handler: @escaping FakeServer.Handler) throws -> OAuthClient {
            let s = FakeServer()
            s.on("/oauth/token", handler)
            return OAuthClient(server: testServer, metadata: try metadata(), transport: s)
        }
        await #expect(throws: APIError.signedOut) {
            try await client { _ in HTTPResponse(status: 400) }.exchange(code: "c", request: request)
        }
        await #expect(throws: APIError.offline("down")) {
            try await client { _ in throw TransportError(message: "down", isOffline: true) }.exchange(code: "c", request: request)
        }
        do {
            _ = try await client { _ in HTTPResponse(status: 503) }.exchange(code: "c", request: request)
            Issue.record("expected a problem")
        } catch let e as APIError {
            #expect(e.title == "The server had a problem")
        }
        do {
            _ = try await client { _ in HTTPResponse(status: 200, body: Data("{}".utf8)) }.exchange(code: "c", request: request)
            Issue.record("expected unreadable")
        } catch let e as APIError {
            if case .unreadable = e {} else { Issue.record("wrong error \(e)") }
        }
        var meta = try metadata()
        meta.tokenEndpoint = ""
        let broken = OAuthClient(server: testServer, metadata: meta, transport: FakeServer())
        do {
            _ = try await broken.exchange(code: "c", request: request)
            Issue.record("expected a refusal")
        } catch let e as APIError {
            if case .notLoregraph = e {} else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func revokesBothTokensAtSignOut() async {
        let server = FakeServer()
        server.on("/oauth/revoke") { _ in HTTPResponse(status: 200) }
        await TokenRevoker.revoke(oauthCredentials(), transport: server)
        #expect(server.requests.map { $0.form["token"] } == ["r-1", "a-1"])
        await TokenRevoker.revoke(Credentials(kind: .personal, server: testServer, accessToken: "p"), transport: server)
        #expect(server.requests.count == 2)
    }
}

@Suite struct AuthSessionTests {
    @Test func signsInAndOut() async throws {
        let store = MemoryTokenStore()
        let server = FakeServer()
        server.on("/oauth/revoke") { _ in HTTPResponse(status: 200) }
        let auth = AuthSession(store: store, transport: server)
        #expect(await !auth.isSignedIn)
        await #expect(throws: APIError.signedOut) { try await auth.accessToken() }
        await #expect(throws: APIError.signedOut) { try await auth.tokenAfterUnauthorized("x") }
        try await auth.signIn(oauthCredentials())
        #expect(await auth.isSignedIn)
        #expect(try store.load()?.accessToken == "a-1")
        #expect(try await auth.accessToken() == "a-1")
        await auth.signOut()
        #expect(await !auth.isSignedIn)
        #expect(try store.load() == nil)
        #expect(server.count("/oauth/revoke") == 2)
        // a second launch reads the store
        try store.save(oauthCredentials(access: "saved"))
        #expect(try await AuthSession(store: store, transport: server).accessToken() == "saved")
    }

    @Test func refreshesBeforeExpiryOnce() async throws {
        let clock = TestClock()
        let server = FakeServer()
        server.on("/oauth/token") { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return HTTPResponse(status: 200, body: tokenJSON("a-2", refresh: "r-2"))
        }
        let store = MemoryTokenStore(oauthCredentials(expiresAt: clock.now.addingTimeInterval(10)))
        let auth = AuthSession(store: store, transport: server, now: clock.function)
        async let one = auth.accessToken()
        async let two = auth.accessToken()
        let tokens = try await [one, two]
        #expect(tokens == ["a-2", "a-2"])
        #expect(server.count("/oauth/token") == 1)
        #expect(try store.load()?.refreshToken == "r-2")
    }

    @Test func refreshesAfterUnauthorized() async throws {
        let server = FakeServer()
        server.on("/oauth/token") { _ in HTTPResponse(status: 200, body: tokenJSON("a-2")) }
        let auth = AuthSession(store: MemoryTokenStore(oauthCredentials()), transport: server)
        #expect(try await auth.tokenAfterUnauthorized("a-1") == "a-2")
        // someone else already refreshed: the current token comes back without a call
        #expect(try await auth.tokenAfterUnauthorized("a-1") == "a-2")
        #expect(server.count("/oauth/token") == 1)
    }

    @Test func aRefusedRefreshSignsOut() async throws {
        let server = FakeServer()
        server.on("/oauth/token") { _ in HTTPResponse(status: 400) }
        let store = MemoryTokenStore(oauthCredentials())
        let auth = AuthSession(store: store, transport: server)
        await #expect(throws: APIError.signedOut) { try await auth.tokenAfterUnauthorized("a-1") }
        #expect(await !auth.isSignedIn)
        #expect(try store.load() == nil)
    }

    @Test func aRefusedPersonalTokenSignsOut() async throws {
        let store = MemoryTokenStore(Credentials(kind: .personal, server: testServer, accessToken: "p"))
        let auth = AuthSession(store: store, transport: FakeServer())
        await #expect(throws: APIError.signedOut) { try await auth.tokenAfterUnauthorized("p") }
        #expect(try store.load() == nil)
    }

    @Test func refreshWithoutAnEndpointSignsOut() async throws {
        var creds = oauthCredentials(expiresAt: Date.distantPast)
        creds.tokenEndpoint = nil
        let auth = AuthSession(store: MemoryTokenStore(creds), transport: FakeServer())
        await #expect(throws: APIError.signedOut) { try await auth.accessToken() }
        #expect(await !auth.isSignedIn)
    }

    @Test func otherRefreshFailuresKeepTheSignIn() async throws {
        let server = FakeServer()
        server.on("/oauth/token") { _ in throw TransportError(message: "down", isOffline: true) }
        let auth = AuthSession(store: MemoryTokenStore(oauthCredentials()), transport: server)
        await #expect(throws: APIError.offline("down")) { try await auth.tokenAfterUnauthorized("a-1") }
        #expect(await auth.isSignedIn)
    }
}

@Suite struct APIClientTests {
    @Test func getsAndDecodes() async throws {
        let stack = Stack()
        let me = try await stack.client.get(API.me(), world: nil)
        #expect(me.value.ceiling == .designer)
        #expect(!me.data.isEmpty)
        let sent = try #require(stack.server.requests.last)
        #expect(sent.headers["Authorization"] == "Bearer token-1")
        #expect(sent.headers["Accept"] == "application/json")
    }

    @Test func turnsFailuresIntoErrors() async throws {
        let stack = Stack()
        stack.server.status("/about", 500)
        stack.server.json("/worlds", value: ["worlds": "not a list"])
        await #expect(throws: APIError.self) { try await stack.client.get(API.about(), world: "main") }
        do {
            _ = try await stack.client.get(API.worlds(), world: nil)
            Issue.record("expected unreadable")
        } catch let e as APIError {
            if case .unreadable(let m) = e { #expect(m.contains("worlds")) } else { Issue.record("wrong \(e)") }
        }
        stack.server.json("/me", value: ["id": "1"])
        do {
            _ = try await stack.client.get(API.me(), world: nil)
            Issue.record("expected unreadable")
        } catch let e as APIError {
            if case .unreadable(let m) = e { #expect(m.contains("Missing")) } else { Issue.record("wrong \(e)") }
        }
        stack.server.offline("/views")
        await #expect(throws: APIError.offline("")) { try await stack.client.get(API.views(), world: "main") }
        stack.server.on("/map/layers") { _ in throw TransportError(message: "TLS failed", isOffline: false) }
        await #expect(throws: APIError.offline("TLS failed")) { try await stack.client.get(API.mapLayers(), world: "main") }
    }

    @Test func describesDecodingErrors() {
        let ctx = DecodingError.Context(codingPath: [], debugDescription: "d")
        #expect(APIClient.describe(.valueNotFound(String.self, ctx)).contains("Unexpected value"))
        #expect(APIClient.describe(.dataCorrupted(ctx)).contains("d"))
    }

    @Test func retriesOnceAfterARefresh() async throws {
        let server = FakeServer.testmark()
        server.on("/oauth/token") { _ in HTTPResponse(status: 200, body: tokenJSON("a-2")) }
        server.on("/me") { req in
            req.headers["Authorization"] == "Bearer a-2" ? HTTPResponse(status: 200, body: Fixture.data("me")) : HTTPResponse(status: 401)
        }
        let auth = AuthSession(store: MemoryTokenStore(oauthCredentials()), transport: server)
        let client = APIClient(server: testServer, transport: server, auth: auth)
        let me = try await client.get(API.me(), world: nil)
        #expect(me.value.scopes.contains("lore:read"))
    }

    @Test func tellsTheAppWhenSignedOut() async throws {
        let server = FakeServer()
        server.status("/me", 401)
        server.on("/oauth/token") { _ in HTTPResponse(status: 200, body: tokenJSON("a-2")) }
        let flag = TestFlag()
        let auth = AuthSession(store: MemoryTokenStore(oauthCredentials()), transport: server)
        let client = APIClient(server: testServer, transport: server, auth: auth, onSignedOut: { flag.set() })
        await #expect(throws: APIError.signedOut) { try await client.get(API.me(), world: nil) }
        #expect(flag.isSet)
    }

    @Test func fetchesBytes() async throws {
        let stack = Stack()
        let tile = try await stack.client.bytes(path: "/map/tiles/places/5/16/5.mvt", query: [URLQueryItem(name: "v", value: "67")],
                                                world: "main")
        #expect(tile?.isEmpty == false)
        #expect(stack.server.requests.last?.headers["Accept"] == "*/*")
        #expect(stack.server.requests.last?.query["world"] == ["main"])
        let none = try await stack.client.bytes(path: "/map/tiles/places/0/0/0.mvt", world: "main")
        #expect(none == nil)
        stack.server.status("/map/tiles/places/1/0/0.mvt", 500)
        await #expect(throws: APIError.self) { try await stack.client.bytes(path: "/map/tiles/places/1/0/0.mvt", world: nil) }
    }

    @Test func sendsTheTokenOnlyToItsOwnServer() async throws {
        let server = FakeServer()
        server.on("/media/a.png") { req in
            HTTPResponse(status: req.url.host == "lore.example.test" ? 200 : 404, body: Data(req.headers["Authorization"].map { Array($0.utf8) } ?? []))
        }
        server.fallback = { req in HTTPResponse(status: 200, body: Data((req.headers["Authorization"] ?? "none").utf8)) }
        let auth = AuthSession(store: MemoryTokenStore(Credentials(kind: .personal, server: testServer, accessToken: "p")), transport: server)
        let client = APIClient(server: testServer, transport: server, auth: auth)
        let own = try await client.bytes(at: URL(string: "https://lore.example.test/media/a.png")!)
        #expect(String(decoding: own, as: UTF8.self) == "Bearer p")
        let other = try await client.bytes(at: URL(string: "https://cdn.example.test/b.png")!)
        #expect(String(decoding: other, as: UTF8.self) == "none")
        server.fallback = { _ in HTTPResponse(status: 403) }
        await #expect(throws: APIError.self) { try await client.bytes(at: URL(string: "https://cdn.example.test/b.png")!) }
        server.on("/media/a.png") { _ in HTTPResponse(status: 410) }
        await #expect(throws: APIError.self) { try await client.bytes(at: URL(string: "https://lore.example.test/media/a.png")!) }
    }
}

final class TestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
