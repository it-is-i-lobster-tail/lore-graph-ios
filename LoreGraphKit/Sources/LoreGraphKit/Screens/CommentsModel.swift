import Foundation
import Observation

/// One page's comments (loregraph ADR D-84): the highlights in its text and the conversation
/// beside it. Comments are notes, not lore: adding, answering and resolving them changes no page
/// and opens no edit tag, and needs only `lore:read`. Without a connection, changes are kept on
/// the phone and shown at once, marked as waiting, and sent when the server is back.
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
    /// The page's title and a section's heading, for the list of changes waiting to be sent.
    @ObservationIgnored public var describe: (_ section: String?) -> (page: String?, heading: String?) = { _ in (nil, nil) }
    @ObservationIgnored public let context: ReadContext

    public init(ref: String, context: ReadContext) {
        self.ref = ref
        self.context = context
        loader = context.loader(API.comments(on: ref, viewAs: context.view.viewAs))
        context.offline?.watch(self)
    }

    public func load() async { await loader.load() }
    public func refresh() async { await loader.refresh() }

    /// The server's comments with this phone's waiting changes laid over them.
    public var all: [PageComment] {
        Self.overlay(loader.value?.comments ?? [], context.offline?.pending(world: context.world) ?? [], page: ref)
    }
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

    /// A comment on a passage (or, without one, on the whole section). Returns the new comment
    /// (offline: the one waiting to be sent).
    @discardableResult
    public func add(section: String, picked: Anchors.Picked?, body: String) async -> PageComment? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let about = describe(section)
        let q = queued(.add, section: section, heading: about.heading, quote: picked?.quote, prefix: picked?.prefix,
                       suffix: picked?.suffix, body: text)
        guard await perform(q) else { return nil }
        return comment(q.localID) ?? lastSent
    }

    @discardableResult
    public func reply(to id: String, body: String, resolve: Bool = false) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await perform(queued(.reply, comment: id, body: text, resolve: resolve))
    }

    @discardableResult
    public func setResolved(_ id: String, _ resolved: Bool) async -> Bool {
        await perform(queued(resolved ? .resolve : .reopen, comment: id))
    }

    /// New text for the reader's own comment or reply (one not sent yet just takes the new text).
    @discardableResult
    public func edit(_ id: String, reply: String? = nil, body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let local = Self.queuedID(reply ?? id), let offline = context.offline {
            await offline.edit(local, body: text)
            return true
        }
        return await perform(queued(.edit, comment: id, reply: reply, body: text))
    }

    /// Deletes a comment with its replies, or one reply (one not sent yet is dropped).
    @discardableResult
    public func delete(_ id: String, reply: String? = nil) async -> Bool {
        if let local = Self.queuedID(reply ?? id), let offline = context.offline {
            await offline.discard(local)
            return true
        }
        return await perform(queued(.delete, comment: id, reply: reply))
    }

    /// Sends a change at once when nothing is waiting; keeps it for later when the server can't be
    /// reached or earlier changes are still waiting (so they arrive in order).
    private func perform(_ q: QueuedChange) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        if let offline = context.offline, offline.hasUnsent || q.waitsForAnother {
            await offline.queue(q)
            actionError = nil
            Task { await offline.flush() }
            return true
        }
        guard let change = q.change else { return false }
        do {
            let r = try await context.repository.client.send(change, world: context.world)
            actionError = nil
            warnings = r.warnings ?? []
            lastSent = r.comment
            if let c = r.comment { put(c) } else if q.kind == .delete, let id = q.comment { remove(id) }
            return true
        } catch {
            if let offline = context.offline, OfflineModel.unreachable(error) {
                await offline.queue(q)
                actionError = nil
                return true
            }
            actionError = (error as? APIError) ?? .offline("")
            return false
        }
    }

    @ObservationIgnored private var lastSent: PageComment?

    private func queued(_ kind: QueuedChange.Kind, comment: String? = nil, reply: String? = nil, section: String? = nil,
                        heading: String? = nil, quote: String? = nil, prefix: String? = nil, suffix: String? = nil,
                        body: String? = nil, resolve: Bool? = nil) -> QueuedChange {
        let target = comment.flatMap { self.comment($0) }
        return QueuedChange(kind: kind, world: context.world, page: ref, pageTitle: describe(nil).page, comment: comment, reply: reply,
                            section: section ?? target?.section.key, sectionHeading: heading ?? target?.section.heading,
                            quote: quote, prefix: prefix, suffix: suffix, body: body, resolve: resolve == true ? true : nil,
                            queuedAt: context.repository.now())
    }

    /// The queued change behind a local id (`queued-…`).
    static func queuedID(_ id: String) -> String? {
        QueuedChange.isLocal(id) ? String(id.dropFirst(QueuedChange.prefix.count)) : nil
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

    /// The server's comments as they will be once the waiting changes are sent: new comments on
    /// this page at the end, replies under their comment, resolves, edits and deletes applied.
    /// Every changed comment or reply carries its `queued` mark.
    public static func overlay(_ server: [PageComment], _ queue: [QueuedChange], page: String) -> [PageComment] {
        var out = server
        for q in queue {
            let mark = PageComment.QueueMark(q)
            let at = Self.iso(q.queuedAt)
            if q.kind == .add {
                guard q.page == page, let section = q.section else { continue }
                let anchor = q.quote.map {
                    PageComment.Anchor(status: .exact, quote: $0, text: $0, prefix: q.prefix, suffix: q.suffix)
                } ?? PageComment.Anchor(status: .section)
                out.append(PageComment(
                    id: q.localID, page: nil,
                    section: PageComment.SectionRef(id: nil, key: section, heading: q.sectionHeading, exists: true, generated: nil),
                    anchor: anchor, status: .open, visibility: .restricted, bodyMd: q.body ?? "",
                    author: PageComment.Author(name: nil, via: nil, mine: true), createdAt: at, editedAt: nil, updatedAt: at,
                    resolvedAt: nil, resolvedBy: nil, replies: [], version: nil, canEdit: true, canDelete: true, uiUrl: nil,
                    queued: mark))
                continue
            }
            guard let i = out.firstIndex(where: { $0.id == q.comment }) else { continue }
            switch q.kind {
            case .add:
                break
            case .reply:
                out[i].replies.append(PageComment.Reply(id: q.localID, bodyMd: q.body ?? "", visibility: out[i].visibility,
                                                        author: PageComment.Author(name: nil, via: nil, mine: true),
                                                        createdAt: at, editedAt: nil, canEdit: true, canDelete: true, queued: mark))
                if q.resolve == true {
                    out[i].status = .resolved
                    out[i].resolvedBy = "you"
                }
            case .resolve, .reopen:
                out[i].status = q.kind == .resolve ? .resolved : .open
                out[i].resolvedBy = q.kind == .resolve ? "you" : nil
                if out[i].queued == nil { out[i].queued = mark }
            case .edit:
                if let reply = q.reply {
                    if let j = out[i].replies.firstIndex(where: { $0.id == reply }) {
                        out[i].replies[j].bodyMd = q.body ?? out[i].replies[j].bodyMd
                        out[i].replies[j].editedAt = at
                        out[i].replies[j].queued = mark
                    }
                } else {
                    out[i].bodyMd = q.body ?? out[i].bodyMd
                    out[i].editedAt = at
                    out[i].queued = mark
                }
            case .delete:
                if let reply = q.reply {
                    out[i].replies.removeAll { $0.id == reply }
                } else {
                    out.remove(at: i)
                }
            }
        }
        return out
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
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
