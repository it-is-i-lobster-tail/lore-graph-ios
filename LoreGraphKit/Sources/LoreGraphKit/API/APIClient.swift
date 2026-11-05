import Foundation

/// A decoded answer with the bytes it came from (the cache stores the bytes).
public struct Fetched<Value: Sendable>: Sendable {
    public var value: Value
    public var data: Data
}

/// Reads from one loregraph server as the signed-in reader. Sends the token, retries once
/// after a refresh on 401, and turns failures into `APIError`.
public struct APIClient: Sendable {
    public let server: URL
    let transport: HTTPTransport
    let auth: AuthSession
    /// Told when the sign-in has ended for good (the app shows the sign-in screen).
    let onSignedOut: (@Sendable () -> Void)?

    public init(server: URL, transport: HTTPTransport, auth: AuthSession, onSignedOut: (@Sendable () -> Void)? = nil) {
        self.server = server
        self.transport = transport
        self.auth = auth
        self.onSignedOut = onSignedOut
    }

    /// GET one endpoint in a world, through a view.
    public func get<T>(_ endpoint: Endpoint<T>, world: String?, view: ViewState = .default) async throws -> Fetched<T> {
        let url = endpoint.url(base: server, world: world, view: view)
        let response = try await send(url: url, accept: "application/json")
        guard (200..<300).contains(response.status) else {
            throw APIError.from(status: response.status, body: response.body)
        }
        return Fetched(value: try Self.decode(T.self, from: response.body), data: response.body)
    }

    /// Sends a change (a reading mark, a comment) in a world. Never cached; the answer is decoded.
    public func send<T>(_ change: Change<T>, world: String?) async throws -> T {
        let url = change.url(base: server, world: world)
        let response = try await send(url: url, accept: "application/json", method: change.method, body: change.bodyData,
                                      extra: change.idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:])
        guard (200..<300).contains(response.status) else {
            throw APIError.from(status: response.status, body: response.body)
        }
        return try Self.decode(T.self, from: response.body)
    }

    /// Bytes from the server (tiles, images), with the token. 204 comes back as empty data.
    public func bytes(path: String, query: [URLQueryItem] = [], world: String?) async throws -> Data? {
        let ep = Endpoint<JSONValue>(path, query: query, readsView: false, worldScoped: world != nil, freshness: .map)
        let response = try await send(url: ep.url(base: server, world: world, view: .default), accept: "*/*")
        if response.status == 204 { return nil }
        guard (200..<300).contains(response.status) else {
            throw APIError.from(status: response.status, body: response.body)
        }
        return response.body
    }

    /// Bytes from any address on this server (media files), with the token.
    public func bytes(at url: URL) async throws -> Data {
        guard url.host == server.host else {
            // never send the token anywhere else
            let response = try await transportSend(HTTPRequest(url: url))
            guard (200..<300).contains(response.status) else { throw APIError.from(status: response.status, body: response.body) }
            return response.body
        }
        let response = try await send(url: url, accept: "*/*")
        guard (200..<300).contains(response.status) else { throw APIError.from(status: response.status, body: response.body) }
        return response.body
    }

    private func send(url: URL, accept: String, method: String = "GET", body: Data? = nil,
                      extra: [String: String] = [:]) async throws -> HTTPResponse {
        do {
            return try await sendSigned(url: url, accept: accept, method: method, body: body, extra: extra)
        } catch APIError.signedOut {
            onSignedOut?()
            throw APIError.signedOut
        }
    }

    private func sendSigned(url: URL, accept: String, method: String, body: Data?, extra: [String: String]) async throws -> HTTPResponse {
        let token = try await auth.accessToken()
        var response = try await transportSend(request(url, token: token, accept: accept, method: method, body: body, extra: extra))
        if response.status == 401 {
            let fresh = try await auth.tokenAfterUnauthorized(token)
            response = try await transportSend(request(url, token: fresh, accept: accept, method: method, body: body, extra: extra))
            if response.status == 401 { throw APIError.signedOut }
        }
        return response
    }

    private func request(_ url: URL, token: String, accept: String, method: String = "GET", body: Data? = nil,
                         extra: [String: String] = [:]) -> HTTPRequest {
        var headers = extra.merging(["Authorization": "Bearer \(token)", "Accept": accept]) { _, new in new }
        if body != nil { headers["Content-Type"] = "application/json" }
        return HTTPRequest(method: method, url: url, headers: headers, body: body)
    }

    private func transportSend(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            return try await transport.send(request)
        } catch let e as TransportError {
            throw APIError.offline(e.isOffline ? "" : e.message)
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.unreadable(describe(error))
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "Missing \(key.stringValue) at \(path(ctx))."
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "Unexpected value at \(path(ctx)): \(ctx.debugDescription)"
        @unknown default: return "The answer had an unexpected shape."
        }
    }
}
