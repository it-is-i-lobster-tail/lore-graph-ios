import Foundation
import Testing
@testable import LoreGraphKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct DigestTests {
    @Test func sha256MatchesKnownVectors() {
        #expect(Digest.sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(Digest.sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func portableSHA256MatchesKnownVectors() {
        func hex(_ s: String) -> String { PortableSHA256.hash(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        #expect(hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(hex(String(repeating: "a", count: 1000)) == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func base64URLHasNoPaddingOrUnsafeCharacters() {
        #expect(Digest.base64URL(Data([0xFB, 0xFF, 0xBF])) == "-_-_")
        #expect(Digest.base64URL(Data([0x61])) == "YQ")
    }

    @Test func randomBytesHaveTheLengthAsked() {
        #expect(Digest.randomBytes(32).count == 32)
        #expect(Digest.randomBytes(16) != Digest.randomBytes(16))
    }

    @Test func pkceChallengeIsTheVerifiersHash() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mJ92K9qkM1y1i8DeMvEqDT5pWeqgN8")
        #expect(p.challenge == "zMxo-_eoI119dC-v3uY1h5OfC8-m53toMEK0J7y5sbE")
        let made = PKCE.make()
        #expect(made.verifier.count == 43)
        #expect(made.challenge == PKCE(verifier: made.verifier).challenge)
    }
}

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let data = Data(#"{"n":null,"b":true,"x":1.5,"i":3,"s":"hi","a":[1,"two",false],"o":{"k":"v"}}"#.utf8)
        let v = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(v["n"] == .null)
        #expect(v["b"]?.bool == true)
        #expect(v["x"]?.number == 1.5)
        #expect(v["s"]?.string == "hi")
        #expect(v["a"]?.array?.count == 3)
        #expect(v["o"]?.object?["k"] == .string("v"))
        #expect(v["s"]?.number == nil)
        #expect(v["x"]?.string == nil)
        #expect(v["x"]?.bool == nil)
        #expect(v["x"]?.array == nil)
        #expect(v["x"]?.object == nil)
        #expect(JSONValue.string("true").bool == true)
        #expect(JSONValue.string("nope").bool == false)
    }

    @Test func roundTrips() throws {
        let v = JSONValue.object(["n": .null, "b": .bool(false), "x": .number(2), "s": .string("a"), "a": .array([.number(1)]),
                                  "o": .object(["k": .string("v")])])
        let back = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
        #expect(back == v)
    }

    @Test func readsAsShortText() {
        #expect(JSONValue.null.text == "")
        #expect(JSONValue.bool(true).text == "yes")
        #expect(JSONValue.bool(false).text == "no")
        #expect(JSONValue.number(3).text == "3")
        #expect(JSONValue.number(2.5).text == "2.5")
        #expect(JSONValue.string("x").text == "x")
        #expect(JSONValue.array([.string("a"), .null, .number(1)]).text == "a, 1")
        #expect(JSONValue.object(["b": .number(2), "a": .string("x")]).text == "a: x, b: 2")
    }
}

