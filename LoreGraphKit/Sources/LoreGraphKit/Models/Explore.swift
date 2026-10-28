import Foundation

/// A piece of a snippet, marked when it matched the query.
public struct SnippetPart: Codable, Hashable, Sendable {
    public var text: String
    public var hit: Bool
}

/// `GET /api/v1/search` (F-10.1).
public struct SearchResults: Codable, Hashable, Sendable {
    public struct Result: Codable, Hashable, Sendable, Identifiable {
        public struct Passage: Codable, Hashable, Sendable {
            public var id: String?
            public var kind: String?
            public var headingPath: String?
            public var snippetParts: [SnippetPart]?
            public var snippet: String?
            public var visibility: Visibility?
        }

        public struct MatchedName: Codable, Hashable, Sendable {
            public var name: String
            public var kind: String?
            public var match: String?
        }

        public var entity: EntityCard
        public var displayName: String?
        public var score: Double?
        public var why: [String]?
        public var matchedName: MatchedName?
        public var snippet: String?
        public var snippetParts: [SnippetPart]?
        public var passages: [Passage]?

        public var id: String { entity.id }
    }

    public struct Facets: Codable, Hashable, Sendable {
        public var type: [String: Int]?
        public var kind: [String: Int]?
    }

    public var query: String?
    public var results: [Result]
    public var total: Int?
    public var nextCursor: String?
    public var facets: Facets?
    public var warnings: [String]?
    public var tookMs: Int?
}

/// `GET /api/v1/search/resolve?mode=suggest` (F-10.2).
public struct Suggestions: Codable, Hashable, Sendable {
    public struct Candidate: Codable, Hashable, Sendable, Identifiable {
        public var ref: String
        public var id: String
        public var title: String
        public var type: EntityType?
        public var kind: String?
        public var visibility: Visibility?
        public var shortDescription: String?
        public var matched: String?
        public var how: String?

        public var card: EntityCard {
            EntityCard(ref: ref, id: id, title: title, type: type, kind: kind, visibility: visibility,
                       shortDescription: shortDescription)
        }
    }

    public var query: String?
    public var candidates: [Candidate]
}

/// `GET /api/v1/dates/convert` (F-3.1): what the server understood a typed date as.
public struct DateConversion: Codable, Hashable, Sendable {
    public struct Calendar: Codable, Hashable, Sendable {
        public var key: String
        public var name: String
        public var `default`: Bool?
    }

    public var parsed: DateSpan
    public var formatted: [String: String]?
    public var calendars: [Calendar]?
}

/// `GET /api/v1/timeline` (F-6).
public struct Timeline: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var kind: String
        public var id: String
        public var ref: String?
        public var title: String
        public var predicate: String?
        public var family: String?
        public var date: DateSpan
        public var visibility: Visibility
        public var canon: Canon?
        public var claim: Bool?
        public var accordingTo: EntityCard?
        public var claimRelation: String?
        public var lanes: [String: String?]?
        public var uiUrl: String?

        public var isClaim: Bool { claim == true || accordingTo != nil }

        /// The lane this item sits in under a lane scheme (type, faction, place, person).
        public func lane(_ scheme: String) -> String? {
            guard let value = lanes?[scheme] else { return nil }
            return value
        }
    }

    public struct Era: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var scheme: String?
        public var span: DateSpan
        public var description: String?
        public var visibility: Visibility?
    }

    public var items: [Item]
    public var eras: [Era]?
    public var nextCursor: String?
}

/// `GET /api/v1/people/{ref}/family-tree` (F-8).
public struct FamilyTree: Codable, Hashable, Sendable {
    public struct Person: Codable, Hashable, Sendable, Identifiable {
        public var ref: String
        public var id: String
        public var title: String
        public var displayTitle: String?
        public var shortDescription: String?
        public var visibility: Visibility?
        public var generation: Int
        public var gender: String?
        public var lifespan: DateSpan?
        public var atYear: JSONValue?
        public var root: Bool?

