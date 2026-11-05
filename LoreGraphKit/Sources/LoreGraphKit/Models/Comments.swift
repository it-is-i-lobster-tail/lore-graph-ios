import Foundation

/// A comment on page text (loregraph ADR D-84): a thread on one section of a page, usually on a
/// passage of its text, with replies. Comments are notes, not lore: they never change a page.
public struct PageComment: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case open, resolved }

    public struct SectionRef: Codable, Hashable, Sendable {
        public var id: String?
        public var key: String
        public var heading: String?
        /// False when the section was deleted (the comment stays, detached).
        public var exists: Bool
        public var generated: Bool?
    }

    /// Where the passage is now. The server finds it again on every read and sends the text it
    /// found with its occurrence and context; positions never cross between server and app.
    public struct Anchor: Codable, Hashable, Sendable {
        public enum State: String, Codable, Sendable {
            /// The passage reads as it did.
            case exact
            /// The passage was edited; the highlight is on the closest text.
            case changed
            /// The passage is gone; the comment stays with the words it was on.
            case detached
            /// A comment on the whole section.
            case section
        }

        public var status: State
        /// The passage as it was when the comment was written.
        public var quote: String?
        /// The text it is on now, with which occurrence of that text it is and its context.
        public var text: String?
        public var prefix: String?
        public var suffix: String?
        public var occurrence: Int?

        public init(status: State, quote: String? = nil, text: String? = nil, prefix: String? = nil,
                    suffix: String? = nil, occurrence: Int? = nil) {
            self.status = status
            self.quote = quote
            self.text = text
            self.prefix = prefix
            self.suffix = suffix
            self.occurrence = occurrence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            status = State(rawValue: try c.decode(String.self, forKey: .status)) ?? .detached
            quote = try c.decodeIfPresent(String.self, forKey: .quote)
            text = try c.decodeIfPresent(String.self, forKey: .text)
            prefix = try c.decodeIfPresent(String.self, forKey: .prefix)
            suffix = try c.decodeIfPresent(String.self, forKey: .suffix)
            occurrence = try c.decodeIfPresent(Int.self, forKey: .occurrence)
        }

        /// Shown as a highlight in the page's text.
        public var isPlaced: Bool { (status == .exact || status == .changed) && !(text ?? "").isEmpty }
    }

    public struct Author: Codable, Hashable, Sendable {
        public var name: String?
        /// The client or agent it came through.
        public var via: String?
        /// Written by this reader through this app.
        public var mine: Bool

        public var shown: String { name ?? via ?? "Someone" }
    }

    public struct Reply: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var bodyMd: String
        public var visibility: Visibility
        public var author: Author
        public var createdAt: String?
        public var editedAt: String?
        public var canEdit: Bool
        public var canDelete: Bool
        /// Written on this phone and not sent yet.
        public var queued: QueueMark? = nil
    }

    /// A change made on this phone that the server has not had yet.
    public struct QueueMark: Codable, Hashable, Sendable {
        /// The queued change (`QueuedChange.id`).
        public var id: String
        public var summary: String
        /// Why the server refused it, when it did.
        public var problem: String?
        /// A new comment on a passage: it can go on the whole section instead.
        public var onPassage: Bool

        public init(_ c: QueuedChange) {
            id = c.id
            summary = c.summary
            problem = c.problem
            onPassage = c.kind == .add && c.quote != nil
        }
    }

    public var id: String
    public var page: EntityCard?
    public var section: SectionRef
    public var anchor: Anchor
    public var status: Status
    public var visibility: Visibility
    public var bodyMd: String
    public var author: Author
    public var createdAt: String?
    public var editedAt: String?
    public var updatedAt: String?
    public var resolvedAt: String?
    public var resolvedBy: String?
    public var replies: [Reply]
    public var version: Int?
    public var canEdit: Bool
    public var canDelete: Bool
    public var uiUrl: String?
    /// Written, or changed, on this phone and not sent yet.
    public var queued: QueueMark? = nil

    public var isOpen: Bool { status == .open }
}

/// `GET /comments`: comments with their replies; one page's come in reading order.
public struct CommentList: Codable, Hashable, Sendable {
    public var comments: [PageComment]
    /// Open and resolved comments under the same filters, whatever the status asked.
    public var counts: [String: Int]
    public var nextCursor: String?
    public var uiUrl: String?

    public init(comments: [PageComment] = [], counts: [String: Int] = [:], nextCursor: String? = nil, uiUrl: String? = nil) {
        self.comments = comments
        self.counts = counts
        self.nextCursor = nextCursor
        self.uiUrl = uiUrl
    }

    public var open: Int { counts["open"] ?? comments.filter(\.isOpen).count }
    public var resolved: Int { counts["resolved"] ?? comments.filter { !$0.isOpen }.count }
}

/// What adding, answering, resolving or editing a comment answers.
public struct CommentResult: Codable, Hashable, Sendable {
    /// The comment as the list shows it; nil once deleted.
    public var comment: PageComment?
    public var warnings: [String]?
}
