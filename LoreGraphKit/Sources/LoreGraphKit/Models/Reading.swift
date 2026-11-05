import Foundation

/// A reading list (loregraph ADR D-83): every page of a world in an order to read from the start,
/// in parts, with the reader's own progress. `GET /reading-lists[/{id}]` answers with this.
public struct ReadingList: Codable, Hashable, Sendable {
    /// The list itself; nil when the reader has no list in this world yet.
    public var readingList: Info?
    public var progress: Progress?
    public var parts: [Part]
    /// The page to read next: the first unread one after the page marked last; nil when every page is read.
    public var upNext: Item?
    public var items: [Item]
    /// Pages that are not in the list yet (made or approved since it was built).
    public var newPages: Int?
    /// The reader's lists in this world, newest first.
    public var lists: [Info]
    public var nextCursor: String?

    public init(readingList: Info? = nil, progress: Progress? = nil, parts: [Part] = [], upNext: Item? = nil,
                items: [Item] = [], newPages: Int? = nil, lists: [Info] = [], nextCursor: String? = nil) {
        self.readingList = readingList
        self.progress = progress
        self.parts = parts
        self.upNext = upNext
        self.items = items
        self.newPages = newPages
        self.lists = lists
        self.nextCursor = nextCursor
    }

    public struct Info: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var visibility: Visibility?
        public var createdAt: String?
        public var updatedAt: String?
        public var pages: Int?
        /// Pages read (in the list of lists only).
        public var read: Int?
        public var uiUrl: String?
        /// The parts with their counts (in a build answer only).
        public var parts: [Part]?
    }

    public struct Progress: Codable, Hashable, Sendable {
        public var pages: Int
        public var read: Int
        public var unread: Int
        /// Read, then edited by someone else.
        public var changed: Int
        public var percent: Int
        public var words: Int
        public var wordsRead: Int
        /// At 200 words a minute, at least a minute a page.
        public var minutesLeft: Int
        public var lastReadAt: String?
    }

    public struct Part: Codable, Hashable, Sendable, Identifiable {
        public var key: String
        public var title: String
        public var note: String?
        public var pages: Int
        public var read: Int
        public var words: Int
        public var minutesLeft: Int
        /// The number of its first page in the list.
        public var first: Int

        public var id: String { key }
        public var isDone: Bool { read >= pages }
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        /// Its number in the list, from 1.
        public var n: Int
        public var page: EntityCard
        public var part: String
        public var words: Int
        /// When the reader marked it read, as the server wrote it (nil while unread).
        public var readAt: String?
        /// Edited by someone else since it was read.
        public var changed: Bool
        /// Minutes to read it (the next page only).
        public var minutes: Int?
        public var uiUrl: String?

        public var id: String { page.id }
        public var isRead: Bool { readAt != nil }
        /// Read and still as it was read.
        public var isDone: Bool { isRead && !changed }
    }
}

/// What building, renaming, adding to or deleting a reading list answers.
public struct ReadingBuildResult: Codable, Hashable, Sendable {
    /// The list with its parts; nil once deleted.
    public var readingList: ReadingList.Info?
    /// Pages this call put in the list.
    public var added: Int?
    public var warnings: [String]?
}

/// What marking pages read or unread answers: the new progress and the page to read next.
public struct ReadingMarkResult: Codable, Hashable, Sendable {
    /// Pages whose mark changed.
    public var changed: Int
    public var items: [ReadingList.Item]
    public var progress: ReadingList.Progress
    public var parts: [ReadingList.Part]
    public var upNext: ReadingList.Item?
    public var warnings: [String]?
}

/// A word diff of a section's text since a moment (`diff_since`): what was kept, added and removed.
public struct WordChange: Codable, Hashable, Sendable {
    public enum Op: String, Codable, Sendable { case equal, insert, delete }

    public var op: Op
    public var text: String

    public init(op: Op, text: String) {
        self.op = op
        self.text = text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        op = Op(rawValue: try c.decode(String.self, forKey: .op)) ?? .equal
        text = try c.decode(String.self, forKey: .text)
    }
}