        public var shownTitle: String { displayTitle ?? title }
    }

    public struct ParentLink: Codable, Hashable, Sendable {
        public var statementId: String
        public var parent: String
        public var child: String
        public var role: String?
        public var kind: String?
        public var disputed: Bool?
        public var visibility: Visibility
        public var accordingTo: EntityCard?

        /// Adoption, fostering and the like are drawn dashed.
        public var isBiological: Bool { kind == nil || kind == "biological" }
    }

    public struct Marriage: Codable, Hashable, Sendable {
        public var statementId: String
        public var a: String
        public var b: String
        public var kind: String?
        public var visibility: Visibility?
        public var valid: DateSpan?
    }

    public struct Union: Codable, Hashable, Sendable {
        public var a: String?
        public var b: String?
        public var children: [String]
    }

    public var root: EntityCard
    public var people: [Person]
    public var parents: [ParentLink]
    public var marriages: [Marriage]
    public var unions: [Union]
    public var uiUrl: String?
}

/// `GET /api/v1/people/kinship` (F-8.6).
public struct Kinship: Codable, Hashable, Sendable {
    public var relationship: String?
    public var inverse: String?
    public var sentence: String?
    public var via: String?
    public var commonAncestors: [EntityCard]?
    public var path: [EntityCard]?
}

/// `GET /api/v1/graph/neighbourhood` (F-9.1).
public struct Neighbourhood: Codable, Hashable, Sendable {
    public struct Node: Codable, Hashable, Sendable, Identifiable {
        public struct Span: Codable, Hashable, Sendable {
            public var from: Double?
            public var to: Double?
        }

        public var ref: String
        public var id: String
        public var title: String
        public var displayTitle: String?
        public var type: EntityType
        public var kind: String?
        public var visibility: Visibility
        public var canon: Canon?
        public var shortDescription: String?
        public var depth: Int?
        public var degree: Int?
        public var exists: Bool?
        public var span: Span?
        public var more: Int?

        public var shownTitle: String { displayTitle ?? title }
        public var card: EntityCard {
            EntityCard(ref: ref, id: id, title: title, type: type, kind: kind, visibility: visibility, canon: canon,
                       shortDescription: shortDescription)
        }
    }

    public struct Edge: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var source: String
        public var target: String
        public var sourceRef: String?
        public var targetRef: String?
        public var predicate: String
        public var label: String?
        public var inverseLabel: String?
        public var family: String?
        public var symmetric: Bool?
        public var role: String?
        public var valid: DateSpan?
        public var accordingTo: EntityCard?
        public var claimRelation: String?
        public var certainty: String?
        public var visibility: Visibility
        public var canon: Canon?

        public var isClaim: Bool { accordingTo != nil }
    }

    public var nodes: [Node]
    public var edges: [Edge]
    public var truncated: Bool?
    public var uiUrl: String?
}

/// `GET /api/v1/graph/path` (F-9.5).
public struct GraphPaths: Codable, Hashable, Sendable {
    public struct Path: Codable, Hashable, Sendable {
        public struct Step: Codable, Hashable, Sendable {
            public var from: String
            public var to: String
            public var statementId: String?
            public var predicate: String?
            public var label: String?
            public var visibility: Visibility?
            public var accordingTo: EntityCard?
        }

        public var length: Int
        public var steps: [Step]
        public var sentence: String?
    }

    public var paths: [Path]
    public var length: Int?
}

/// `GET /api/v1/map/layers` (F-7.5).
public struct MapLayers: Codable, Hashable, Sendable {
    public struct Layer: Codable, Hashable, Sendable, Identifiable {
        public struct Raster: Codable, Hashable, Sendable {
            public var key: String?
            public var url: String?
            public var nativeZoom: Int?
            public var status: String?
        }

