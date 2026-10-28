import Foundation

/// `GET /api/v1/entities/{ref}?detail=full&include=html,media,shapes`: one wiki page.
public struct EntityDetail: Codable, Hashable, Sendable {
    public struct Entity: Codable, Hashable, Sendable {
        public var id: String
        public var ref: String
        public var slug: String?
        public var title: String
        public var displayTitle: String?
        public var type: EntityType
        public var kind: String?
        public var kindLabel: String?
        public var shortDescription: String?
        public var visibility: Visibility
        public var canon: Canon?
        public var version: Int?
        public var lifespan: DateSpan?
        public var attributes: [String: JSONValue]?
        public var deleted: Bool?
        public var breadcrumbs: [Crumb]?

        public var card: EntityCard {
            var c = EntityCard(ref: ref, id: id, title: title, type: type, kind: kind, visibility: visibility,
                               canon: canon, shortDescription: shortDescription)
            c.displayTitle = displayTitle
            return c
        }
    }

    public struct Crumb: Codable, Hashable, Sendable {
        public var ref: String
        public var title: String
    }

    public struct Name: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String?
        public var usedByLabel: String?
        public var eraLabel: String?
        public var tone: String?
        public var approval: String?
        public var visibility: Visibility?
    }

    public struct InfoboxRow: Codable, Hashable, Sendable {
        public struct Value: Codable, Hashable, Sendable {
            public var text: String
            public var ref: String?
            public var statementId: String?
            public var visibility: Visibility?
            public var role: String?
            public var when: String?
        }

        public var label: String
        public var from: String?
        public var values: [Value]
    }

    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public struct Item: Codable, Hashable, Sendable {
            public var label: String?
            public var other: EntityCard?
            public var statementId: String?
            public var valid: DateSpan?
            public var visibility: Visibility?
        }

        public var id: String
        public var key: String
        public var sectionType: String?
        public var heading: String?
        public var level: Int?
        public var visibility: Visibility
        public var canon: Canon?
        public var generated: Bool?
        public var inWorld: Bool?
        public var authorCanon: Bool?
        public var html: String?
        public var items: [Item]?
        public var link: String?

        /// A generated section with nothing in it (no records yet) is left out of the page.
        public var isEmpty: Bool {
            (html ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (items ?? []).isEmpty
        }
    }

    public struct Media: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: String?
        public var title: String?
        public var caption: String?
        public var credit: String?
        public var url: String?
        public var storagePath: String?
        public var mimeType: String?
        public var widthPx: Int?
        public var heightPx: Int?
        public var role: String?
        public var visibility: Visibility?

        public var isImage: Bool { (mimeType ?? "image/").hasPrefix("image/") && kind != "document" }

        /// Where the file is: its own address, or the server's media path (authorised by the token).
        public func address(base: URL) -> URL? {
            if let url, let u = URL(string: url), u.scheme != nil { return u }
            guard let path = storagePath ?? url else { return nil }
            let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return base.appendingPathComponent(trimmed.hasPrefix("media/") ? trimmed : "media/\(trimmed)")
        }
    }

    public struct Shape: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var role: String?
        public var geometry: GeoJSONGeometry?
        public var precision: String?
        public var generation: String?
        public var visibility: Visibility?
    }

    public struct Details: Codable, Hashable, Sendable {
        public struct Anchor: Codable, Hashable, Sendable {
            public var lon: Double
            public var lat: Double
            public var precision: String?
        }

        public var placement: String?
        public var anchor: Anchor?
        public var parentLocation: EntityCard?
        public var teller: EntityCard?
        public var medium: String?
        public var told: DateSpan?
        public var toldAt: EntityCard?
        public var bias: String?
        public var reliability: Int?
        public var when: DateSpan?
        public var place: EntityCard?
    }

    public struct Category: Codable, Hashable, Sendable {
        public var ref: String?
        public var slug: String?
        public var title: String
    }

    public var entity: Entity
    public var names: [Name]?
    public var details: Details?
    public var infobox: [InfoboxRow]?
    public var sections: [Section]?
    public var categories: [Category]?
    public var media: [Media]?
    public var shapes: [Shape]?
    public var asOf: DateSpan?
    public var viewpoint: EntityCard?
    public var redirectedFrom: String?
    public var uiUrl: String?

    /// Sections worth drawing, in the server's order.
    public var shownSections: [Section] { (sections ?? []).filter { !$0.isEmpty } }

    /// Every other name, for "Also known as".
    public var alsoKnownAs: [Name] { (names ?? []).filter { $0.kind != "primary" } }

    /// The point to centre a locator map on: the anchor, else the first shape's centre.
    public var locatorPoint: (lon: Double, lat: Double)? {
        if let a = details?.anchor { return (a.lon, a.lat) }
        for shape in shapes ?? [] {
            if let c = shape.geometry?.centre { return c }
        }
        return nil
    }

    /// The infobox image, if any.
    public var infoboxImage: Media? {
        (media ?? []).first { $0.isImage && ($0.role == "infobox" || $0.role == "portrait") } ?? (media ?? []).first(where: \.isImage)
    }
}

/// A row of `GET /api/v1/entities` (browse, F-4.2).
public struct EntityListItem: Codable, Hashable, Sendable, Identifiable {
    public var ref: String
    public var id: String
    public var title: String
    public var type: EntityType
    public var kind: String?
    public var shortDescription: String?
    public var visibility: Visibility
    public var canon: Canon?
    public var updatedAt: String?
    public var lifespan: DateSpan?

    public var card: EntityCard {
        EntityCard(ref: ref, id: id, title: title, type: type, kind: kind, visibility: visibility, canon: canon,
                   shortDescription: shortDescription)
    }
}

/// `GET /api/v1/entities/{ref}/backlinks` (F-4.11).
public struct Backlinks: Codable, Hashable, Sendable {
    public struct ProseLink: Codable, Hashable, Sendable {
        public var page: EntityCard
        public var section: String?
        public var heading: String?
        public var mentions: Int?
    }

    public struct LinkRow: Codable, Hashable, Sendable {
        public var page: EntityCard
        public var label: String
        public var direction: String?
        public var statementId: String?
        public var claim: Bool?
    }

    public var page: EntityCard
    public var prose: [ProseLink]
    public var statements: [LinkRow]
    public var nextCursor: String?
}

/// `GET /api/v1/views?trails=true`: saved views and trails (F-4.1, F-4.3).
public struct ViewsAndTrails: Codable, Hashable, Sendable {
    public struct SavedView: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var kind: String?
        public var slug: String
        public var title: String
        public var description: String?
        public var visibility: Visibility?
        public var url: String?
    }

    public struct Trail: Codable, Hashable, Sendable, Identifiable {
        public struct Step: Codable, Hashable, Sendable {
            public var position: Double?
            public var ref: String
            public var title: String
            public var sectionKey: String?
            public var noteMd: String?
        }

        public var id: String
        public var slug: String
        public var title: String
        public var descriptionMd: String?
        public var visibility: Visibility?
        public var steps: [Step]
        public var url: String?

        /// The steps before and after a page on this trail, for previous and next.
        public func neighbours(of ref: String) -> (previous: Step?, next: Step?)? {
            guard let i = steps.firstIndex(where: { $0.ref == ref }) else { return nil }
            return (i > 0 ? steps[i - 1] : nil, i + 1 < steps.count ? steps[i + 1] : nil)
        }
    }

    public var views: [SavedView]
    public var trails: [Trail]?
}
