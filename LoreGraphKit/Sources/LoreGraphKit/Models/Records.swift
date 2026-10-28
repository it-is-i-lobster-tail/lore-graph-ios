import Foundation

/// A statement: a typed link with dates, place, role, certainty and visibility. With
/// `accordingTo` set it is a claim of a story or tale, never a fact (DESIGN.md 4.5).
public struct Statement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var subject: EntityCard?
    public var predicate: String
    public var label: String?
    public var object: EntityCard?
    public var value: JSONValue?
    public var role: String?
    public var side: EntityCard?
    public var place: EntityCard?
    public var valid: DateSpan?
    public var accordingTo: EntityCard?
    public var claimRelation: String?
    public var recordStatementId: String?
    public var certainty: String?
    public var visibility: Visibility
    public var canon: Canon?
    public var sourceQuote: String?
    public var note: String?
    public var sentence: String?
    public var uiUrl: String?

    public var isClaim: Bool { accordingTo != nil }

    /// The sentence the server wrote, else one made from the parts.
    public var shownSentence: String {
        if let sentence, !sentence.isEmpty { return sentence }
        let s = subject?.shownTitle ?? ""
        let o = object?.shownTitle ?? value?.text ?? ""
        return [s, label ?? predicate.replacingOccurrences(of: "_", with: " "), o].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// `GET /api/v1/statements` (F-4.10).
public struct StatementList: Codable, Hashable, Sendable {
    public var items: [Statement]
    public var nextCursor: String?

    /// The record first, claims apart, as the page's Records view shows them.
    public var record: [Statement] { items.filter { !$0.isClaim } }
    public var claims: [Statement] { items.filter(\.isClaim) }
}

/// `GET /api/v1/statements/{id}`: one record with the claims about it.
public struct StatementDetail: Codable, Hashable, Sendable {
    public struct Omission: Codable, Hashable, Sendable {
        public struct Account: Codable, Hashable, Sendable {
            public var ref: String
            public var title: String
        }

        public var account: Account
        public var note: String?
        public var visibility: Visibility?
    }

    public var statement: Statement
    public var record: Statement?
    public var claims: [Statement]?
    public var omittedBy: [Omission]?
}

/// `GET /api/v1/statements/{id}/who-knows` (F-4.10).
public struct WhoKnows: Codable, Hashable, Sendable {
    public struct Holder: Codable, Hashable, Sendable {
        public var holder: EntityCard
        public var how: String?
        public var stance: String?
        public var openness: String?
        public var acquisition: String?
        public var beliefId: String?
        public var since: DateSpan?
        public var visibility: Visibility?
    }

    public var holders: [Holder]
    public var byStance: [String: Int]?
}

/// The way a story or tale was told (`telling`).
public struct Telling: Codable, Hashable, Sendable {
    public var teller: EntityCard?
    public var tellerLabel: String?
    public var medium: String?
    public var told: DateSpan?
    public var toldInTellerCalendar: String?
    public var toldAt: EntityCard?
    public var audience: String?
    public var bias: String?
    public var reliability: Int?
    public var listed: Bool?
}

/// `GET /api/v1/entities/{ref}/accounts`.
public struct AccountList: Codable, Hashable, Sendable {
    public struct Account: Codable, Hashable, Sendable {
        public var account: EntityCard
        public var telling: Telling?
        public var claims: [String: Int]?
        public var claimCount: Int?
        public var omissions: Int?
        public var believers: Int?
    }

    public var accounts: [Account]
}

/// `GET /api/v1/accounts/compare` (F-5.1): the record and each telling, row by row.
public struct AccountsCompared: Codable, Hashable, Sendable {
    public struct Column: Codable, Hashable, Sendable {
        public struct Row: Codable, Hashable, Sendable {
            public var recordStatementId: String?
            public var claims: [Statement]
            public var leftOut: Bool?
            public var omissionNote: String?
        }

        public var account: EntityCard
        public var telling: Telling?
        public var rows: [Row]
        public var unaligned: [Statement]?
    }

    public var subject: EntityCard
    public var record: [Statement]
    public var accounts: [Column]
    public var legend: [String: String]?

    /// What one account says about one record: its claims, or that it leaves the record out,
    /// or nothing (it agrees by silence).
    public func cell(account: String, record id: String) -> Column.Row? {
        accounts.first { $0.account.ref == account }?.rows.first { $0.recordStatementId == id }
    }

    /// The words for a claim relation, never only its symbol.
    public static func relationWord(_ relation: String?) -> String {
        switch relation {
        case "agrees": "agrees"
        case "contradicts": "contradicts"
        case "exaggerates": "exaggerates"
        case "minimizes", "minimises": "minimises"
        case "distorts": "distorts"
        case "invents": "invents"
        case "unverifiable": "cannot be checked"
        case .some(let other): other.replacingOccurrences(of: "_", with: " ")
        case .none: "agrees"
        }
    }
}

/// A belief: a holder's stance on a proposition (DESIGN.md 4.10).
public struct Belief: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var proposition: String
    public var propositionKey: String?
    public var kind: String?
    public var holder: String?
    public var holderTitle: String?
    public var stance: String
    public var conviction: Int?
    public var openness: String?
    public var held: DateSpan?
    public var acquisition: String?
    public var acquiredFrom: EntityCard?
    public var formedByEvent: EntityCard?
    public var statementId: String?
    public var visibility: Visibility
    public var canon: Canon?
    public var sentence: String?
    public var truth: String?
    public var truthNote: String?
    public var inherited: Bool?
    public var depth: Int?
    public var via: String?
    public var overriddenBy: String?

    public var isOverridden: Bool { overriddenBy != nil }
}