        public var id: String
        public var key: String
        public var title: String
        public var kind: String
        public var group: String?
        public var generation: String?
        public var description: String?
        public var source: [String: JSONValue]?
        public var defaultVisible: Bool?
        public var zOrder: Int?
        public var minZoom: Double?
        public var maxZoom: Double?
        public var visibility: Visibility?
        public var style: [String: JSONValue]?
        public var raster: Raster?

        /// Lore shapes or generator geometry served as vector tiles.
        public var isVectorTiled: Bool { kind == "vector" && (source?["shapes"] != nil || source?["features"] != nil) }
        public var isDerived: Bool { kind == "derived" }
        public var isRaster: Bool { kind == "raster" }
        /// Generator geometry (base-*, next-*), as opposed to lore shapes.
        public var isBaseGeometry: Bool { source?["features"] != nil }
        public var isCurrent: Bool { generation == nil || generation == "current" }

        /// Which base map a raster stands for, from its key or title (as the web app reads it).
        public var baseMap: BaseMap? {
            guard isRaster, group == "Base maps" else { return nil }
            let text = "\(key) \(title)".lowercased()
            if text.contains("relief") || text.contains("hillshade") { return .relief }
            if text.contains("atlas") || text.contains("painted") { return .atlas }
            return nil
        }
    }

    public struct Settings: Codable, Hashable, Sendable {
        public struct Home: Codable, Hashable, Sendable {
            public var zoom: Double
            public var center: [Double]
        }

        public var maxZoom: Int?
        public var minZoom: Int?
        public var tileSize: Int?
        public var mvtExtent: Int?
        public var rasterMaxZoom: Int?
        public var home: Home?
        public var tileUrl: String?
    }

    public var layers: [Layer]
    public var groups: [String]?
    public var map: Settings?
    public var mapVersion: Int?
}

public enum BaseMap: String, Codable, Sendable, CaseIterable, Hashable {
    case atlas, relief, plain

    public var label: String {
        switch self {
        case .atlas: "Atlas"
        case .relief: "Relief"
        case .plain: "Plain"
        }
    }
}

/// `GET /api/v1/map/at` (F-7.9): what is at a point.
public struct PlacesAt: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public var lon: Double
        public var lat: Double
    }

    public struct Inside: Codable, Hashable, Sendable {
        public var entity: EntityCard
        public var role: String?
        public var precision: String?
    }

    public struct Nearby: Codable, Hashable, Sendable {
        public var entity: EntityCard
        public var role: String?
        public var distanceKm: Double?
        public var direction: String?
        public var precision: String?
    }

    public struct Feature: Codable, Hashable, Sendable {
        public var featureId: String?
        public var `class`: String?
        public var layer: String?
        public var name: String?
        public var distanceKm: Double?
    }

    public var point: Point
    public var year: Double?
    public var inside: [Inside]
    public var nearest: [Nearby]
    public var features: [Feature]?
    public var elevationM: Double?
}

/// `GET /api/v1/map/distance` (F-7.10).
public struct Distance: Codable, Hashable, Sendable {
    public struct Waypoint: Codable, Hashable, Sendable {
        public var label: String?
        public var entity: EntityCard?
        public var lon: Double
        public var lat: Double
        public var precision: String?
    }

    public struct Leg: Codable, Hashable, Sendable {
        public var from: String?
        public var to: String?
        public var km: Double
        public var bearing: Double?
        public var direction: String?
    }

    public struct Travel: Codable, Hashable, Sendable {
        public var kmPerDay: Double?
        public var days: Double
        public var hours: Double?
    }

    public var waypoints: [Waypoint]
    public var legs: [Leg]
    public var totalKm: Double
    public var travel: [String: Travel]?
    public var warnings: [String]?

    /// Travel modes in a fixed order, with their words.
    public static let modes: [(key: String, label: String)] = [
        ("foot", "On foot"), ("march", "Marching"), ("horse", "By horse"), ("cart", "By cart"),
        ("barge_down", "Barge downstream"), ("barge_up", "Barge upstream"), ("ship", "By ship"),
    ]
}
