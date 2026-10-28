import Foundation

/// Hands out a current access token. Refreshes quietly before expiry and after a 401, one
/// refresh at a time: the server rotates refresh tokens, so two refreshes racing would spend
/// the same token twice and sign the reader out.
public actor AuthSession {
    public private(set) var credentials: Credentials?
    let store: TokenStore
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    private var refreshing: Task<Credentials, Error>?

    public init(store: TokenStore, transport: HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.transport = transport
        self.now = now
        self.credentials = try? store.load()
    }

    public var isSignedIn: Bool { credentials != nil }

    public func signIn(_ credentials: Credentials) throws {
        try store.save(credentials)
        self.credentials = credentials
    }

    /// Forgets the credentials here and revokes them on the server (best effort).
    public func signOut() async {
        let old = credentials
        credentials = nil
        refreshing?.cancel()
        refreshing = nil
        try? store.delete()
        if let old { await TokenRevoker.revoke(old, transport: transport) }
    }

    /// A token to send now, refreshed first if it is about to expire.
    public func accessToken() async throws -> String {
        guard let c = credentials else { throw APIError.signedOut }
        if c.needsRefresh(now: now()) {
            return try await refresh(from: c).accessToken
        }
        return c.accessToken
    }

    /// After a 401 with `token`: refresh once (unless another call already has) and return the
    /// new token, or sign out when the server says the grant is gone.
    public func tokenAfterUnauthorized(_ token: String) async throws -> String {
        guard let c = credentials else { throw APIError.signedOut }
        if c.accessToken != token { return c.accessToken }   // someone else refreshed meanwhile
        guard c.kind == .oauth, c.refreshToken != nil else {
            await expire()
            throw APIError.signedOut
        }
        return try await refresh(from: c).accessToken
    }

    private func refresh(from c: Credentials) async throws -> Credentials {
        if let refreshing { return try await refreshing.value }
        let transport = self.transport
        let now = self.now
        let task = Task<Credentials, Error> {
            guard let endpoint = c.tokenEndpoint else { throw APIError.signedOut }
            let meta = AuthorizationServerMetadata(issuer: c.server.absoluteString, authorizationEndpoint: "",
                                                   tokenEndpoint: endpoint.absoluteString,
                                                   revocationEndpoint: c.revocationEndpoint?.absoluteString)
            return try await OAuthClient(server: c.server, metadata: meta, transport: transport, now: now).refresh(c)
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            try? store.save(fresh)
            credentials = fresh
            return fresh
        } catch APIError.signedOut {
            await expire()
            throw APIError.signedOut
        }
    }

    /// The grant is gone: drop it without calling the server.
    private func expire() async {
        credentials = nil
        try? store.delete()
    }
}
