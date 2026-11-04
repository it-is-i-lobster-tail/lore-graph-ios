import Foundation
import Observation

/// One page's comments (loregraph ADR D-84): the highlights in its text and the conversation
/// beside it. Comments are notes, not lore: adding, answering and resolving them changes no page
/// and opens no edit tag, and needs only `lore:read`.
@Observable
@MainActor
public final class CommentsModel {
    public let ref: String
    public let loader: Loader<CommentList>
    public private(set) var isWorking = false
    /// The last change that failed, with the server's reason.
    public var actionError: APIError?
    /// Notes from the server about the last change (a visibility raised, a quote matched loosely).
    public private(set) var warnings: [String] = []
    /// Shown in the list as well as the open ones.
    public var showResolved = false
    @ObservationIgnored public let context: ReadContext

    public init(ref: String, context: ReadContext) {
        self.ref = ref
        self.context = context
        loader = context.loader(API.comments(on: ref, viewAs: context.view.viewAs))
    }

    public func load() async { await loader.load() }
    public func refresh() async { await loader.refresh() }

    public var all: [PageComment] { loader.value?.comments ?? [] }
    public var open: [PageComment] { all.filter(\.isOpen) }
    public var openCount: Int { open.count }
    public var resolvedCount: Int { all.count - open.count }
    /// The comments the panel lists, in reading order.
    public var shown: [PageComment] { showResolved ? all : open }

    public func comment(_ id: String) -> PageComment? { all.first { $0.id == id } }

    /// Open comments on a section (by key).
    public func open(in section: String) -> [PageComment] { open.filter { $0.section.key == section } }

    /// The passages of a section's open comments, to highlight in its text.
    public func highlights(_ section: String) -> [Anchors.Highlight] {
        open.filter { $0.section.key == section && $0.anchor.isPlaced }.map { Anchors.Highlight(id: $0.id, anchor: $0.anchor) }
    }

    /// The panel's comments in groups by section, in reading order.
    public var groups: [CommentGroup] {
        var out: [CommentGroup] = []
        for c in shown {
            if let i = out.firstIndex(where: { $0.key == c.section.key }) {
                out[i].comments.append(c)
            } else {
                out.append(CommentGroup(key: c.section.key, heading: c.section.heading, comments: [c]))
            }
        }
        return out
    }

    // MARK: changes

    /// A comment on a passage (or, without one, on the whole section). Returns the new comment.
    @discardableResult
    public func add(section: String, picked: Anchors.Picked?, body: String) async -> PageComment? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let change = API.addComment(page: ref, section: section, quote: picked?.quote, prefix: picked?.prefix,
                                    suffix: picked?.suffix, body: text)
        guard let c = await send(change) else { return nil }
        return c
    }

    @discardableResult
    public func reply(to id: String, body: String, resolve: Bool = false) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await send(API.reply(to: id, body: text, resolve: resolve)) != nil
    }

    @discardableResult
    public func setResolved(_ id: String, _ resolved: Bool) async -> Bool {
        await send(API.resolveComment(id, resolved: resolved)) != nil
    }

    /// New text for the reader's own comment or reply.
    @discardableResult
    public func edit(_ id: String, reply: String? = nil, body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await send(API.editComment(id, reply: reply, body: text)) != nil
    }

    /// Deletes a comment with its replies, or one reply.
    @discardableResult
    public func delete(_ id: String, reply: String? = nil) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let r = try await context.repository.client.send(API.deleteComment(id, reply: reply), world: context.world)
            actionError = nil
            warnings = r.warnings ?? []
            if let c = r.comment { put(c) } else { remove(id) }
            return true
        } catch {
            actionError = (error as? APIError) ?? .offline("")
            return false
        }
    }

    private func send(_ change: Change<CommentResult>) async -> PageComment? {
        isWorking = true
        defer { isWorking = false }
        do {
            let r = try await context.repository.client.send(change, world: context.world)
            actionError = nil
            warnings = r.warnings ?? []
            if let c = r.comment { put(c) }
            return r.comment
        } catch {
            actionError = (error as? APIError) ?? .offline("")
            return nil
        }
    }

    /// Puts a comment the server sent back in its place (a new one at the end; the next load
    /// sorts it into reading order).
    func put(_ c: PageComment) {
        var v = loader.value ?? CommentList()
        if let i = v.comments.firstIndex(where: { $0.id == c.id }) {
            let was = v.comments[i].status
            v.comments[i] = c
            if was != c.status { recount(&v) }
        } else {
            v.comments.append(c)
            recount(&v)
        }
        loader.show(v)
    }

    func remove(_ id: String) {
        guard var v = loader.value else { return }
        v.comments.removeAll { $0.id == id }
        recount(&v)
        loader.show(v)
    }

    private func recount(_ v: inout CommentList) {
        v.counts = ["open": v.comments.filter(\.isOpen).count, "resolved": v.comments.filter { !$0.isOpen }.count]
    }
}

/// One section's comments in the panel.
public struct CommentGroup: Identifiable, Hashable, Sendable {
    public var key: String
    public var heading: String?
    public var comments: [PageComment]
    public var id: String { key }
    /// The heading to show ("Introduction" for the lead).
    public var title: String { heading ?? (key == "lead" ? "Introduction" : key) }
}

/// Comments across the world (the web app's /comments), the latest activity first.
@Observable
@MainActor
public final class AllCommentsModel {
    public private(set) var status: PageComment.Status?
    public private(set) var loader: Loader<CommentList>
    @ObservationIgnored public let context: ReadContext

    public init(status: PageComment.Status? = .open, context: ReadContext) {
        self.status = status
        self.context = context
        loader = context.loader(API.allComments(status: status))
    }

    public func load() async { await loader.load() }
    public func refresh() async { await loader.refresh() }

    public func set(status: PageComment.Status?) async {
        guard status != self.status else { return }
        self.status = status
        loader = context.loader(API.allComments(status: status))
        await loader.load()
    }
}
