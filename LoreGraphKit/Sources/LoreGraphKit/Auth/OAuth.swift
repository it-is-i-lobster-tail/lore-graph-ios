import Foundation

/// What the app holds to read as someone: an OAuth token pair from the built-in iOS client
/// (ADR D-74) or a personal token pasted in (F-1.3). Kept in the Keychain, never in files.
public struct Credentials: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case oauth, personal }

    public var kind: Kind
    public var server: URL
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?
    public var tokenEndpoint: URL?
    public var revocationEndpoint: URL?

    public init(kind: Kind, server: URL, accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                scope: String? = nil, tokenEndpoint: URL? = nil, revocationEndpoint: URL? = nil) {
        self.kind = kind
        self.server = server
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    /// Whether the access token should be refreshed before use (a minute's grace).
    public func needsRefresh(now: Date) -> Bool {
        guard kind == .oauth, refreshToken != nil, let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }

    public var scopes: [String] { (scope ?? "").split(separator: " ").map(String.init) }
}

/// PKCE (RFC 7636): a random verifier and its S256 challenge.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Digest.base64URL(Digest.sha256(Data(verifier.utf8)))
    }

    public static func make() -> PKCE {
        PKCE(verifier: Digest.base64URL(Digest.randomBytes(32)))
    }
}

/// A sign-in in progress: the address for the browser sheet and what to check on return.
public struct AuthorizationRequest: Sendable, Hashable {
    public let url: URL
    public let state: String
    public let pkce: PKCE
    public let resource: String
}

/// The OAuth side of signing in with the server's own page (F-1.2): discovery, the authorize
/// address, the callback, the code exchange, refresh with rotation, and revocation.
public struct OAuthClient: Sendable {
    public static let clientID = "loregraph-ios"
    public static let redirectURI = "loregraph://oauth/callback"
    public static let callbackScheme = "loregraph"

    public let server: URL
    public let metadata: AuthorizationServerMetadata
    let transport: HTTPTransport
    let now: @Sendable () -> Date

    public init(server: URL, metadata: AuthorizationServerMetadata, transport: HTTPTransport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.server = server
        self.metadata = metadata
        self.transport = transport
        self.now = now
    }

    /// The REST API is the only resource the app's tokens are for.
    public var resource: String { Self.normalised(server).absoluteString + "/api" }

