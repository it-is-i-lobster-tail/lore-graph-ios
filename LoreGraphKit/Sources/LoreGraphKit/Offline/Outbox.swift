import Foundation

/// A change to a comment written while the server could not be reached, kept on the phone until
/// it is sent. Its id goes with it as `Idempotency-Key`, so a change the server got but whose
/// answer was lost is not made twice when it is sent again.
public struct QueuedChange: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case add, reply, resolve, reopen, edit, delete
    }

    public var id: String
    public var kind: Kind
    public var world: String?
    /// The page it is on (as the page was opened) and its title, for the lists.
    public var page: String
    public var pageTitle: String?
    /// The comment it is about; a queued comment's own id (`queued-…`) until that is sent.
    public var comment: String?
    /// The reply it is about (editing or deleting a reply).
    public var reply: String?
    /// A new comment's section and passage.
    public var section: String?
    public var sectionHeading: String?
    public var quote: String?
    public var prefix: String?
    public var suffix: String?
    public var body: String?
    /// A reply that also resolves the comment.
    public var resolve: Bool?
    public var queuedAt: Date
    /// Why the server refused it; it waits for the reader to retry, change or discard it.
    public var problem: String?
    /// Goes up when the reader retries a refused change: the server keeps its answer for a key, so
    /// a new try needs a new key. A change that got no answer is sent again with the same one.
    public var attempt: Int = 0

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, world: String?, page: String, pageTitle: String? = nil,
                comment: String? = nil, reply: String? = nil, section: String? = nil, sectionHeading: String? = nil,
                quote: String? = nil, prefix: String? = nil, suffix: String? = nil, body: String? = nil, resolve: Bool? = nil,
                queuedAt: Date, problem: String? = nil) {
        self.id = id
        self.kind = kind
        self.world = world
        self.page = page
        self.pageTitle = pageTitle
        self.comment = comment
        self.reply = reply
        self.section = section
        self.sectionHeading = sectionHeading
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.body = body
        self.resolve = resolve
        self.queuedAt = queuedAt
        self.problem = problem
    }

    /// The id a queued comment shows by until the server gives it its own.
    public var localID: String { Self.prefix + id }

    public static let prefix = "queued-"

    public static func isLocal(_ id: String?) -> Bool { id?.hasPrefix(prefix) ?? false }

    /// Waits for another queued change (the comment it is on is not sent yet).
    public var waitsForAnother: Bool { Self.isLocal(comment) }

    /// The request, ready to send once every id in it is the server's.
    public var change: Change<CommentResult>? {
        var c: Change<CommentResult>
        switch kind {
        case .add:
            guard let section, let body else { return nil }
            c = API.addComment(page: page, section: section, quote: quote, prefix: prefix, suffix: suffix, body: body)
        case .reply:
            guard let comment, let body else { return nil }
            c = API.reply(to: comment, body: body, resolve: resolve ?? false)
        case .resolve, .reopen:
            guard let comment else { return nil }
            c = API.resolveComment(comment, resolved: kind == .resolve)
        case .edit:
            guard let comment, let body else { return nil }
            c = API.editComment(comment, reply: reply, body: body)
        case .delete:
            guard let comment else { return nil }
            c = API.deleteComment(comment, reply: reply)
        }
        c.idempotencyKey = "ios-\(id)-\(attempt)"
        return c
    }

    /// What it is, in a few words, for the list of changes waiting to be sent.
    public var summary: String {
        switch kind {
        case .add: "New comment"
        case .reply: resolve == true ? "Reply and resolve" : "Reply"
        case .resolve: "Resolve"
        case .reopen: "Reopen"
        case .edit: reply == nil ? "Edit comment" : "Edit reply"
        case .delete: reply == nil ? "Delete comment" : "Delete reply"
        }
    }
}

/// The reader's changes to comments waiting for the server, in the order they were made, kept on
/// the phone (beside the downloads, so Clear cache keeps them) until they are sent.
public actor Outbox {
    public let file: URL
    private var items: [QueuedChange]?

    public init(file: URL) {
        self.file = file
    }

    public var all: [QueuedChange] {
        load()
        return items ?? []
    }

    public func append(_ c: QueuedChange) {
        load()
        items?.append(c)
        persist()
    }

    public func replace(_ c: QueuedChange) {
        load()
        guard let i = items?.firstIndex(where: { $0.id == c.id }) else { return }
        items?[i] = c
        persist()
    }

    public func remove(_ id: String) {
        load()
        items?.removeAll { $0.id == id }
        persist()
    }

    /// A queued comment was sent and has the server's id: later changes to it use that id.
    public func sent(_ id: String, as serverID: String?) {
        load()
        items?.removeAll { $0.id == id }
        if let serverID {
            let local = QueuedChange.prefix + id
            for i in (items ?? []).indices where items?[i].comment == local { items?[i].comment = serverID }
        }
        persist()
    }

    /// Discards a change, and every change waiting on it (replies to a comment that is not sent).
    public func discard(_ id: String) {
        load()
        let local = QueuedChange.prefix + id
        items?.removeAll { $0.id == id || $0.comment == local }
        persist()
    }

    public func removeAll() {
        items = []
        try? FileManager.default.removeItem(at: file)
    }

    private func load() {
        guard items == nil else { return }
        items = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([QueuedChange].self, from: $0) } ?? []
    }

    private func persist() {
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DownloadStore.excludeFromBackup(dir)
        guard let data = try? JSONEncoder().encode(items ?? []) else { return }
        #if os(iOS)
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: file, options: .atomic)
        #endif
    }
}
