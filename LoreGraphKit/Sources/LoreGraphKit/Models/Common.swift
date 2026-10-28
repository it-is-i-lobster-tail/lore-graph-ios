import Foundation

/// Who outside the world may read a row (DESIGN.md 4.8). Ordered: public < restricted < designer.
public enum Visibility: String, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case `public`, restricted, designer

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        // an unknown level is treated as the most private, never as public
        self = Visibility(rawValue: raw) ?? .designer
    }

    var rank: Int {
        switch self {
        case .public: 0
        case .restricted: 1
        case .designer: 2
        }
    }

    public static func < (a: Visibility, b: Visibility) -> Bool { a.rank < b.rank }

    /// The words shown beside a mark, so colour is never the only signal.
    public var label: String {
        switch self {
        case .public: "Public"
        case .restricted: "Restricted"
        case .designer: "Designer only"
        }
    }
}

/// A canon status (draft, proposed, approved, author_canon, retired). Open, so a new status
/// from a newer server still decodes.
public struct Canon: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let draft = Canon(rawValue: "draft")
    public static let proposed = Canon(rawValue: "proposed")
    public static let approved = Canon(rawValue: "approved")
    public static let authorCanon = Canon(rawValue: "author_canon")
    public static let retired = Canon(rawValue: "retired")

    /// Approved and author canon read as plain canon; anything else gets a chip.
    public var isCanon: Bool { self == .approved || self == .authorCanon }

    public var label: String {
        switch rawValue {
        case "author_canon": "Author canon"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
}

/// The eight fixed entity types (DESIGN.md 4.2).
public enum EntityType: String, Codable, Sendable, CaseIterable, Hashable {
    case event, story, tale, faction, individual, location, item, misc

    public init(from decoder: Decoder) throws {
        self = EntityType(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .misc
    }

    public var label: String {
        switch self {
        case .event: "Event"
        case .story: "Story"
        case .tale: "Tale"
        case .faction: "Faction"
        case .individual: "Person"
        case .location: "Place"
        case .item: "Item"
        case .misc: "Other"
        }
    }

    public var plural: String {
        switch self {
        case .event: "Events"
        case .story: "Stories"
        case .tale: "Tales"
        case .faction: "Factions"
        case .individual: "People"
        case .location: "Places"
        case .item: "Items"
        case .misc: "Other"
        }
    }

    /// An SF Symbol for the type, shared by lists, cards and the graph legend.
    public var symbol: String {
        switch self {
        case .event: "diamond.fill"
        case .story: "book.closed.fill"
        case .tale: "bubble.left.and.text.bubble.right.fill"
        case .faction: "shield.lefthalf.filled"
        case .individual: "person.fill"
        case .location: "mappin.and.ellipse"
        case .item: "cube.fill"
        case .misc: "square.grid.2x2.fill"
        }
    }
}

/// A date or span in fractional YV years, as the server writes it (`from` inclusive, `to`
/// exclusive), with its precision, a label in the requested calendar and, for "c." dates, the
/// wider envelope (`outer`).
public struct DateSpan: Codable, Hashable, Sendable {
    public struct Outer: Codable, Hashable, Sendable {
        public var from: Double?
        public var to: Double?
    }

    public var from: Double?
    public var to: Double?
    public var precision: String?
    public var label: String?
    public var formatted: String?
    public var outer: Outer?

    public init(from: Double?, to: Double?, precision: String? = nil, label: String? = nil,
                formatted: String? = nil, outer: Outer? = nil) {
        self.from = from
        self.to = to
        self.precision = precision
        self.label = label
        self.formatted = formatted
        self.outer = outer
    }

    /// The words to show: the label in the chosen calendar, else the formatted numbers.
    public var text: String { label ?? formatted ?? "" }

    /// Whether this is a "c." date with a faint outer envelope.
    public var isCirca: Bool { outer != nil }

    /// The extent to draw, envelope included.
    public var drawnRange: ClosedRange<Double>? {
        let lo = outer?.from ?? from ?? to
        let hi = outer?.to ?? to ?? from
        guard let lo, let hi else { return nil }
        return min(lo, hi)...max(lo, hi)
    }

    /// Whether the span holds the year (open ends run on for ever).
    public func contains(_ year: Double) -> Bool {
        if let from, year < from { return false }
        if let to, year >= to { return false }
        return true
    }
}

/// The small card every answer uses for a page: enough to list it and open it.
public struct EntityCard: Codable, Hashable, Sendable, Identifiable {
    public var ref: String
    public var id: String
    public var title: String
    public var type: EntityType?
    public var kind: String?
    public var visibility: Visibility?
    public var canon: Canon?
    public var shortDescription: String?
    public var displayTitle: String?
    public var nameHere: String?

    public init(ref: String, id: String, title: String, type: EntityType? = nil, kind: String? = nil,
                visibility: Visibility? = nil, canon: Canon? = nil, shortDescription: String? = nil) {
        self.ref = ref
        self.id = id
        self.title = title
        self.type = type
        self.kind = kind
        self.visibility = visibility
        self.canon = canon
        self.shortDescription = shortDescription
    }

    /// The name to show: the viewpoint's name for the page when there is one.
    public var shownTitle: String { nameHere ?? displayTitle ?? title }
}

/// A kind key such as `event.battle` read as words ("Battle").
public func kindLabel(_ kind: String?) -> String? {
    guard let kind, !kind.isEmpty else { return nil }
    let last = kind.split(separator: ".").last.map(String.init) ?? kind
    let words = last.replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
}

/// One page of a list answer.
public struct Page<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var items: [Item]
    public var nextCursor: String?
    public var total: Int?
}