    /// Reads the server's OAuth metadata and checks it is a loregraph server at that address.
    public static func discover(server: URL, transport: HTTPTransport) async throws -> OAuthClient {
        let base = normalised(server)
        let url = base.appendingPathComponent(".well-known/oauth-authorization-server")
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, headers: ["Accept": "application/json"]))
        } catch let e as TransportError {
            throw e.isOffline ? APIError.offline("Can't reach \(base.host ?? base.absoluteString).") : APIError.offline(e.message)
        }
        guard response.status == 200,
              let meta = try? JSONCoding.decoder.decode(AuthorizationServerMetadata.self, from: response.body) else {
            throw APIError.notLoregraph("\(base.host ?? base.absoluteString) didn't answer like a loregraph server. Check the address.")
        }
        guard normalised(URL(string: meta.issuer) ?? base) == base else {
            throw APIError.notLoregraph("The server calls itself \(meta.issuer), not \(base.absoluteString). Use that address instead.")
        }
        guard (meta.codeChallengeMethodsSupported ?? ["S256"]).contains("S256") else {
            throw APIError.notLoregraph("The server doesn't support secure sign-in (PKCE S256).")
        }
        return OAuthClient(server: base, metadata: meta, transport: transport)
    }

    /// An address the user typed, made canonical: https unless http was written, no path, no
    /// trailing slash.
    public static func normalised(_ url: URL) -> URL {
        var text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard var c = URLComponents(string: text) else { return url }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url ?? url
    }

    /// The address for the browser sheet. Asks for reading, the secrets scope (the consent screen
    /// lets the user untick it and pick the ceiling) and a refresh token.
    public func authorizationRequest(pkce: PKCE = .make(), state: String = Digest.base64URL(Digest.randomBytes(16))) -> AuthorizationRequest {
        var c = URLComponents(string: metadata.authorizationEndpoint)!
        c.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: "lore:read lore:secrets offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource),
        ]
        return AuthorizationRequest(url: c.url!, state: state, pkce: pkce, resource: resource)
    }

    /// The code from the callback, after checking the state and the issuer (RFC 9207).
    public func code(from callback: URL, for request: AuthorizationRequest) throws -> String {
        guard callback.scheme == Self.callbackScheme,
              let c = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw APIError.problem(Problem(title: "Sign-in failed", detail: "The sign-in returned to the wrong place."))
        }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard q["state"] == request.state else {
            throw APIError.problem(Problem(title: "Sign-in failed", detail: "The sign-in answer didn't match this request. Try again."))
        }
        if let iss = q["iss"], Self.normalised(URL(string: iss) ?? server) != Self.normalised(URL(string: metadata.issuer) ?? server) {
            throw APIError.problem(Problem(title: "Sign-in failed", detail: "The sign-in answer came from another server."))
        }
        if let error = q["error"] {
            let words: String
            switch error {
            case "access_denied": words = "You chose not to allow the app."
            case "invalid_target": words = "The server refused the app's access to the REST API."
            default: words = q["error_description"] ?? error
            }
            throw APIError.problem(Problem(title: "Sign-in didn't finish", code: error, detail: words))
        }
        guard let code = q["code"], !code.isEmpty else {
            throw APIError.problem(Problem(title: "Sign-in failed", detail: "The server sent no sign-in code."))
        }
        return code
    }

    /// Swaps the code for tokens.
    public func exchange(code: String, request: AuthorizationRequest) async throws -> Credentials {
        try await token([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", Self.redirectURI),
            ("client_id", Self.clientID), ("code_verifier", request.pkce.verifier), ("resource", request.resource),
        ], previous: nil)
    }

    /// A new token pair; the server rotates the refresh token on every use.
    public func refresh(_ credentials: Credentials) async throws -> Credentials {
        guard let rt = credentials.refreshToken else { throw APIError.signedOut }
        return try await token([("grant_type", "refresh_token"), ("refresh_token", rt), ("client_id", Self.clientID),
                                ("resource", resource)], previous: credentials)
    }

    func token(_ fields: [(String, String)], previous: Credentials?) async throws -> Credentials {
        guard let endpoint = URL(string: metadata.tokenEndpoint) else { throw APIError.notLoregraph("No token endpoint.") }
        let response: HTTPResponse
        do {
            response = try await transport.send(.form(endpoint, fields))
        } catch let e as TransportError {
            throw APIError.offline(e.message)
        }
        guard response.status == 200 else {
            if response.status == 400 || response.status == 401 { throw APIError.signedOut }
            throw APIError.from(status: response.status, body: response.body)
        }
        guard let t = try? JSONCoding.decoder.decode(TokenResponse.self, from: response.body) else {
            throw APIError.unreadable("The server's sign-in answer had an unexpected shape.")
        }
        return Credentials(kind: .oauth, server: server, accessToken: t.accessToken,
                           refreshToken: t.refreshToken ?? previous?.refreshToken,
                           expiresAt: t.expiresIn.map { now().addingTimeInterval($0) },
                           scope: t.scope ?? previous?.scope, tokenEndpoint: endpoint,
                           revocationEndpoint: metadata.revocationEndpoint.flatMap(URL.init(string:)))
    }
}

/// Revokes tokens at sign-out (RFC 7009). Best effort: signing out never waits on the network.
public enum TokenRevoker {
    public static func revoke(_ credentials: Credentials, transport: HTTPTransport) async {
        guard credentials.kind == .oauth, let endpoint = credentials.revocationEndpoint else { return }
        for token in [credentials.refreshToken, credentials.accessToken].compactMap({ $0 }) {
            _ = try? await transport.send(.form(endpoint, [("token", token), ("client_id", OAuthClient.clientID)]))
        }
    }
}
