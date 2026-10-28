import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP exchange, kept small so the client can be tested without a network.
public struct HTTPRequest: Sendable, Hashable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }

    /// A form-encoded POST (the token and revocation endpoints).
    public static func form(_ url: URL, _ fields: [(String, String)]) -> HTTPRequest {
        let body = fields.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
        return HTTPRequest(method: "POST", url: url,
                           headers: ["Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"],
                           body: Data(body.utf8))
    }

    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public struct HTTPResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A header by name, ignoring case.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Sends requests. The app uses `URLSessionTransport`; tests use a scripted one.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The network failed before any answer came back (offline, timed out, TLS).
public struct TransportError: Error, Sendable, Hashable {
    public var message: String
    public var isOffline: Bool

    public init(message: String, isOffline: Bool) {
        self.message = message
        self.isOffline = isOffline
    }
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session with no shared cookies or URL cache: the app keeps its own cache and sends the
    /// token itself, so nothing about the reader is stored by the system.
    public static func ephemeral(timeout: TimeInterval = 30) -> URLSessionTransport {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, response) = try await session.data(for: r)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError(message: "The server did not answer over HTTP.", isOffline: false)
            }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields {
                if let k = k as? String { headers[k] = "\(v)" }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let e as TransportError {
            throw e
        } catch let e as URLError {
            throw TransportError(message: e.localizedDescription, isOffline: Self.offlineCodes.contains(e.code))
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
    ]
}