/// Answers URLSession requests from a table, for testing the real transport.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (URLRequest) -> Result<(Int, [String: String], Data), URLError> = { _ in
        .success((200, [:], Data()))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.answer(request) {
        case .success(let (status, headers, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct HTTPTests {
    @Test func formEncodesFields() {
        let r = HTTPRequest.form(testServer, [("a b", "c&d"), ("e", "~ok.-_")])
        #expect(r.method == "POST")
        #expect(r.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(String(decoding: r.body!, as: UTF8.self) == "a%20b=c%26d&e=~ok.-_")
    }

    @Test func headersAreFoundIgnoringCase() {
        let r = HTTPResponse(status: 200, headers: ["Content-Type": "x"])
        #expect(r.header("content-type") == "x")
        #expect(r.header("etag") == nil)
    }

    func transport() -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    @Test func urlSessionTransportSendsAndReads() async throws {
        StubProtocol.answer = { req in
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
            #expect(req.httpMethod == "GET")
            return .success((201, ["X-Thing": "1"], Data("hello".utf8)))
        }
        let r = try await transport().send(HTTPRequest(url: testServer, headers: ["Authorization": "Bearer t"]))
        #expect(r.status == 201)
        #expect(r.header("x-thing") == "1")
        #expect(String(decoding: r.body, as: UTF8.self) == "hello")
    }

    @Test func urlSessionTransportReportsOffline() async {
        StubProtocol.answer = { _ in .failure(URLError(.notConnectedToInternet)) }
        do {
            _ = try await transport().send(HTTPRequest(url: testServer))
            Issue.record("expected a failure")
        } catch let e as TransportError {
            #expect(e.isOffline)
        } catch {
            Issue.record("unexpected \(error)")
        }
        StubProtocol.answer = { _ in .failure(URLError(.badServerResponse)) }
        do {
            _ = try await transport().send(HTTPRequest(url: testServer))
            Issue.record("expected a failure")
        } catch let e as TransportError {
            #expect(!e.isOffline)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func ephemeralSessionKeepsNothing() {
        let t = URLSessionTransport.ephemeral(timeout: 12)
        #expect(t.session.configuration.timeoutIntervalForRequest == 12)
        #expect(t.session.configuration.httpShouldSetCookies == false)
        #expect(URLSessionTransport().session === URLSession.shared)
    }
}

@Suite struct APIErrorTests {
    @Test func wordsForEveryCase() {
        let p = Problem(title: "T", status: 422, code: "c", detail: "D", hint: "H")
        let cases: [APIError] = [.signedOut, .notFound(p), .notFound(Problem()), .problem(p), .problem(Problem()), .offline(""),
                                 .offline("down"), .unreadable("bad"), .notLoregraph("nope")]
        for c in cases {
            #expect(!c.title.isEmpty)
            #expect(!c.message.isEmpty)
        }
        #expect(APIError.problem(p).title == "T")
        #expect(APIError.problem(Problem()).title == "The server refused the request")
        #expect(APIError.problem(Problem(title: "Only")).message == "Only")
        #expect(APIError.notFound(Problem()).message.contains("can't see"))
        #expect(APIError.offline("").message.contains("still here"))
        #expect(APIError.offline("down").message == "down")
        #expect(APIError.notFound(p).hint == "H")
        #expect(APIError.offline("").hint != nil)
        #expect(APIError.unreadable("x").hint != nil)
        #expect(APIError.signedOut.hint == nil)
        #expect(APIError.offline("").isOffline)
        #expect(!APIError.signedOut.isOffline)
    }

    @Test func readsFailedAnswers() {
        #expect(APIError.from(status: 401, body: Data()) == .signedOut)
        if case .notFound(let p) = APIError.from(status: 404, body: Fixture.data("not-found")) {
            #expect(p.status == 404)
        } else {
            Issue.record("not a 404")
        }
        if case .problem(let p) = APIError.from(status: 503, body: Data()) {
            #expect(p.title == "The server had a problem")
            #expect(p.detail == "Try again in a moment.")
        } else {
            Issue.record("not a problem")
        }
        if case .problem(let p) = APIError.from(status: 422, body: Fixture.data("dates-convert-bad")) {
            #expect(p.status == 422)
            #expect(p.title != nil)
        } else {
            Issue.record("not a problem")
        }
        if case .problem(let p) = APIError.from(status: 400, body: Data("{}".utf8)) {
            #expect(p.title == "The server refused the request")
            #expect(p.detail == nil)
        } else {
            Issue.record("not a problem")
        }
    }

    @Test func codersUseSnakeCase() throws {
        let data = try JSONCoding.encoder.encode(Problem(title: "a", detail: "b"))
        #expect(String(decoding: data, as: UTF8.self).contains("\"detail\""))
        let back = try JSONCoding.decoder.decode(Problem.self, from: Data(#"{"request_id":"r"}"#.utf8))
        #expect(back.requestId == "r")
    }
}

@Suite struct EndpointTests {
    @Test func buildsAddressesWithWorldAndView() {
        let view = ViewState(asOf: 1020.5, viewpoint: .init(ref: "dirk", title: "Dirk"), calendar: "lc", viewAs: .public)
        let url = API.entity("dirk").url(base: testServer, world: "main", view: view)
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(c.path == "/api/v1/entities/dirk")
        let names = c.queryItems!.map(\.name)
        #expect(names == ["detail", "include", "include", "include", "as_of", "viewpoint", "calendar", "view_as", "world"])
        #expect(c.queryItems!.first { $0.name == "as_of" }?.value == "1020.5")
    }

    @Test func leavesOutViewAndWorldWhenNotWanted() {
        let url = API.me().url(base: URL(string: "https://x.test/base/")!, world: "main", view: ViewState(asOf: 1))
        #expect(url.absoluteString == "https://x.test/base/api/v1/me")
        let worlds = API.worlds().url(base: testServer, world: "w", view: .default)
        #expect(worlds.query == nil)
    }

    @Test func cacheKeysIgnoreTheServerAndQueryOrder() {
        let a = Endpoint<JSONValue>("/x", query: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")])
        let b = Endpoint<JSONValue>("/x", query: [URLQueryItem(name: "a", value: "1"), URLQueryItem(name: "b", value: "2")])
        #expect(a.cacheKey(world: "w", view: .default) == b.cacheKey(world: "w", view: .default))
        #expect(a.cacheKey(world: "w", view: .default) == "/api/v1/x?a=1&b=2&world=w")
        #expect(Endpoint<JSONValue>("/y", worldScoped: false).cacheKey(world: "w", view: .default) == "/api/v1/y")
    }

    @Test func encodesRefsAndValues() {
        let url = API.entity("a b/c").url(base: testServer, world: nil, view: .default)
        #expect(url.path.contains("a%20b%2Fc") || url.absoluteString.contains("a%20b%2Fc"))
        let s = API.search("ford & co", types: [.event, .location]).url(base: testServer, world: nil, view: .default)
        #expect(s.absoluteString.contains("q=ford%20%26%20co"))
        #expect(s.absoluteString.contains("types=event&types=location"))
    }

    @Test func everyReadHasItsPath() {
        func path<T>(_ e: Endpoint<T>) -> String { e.url(base: testServer, world: "w", view: .default).path }
        func query<T>(_ e: Endpoint<T>) -> String { e.url(base: testServer, world: "w", view: .default).query ?? "" }
        #expect(path(API.about()) == "/api/v1/about")
        #expect(query(API.historyHead()).contains("limit=1"))
        #expect(path(API.pageHistory("dirk")) == "/api/v1/entities/dirk/history")
        #expect(query(API.entities(type: .individual, kind: "k", category: "c", sort: "updated", cursor: "x", limit: 5))
            == "type=individual&kind=k&category=c&sort=updated&cursor=x&limit=5&world=w")
        #expect(query(API.preview("dirk")).contains("sections=lead"))
        #expect(query(API.backlinks("dirk", cursor: "n")).contains("cursor=n"))
        #expect(path(API.views()) == "/api/v1/views")
        #expect(query(API.search("q", cursor: "c")).contains("cursor=c"))
        #expect(query(API.suggest("la", types: [.location], limit: 3)).contains("mode=suggest&limit=3&types=location"))
        #expect(query(API.statements(entity: "dirk", predicate: "p", family: "f", cursor: "c")).contains("predicate=p&family=f"))
        #expect(path(API.statement("s1")) == "/api/v1/statements/s1")
        #expect(path(API.whoKnows("s1")) == "/api/v1/statements/s1/who-knows")
        #expect(path(API.accounts("b")) == "/api/v1/entities/b/accounts")
        #expect(query(API.compare("b")).contains("ref=b"))
        #expect(query(API.beliefs(of: "fenn")).contains("include_overridden=true"))
        #expect(query(API.beliefs(of: "fenn", includeOverridden: false)) == "world=w")
        #expect(path(API.lineage("b1")) == "/api/v1/beliefs/b1/lineage")
        #expect(query(API.holders(question: "k")).contains("key=k"))
        #expect(path(API.factionTree("t")) == "/api/v1/factions/t/tree")
        #expect(query(API.memberships(group: "t")).contains("group=t"))
        #expect(query(API.timeline(about: ["a", "b"], from: "1000", to: "1100", lanes: "type", claims: true, cursor: "c"))
            == "about=a&about=b&from=1000&to=1100&lanes=type&claims=true&limit=500&cursor=c&world=w")
        #expect(query(API.eras()).contains("limit=1"))
        #expect(query(API.familyTree("dirk", up: 3, down: 1, mode: "ancestors", account: "x"))
            == "up=3&down=1&mode=ancestors&account=x&world=w")
        #expect(query(API.kinship("a", "b")).contains("a=a&b=b"))
        #expect(query(API.neighbourhood(roots: ["dirk"], depth: 2, families: ["kinship"], types: [.individual], claims: true, maxNodes: 9))
            == "roots=dirk&depth=2&families=kinship&types=individual&claims=all&max_nodes=9&world=w")
        #expect(query(API.paths(from: "a", to: "b")).contains("from=a&to=b"))
        #expect(path(API.mapLayers()) == "/api/v1/map/layers")
        #expect(path(API.mapVersion()) == "/api/v1/map/version")
        #expect(query(API.placesAt(lon: 1, lat: 2)).contains("lon=1.00000&lat=2.00000"))
        #expect(query(API.distance(["1,2", "3,4"])).contains("waypoints=1,2;3,4"))
        #expect(query(API.features(layers: ["events"], bbox: (1, 2, 3, 4), zoom: 5, windowYears: 10, question: "q"))
            == "layers=events&bbox=1.00000&bbox=2.00000&bbox=3.00000&bbox=4.00000&zoom=5&window_years=10&question=q&limit=2000&world=w")
        #expect(query(API.shapes(of: "lampton")).contains("refs=lampton"))
        #expect(query(API.territories(bbox: (1, 2, 3, 4), zoom: 2)).contains("zoom=2"))
        #expect(query(API.convertDate("spring 1020")).contains("text=spring%201020"))
    }

    @Test func helpersDropEmptyValues() {
        #expect(item("a", String?.none) == nil)
        #expect(item("a", "") == nil)
        #expect(item("a", Int?.none) == nil)
        #expect(item("a", false) == nil)
        #expect(items("a", nil).isEmpty)
        #expect(items("a", ["", "x"]).count == 1)
        #expect(segment("kind:key") == "kind:key")
    }
}

@Suite struct ViewStateTests {
    @Test func queryItemsCarryTheView() {
        #expect(ViewState.default.queryItems.isEmpty)
        #expect(ViewState.default.isDefault)
        let v = ViewState(asOf: 1020, viewpoint: .init(ref: "dirk", title: "Dirk"), calendar: "lc", viewAs: .restricted)
        #expect(v.queryItems.map(\.value) == ["1020", "dirk", "lc", "restricted"])
        #expect(ViewState(viewAs: .designer).queryItems.isEmpty)
        #expect(!v.isDefault)
    }

    @Test func effectiveLevelNeverRaisesTheCeiling() {
        #expect(ViewState().effectiveLevel(ceiling: .restricted) == .restricted)
        #expect(ViewState(viewAs: .public).effectiveLevel(ceiling: .designer) == .public)
        #expect(ViewState(viewAs: .designer).effectiveLevel(ceiling: .restricted) == .restricted)
    }

    @Test func bannerSentence() {
        #expect(ViewState.default.banner() == nil)
        #expect(ViewState(viewAs: .designer).banner() == nil)
        let v = ViewState(asOf: 1020.5, asOfLabel: "summer YV 1020", viewpoint: .init(ref: "dirk", title: "Dirk"), calendar: "lc",
                          viewAs: .public)
        #expect(v.banner(calendarName: "Lampton count") == "As of summer YV 1020, through Dirk's eyes, dates in Lampton count, shown as Public.")
        #expect(ViewState(asOf: 1020).banner() == "As of YV 1020.")
        #expect(ViewState(viewpoint: .init(ref: "x", title: "Ines")).banner() == "Through Ines' eyes.")
        #expect(ViewState(calendar: "lc").banner() == "Dates in lc.")
    }

    @Test func yearText() {
        #expect(ViewState.yearText(1020) == "1020")
        #expect(ViewState.yearText(1020.25) == "1020.25")
        #expect(ViewState.yearText(1020.4144) == "1020.414")
        #expect(ViewState.yearText(1020.0001) == "1020")
    }

    @Test func newWorldKeepsOnlyThePreviewLevel() {
        let v = ViewState(asOf: 1, viewpoint: .init(ref: "a", title: "A"), calendar: "c", viewAs: .public).forNewWorld()
        #expect(v == ViewState(viewAs: .public))
    }
}

@Suite struct PersistenceTests {
    @Test func memoryStoreKeepsValues() {
        let s = MemoryKeyValueStore()
        s.setValue(AppSettings(requireUnlock: true, baseMap: .relief), forKey: "s")
        #expect(s.value(AppSettings.self, forKey: "s") == AppSettings(requireUnlock: true, baseMap: .relief))
        s.setValue(AppSettings?.none, forKey: "s")
        #expect(s.data(forKey: "s") == nil)
        #expect(s.value(AppSettings.self, forKey: "missing") == nil)
    }

    @Test func userDefaultsStoreKeepsValues() {
        let name = "lgk-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let s = UserDefaultsStore(defaults)
        s.set(Data([1, 2]), forKey: "k")
        #expect(s.data(forKey: "k") == Data([1, 2]))
        s.set(nil, forKey: "k")
        #expect(s.data(forKey: "k") == nil)
        _ = UserDefaultsStore()
    }

    @Test func readerFoldersDifferByServerReaderAndLevel() {
        let a = ReaderIdentity(server: testServer, id: "1", name: "A", ceiling: .designer)
        var b = a
        b.ceiling = .public
        #expect(a.folder.count == 24)
        #expect(a.folder != b.folder)
        #expect(a.folder == ReaderIdentity(server: testServer, id: "1", name: "Other name", ceiling: .designer).folder)
    }

    @Test func readingStateStartsEmpty() throws {
        var s = ReadingState()
        #expect(s.worlds.isEmpty && s.views.isEmpty && s.recentSearches.isEmpty)
        s.cameras["w"] = .init(centre: LonLat(1, 2), zoom: 3, layers: ["places"])
        let back = try JSONDecoder().decode(ReadingState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(ReadingState.recentLimit == 20)
    }
}
