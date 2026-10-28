import Foundation

/// The server's problem details (RFC 9457) as loregraph writes them, with its hint.
public struct Problem: Codable, Hashable, Sendable {
    public struct FieldError: Codable, Hashable, Sendable {
        public var field: String?
        public var message: String?
    }

    public var type: String?
    public var title: String?
    public var status: Int?
    public var code: String?
    public var detail: String?
    public var hint: String?
    public var errors: [FieldError]?
    public var requestId: String?

    public init(title: String? = nil, status: Int? = nil, code: String? = nil, detail: String? = nil, hint: String? = nil) {
        self.title = title
        self.status = status
        self.code = code
        self.detail = detail
        self.hint = hint
    }
}

/// Everything that can go wrong reading from the server, in words a reader can act on (F-11.6).
public enum APIError: Error, Sendable, Hashable {
    /// The sign-in ended or was revoked: sign in again.
    case signedOut
    /// Missing, or not visible at your level: the server answers the same for both.
    case notFound(Problem)
    /// The server refused the request and said why.
    case problem(Problem)
    /// No connection; cached pages stay readable.
    case offline(String)
    /// The answer did not have the expected shape (a server newer or older than the app).
    case unreadable(String)
    /// Not a loregraph server.
    case notLoregraph(String)

    public var title: String {
        switch self {
        case .signedOut: "Signed out"
        case .notFound: "Not found"
        case .problem(let p): p.title ?? "The server refused the request"
        case .offline: "You're offline"
        case .unreadable: "Couldn't read the answer"
        case .notLoregraph: "Not a loregraph server"
        }
    }

    public var message: String {
        switch self {
        case .signedOut: "Your sign-in has ended. Sign in again to keep reading."
        case .notFound(let p): p.detail ?? "There's nothing here, or you can't see it."
        case .problem(let p): p.detail ?? p.title ?? "Something went wrong."
        case .offline(let m): m.isEmpty ? "Pages you've opened before are still here." : m
        case .unreadable(let m): m
        case .notLoregraph(let m): m
        }
    }

    public var hint: String? {
        switch self {
        case .notFound(let p), .problem(let p): p.hint
        case .offline: "Pull down to try again when you're back online."
        case .unreadable: "Check that the app and the server are both up to date."
        default: nil
        }
    }

    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    /// Reads a failed answer: problem details when the server sent them.
    static func from(status: Int, body: Data) -> APIError {
        let problem = (try? JSONCoding.decoder.decode(Problem.self, from: body)) ?? Problem(status: status)
        switch status {
        case 401: return .signedOut
        case 404: return .notFound(problem)
        default:
            var p = problem
            if p.title == nil { p.title = status >= 500 ? "The server had a problem" : "The server refused the request" }
            if p.detail == nil && status >= 500 { p.detail = "Try again in a moment." }
            return .problem(p)
        }
    }
}

/// The JSON coders the whole app uses (snake_case on the wire).
public enum JSONCoding {
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