/// `GET /api/v1/holders/{ref}/beliefs` (F-5.2).
public struct BeliefsOf: Codable, Hashable, Sendable {
    public struct Group: Codable, Hashable, Sendable {
        public var ref: String
        public var title: String
        public var type: EntityType?
        public var via: String?
        public var depth: Int?
        public var sinceFormatted: String?
    }

    public struct Counts: Codable, Hashable, Sendable {
        public var own: Int?
        public var inherited: Int?
        public var overridden: Int?
        public var designerOnly: Int?
    }

    public var holder: EntityCard
    public var asOf: DateSpan?
    public var groups: [Group]?
    public var beliefs: [Belief]
    public var counts: Counts?

    /// Beliefs grouped by question (proposition key), in first-seen order.
    public var byQuestion: [(key: String, beliefs: [Belief])] {
        var order: [String] = []
        var groups: [String: [Belief]] = [:]
        for b in beliefs {
            let key = b.propositionKey ?? b.proposition
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(b)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

/// `GET /api/v1/beliefs/{id}/lineage` (F-5.3): where a belief came from, as sentences.
public struct BeliefLineage: Codable, Hashable, Sendable {
    public struct Step: Codable, Hashable, Sendable {
        public var step: String
        public var beliefId: String?
        public var account: EntityCard?
        public var told: DateSpan?
        public var tellerCard: EntityCard?
        public var medium: String?
        public var bias: String?
        public var reliability: Int?
        public var text: String?
    }

    public var belief: Belief
    public var chain: [Step]
}

/// `GET /api/v1/beliefs/holders` (F-5.4): who believes what about one question.
public struct BeliefHolders: Codable, Hashable, Sendable {
    public struct Question: Codable, Hashable, Sendable {
        public var key: String?
    }

    public struct Holder: Codable, Hashable, Sendable {
        public var holder: EntityCard
        public var beliefId: String?
        public var proposition: String?
        public var stance: String?
        public var openness: String?
        public var held: DateSpan?
        public var own: Bool?
        public var visibility: Visibility?
    }

    public var question: Question?
    public var beliefs: [Belief]
    public var holders: [Holder]
    public var byStance: [String: Int]?
}

/// `GET /api/v1/factions/{ref}/tree` (F-4.12).
public struct FactionTree: Codable, Hashable, Sendable {
    public struct Part: Codable, Hashable, Sendable {
        public var ref: String
        public var id: String
        public var title: String
        public var kind: String?
        public var visibility: Visibility?
        public var shortDescription: String?
        public var how: String?
        public var members: Int?
        public var parts: [Part]?
    }

    public struct Faction: Codable, Hashable, Sendable {
        public var ref: String
        public var title: String
        public var members: Int?
        public var seat: EntityCard?
    }

    public var faction: Faction
    public var parents: [EntityCard]?
    public var parts: [Part]
    public var asOf: DateSpan?
}

/// `GET /api/v1/memberships` (F-4.12).
public struct Memberships: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var statementId: String
        public var member: EntityCard
        public var group: EntityCard
        public var link: String?
        public var role: String?
        public var valid: DateSpan?
        public var accordingTo: EntityCard?
        public var visibility: Visibility?
        public var sentence: String?
    }

    public var items: [Item]
    public var nextCursor: String?
}
