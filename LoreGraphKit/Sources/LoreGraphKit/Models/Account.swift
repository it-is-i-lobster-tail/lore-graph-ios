import Foundation

/// `GET /api/v1/me`: who is signed in and what the token may do.
public struct Me: Codable, Hashable, Sendable {
    public var id: String
    public var email: String?
    public var displayName: String?
    public var role: String?
    public var scopes: [String]
    public var ceiling: Visibility
    public var writeMode: String?
    public var via: String?
    public var version: String?
    public var preferences: [String: JSONValue]?

    /// Whether designer-only material can reach this device (the app-switcher blur, F-1.6).
    public var seesSecrets: Bool { ceiling == .designer }

    /// The preferred calendar from the web app's settings, if not the plain default.
    public var preferredCalendar: String? {
        guard let cal = preferences?["calendar"]?.string, !cal.isEmpty, cal != "yv" else { return nil }
        return cal
    }
}

/// A world as `GET /api/v1/worlds` lists it (ADR D-73).
public struct World: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var description: String?
    public var isDefault: Bool?
    public var visibility: Visibility?
    public var pages: Int?
    public var present: String?
    public var uiUrl: String?

    public var id: String { key }

    public init(key: String, name: String, description: String? = nil, isDefault: Bool? = nil,
                visibility: Visibility? = nil, pages: Int? = nil, present: String? = nil) {
        self.key = key
        self.name = name
        self.description = description
        self.isDefault = isDefault
        self.visibility = visibility
        self.pages = pages
        self.present = present
    }
}

public struct WorldList: Codable, Hashable, Sendable {
    public var current: String?
    public var worlds: [World]
}

/// `GET /api/v1/about`: the world's present, calendars and counts (F-2.3).
public struct About: Codable, Hashable, Sendable {
    public struct WorldRef: Codable, Hashable, Sendable {
        public var key: String
        public var name: String
        public var isDefault: Bool?
    }

    public struct Calendar: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var name: String
        public var abbreviation: String?
        public var kind: String?
        public var `default`: Bool?
        public var id: String { key }
    }

    public struct Counts: Codable, Hashable, Sendable {
        public var pages: [String: Int]?
        public var statements: Int?
        public var beliefs: Int?

        public var totalPages: Int { pages?.values.reduce(0, +) ?? 0 }
    }

    public var world: WorldRef?
    public var present: DateSpan?
    public var calendars: [Calendar]?
    public var counts: Counts?
    public var version: String?
    public var ceiling: Visibility?

    /// The in-world present as a number (spring YV 1131 in the first world).
    public var presentYear: Double { present?.from ?? 1131.25 }
}

/// The newest revision the reader can see (`GET /api/v1/history?limit=1`), the freshness mark
/// of every cached answer in the world: ids only ever grow.
public struct HistoryHead: Codable, Hashable, Sendable {
    public struct Group: Codable, Hashable, Sendable {
        public var revisions: [Revision]
    }

    public struct Revision: Codable, Hashable, Sendable {
        public var id: Int64
        public var at: String?
        public var table: String?
        public var op: String?
        public var entity: EntityCard?
        public var actor: String?
    }

    public var groups: [Group]

    public var newest: Revision? { groups.flatMap(\.revisions).max { $0.id < $1.id } }
}

/// `GET /api/v1/entities/{ref}/history`: past revisions of one page (read only).
public struct PageHistory: Codable, Hashable, Sendable {
    public var groups: [HistoryHead.Group]
    public var nextCursor: String?
}

/// `GET /api/v1/map/version`.
public struct MapVersion: Codable, Hashable, Sendable {
    public var version: Int
    public var changedAt: String?
}

/// The server's OAuth metadata (RFC 8414), read to check an address is a loregraph server.
public struct AuthorizationServerMetadata: Codable, Hashable, Sendable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var revocationEndpoint: String?
    public var scopesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?
    public var authorizationResponseIssParameterSupported: Bool?
}

/// A token endpoint answer (RFC 6749 5.1).
public struct TokenResponse: Codable, Hashable, Sendable {
    public var accessToken: String
    public var tokenType: String?
    public var expiresIn: Double?
    public var refreshToken: String?
    public var scope: String?
}
