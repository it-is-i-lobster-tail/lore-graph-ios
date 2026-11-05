import Foundation
import Observation

/// A reading list (loregraph ADR D-83): the whole wiki in reading order with the reader's
/// progress, read page by page. Marks are the reader's own bookkeeping: they change no lore and
/// open no edit tag, and need only `lore:read`.
@Observable
@MainActor
public final class ReadingModel {
    public enum Filter: String, CaseIterable, Sendable, Identifiable {
        case all, unread, changed

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .all: "All"
            case .unread: "Unread"
            case .changed: "Changed"
            }
        }
    }

    /// The list shown (nil: the reader's newest).
    public private(set) var listID: String?
    public private(set) var loader: Loader<ReadingList>
    public var filter: Filter = .all
    /// Pages after the first answer's, when a list holds more than one answer carries.
    public private(set) var more: [ReadingList.Item] = []
    public private(set) var isWorking = false
    /// The last change that failed (shown over the list; the list itself is unchanged).
    public var actionError: APIError?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored private let limit: Int

    public init(list: String? = nil, context: ReadContext, limit: Int = 5000) {
        listID = list
        self.context = context
        self.limit = limit
        loader = context.loader(API.readingList(list, limit: limit))
    }

    public func load() async { await loader.load() }

    public func refresh() async {
        more = []
        await loader.refresh()
    }

    // MARK: what the list holds

    public var list: ReadingList? { loader.value }
    public var info: ReadingList.Info? { list?.readingList }
    /// The reader has no reading list in this world yet.
    public var isEmpty: Bool { loader.value != nil && info == nil }
    public var progress: ReadingList.Progress? { list?.progress }
    public var parts: [ReadingList.Part] { list?.parts ?? [] }
    public var upNext: ReadingList.Item? { list?.upNext }
    public var items: [ReadingList.Item] { (list?.items ?? []) + more }
    public var canLoadMore: Bool { (more.isEmpty ? list?.nextCursor : moreCursor) != nil }
    @ObservationIgnored private var moreCursor: String?

    /// The pages of a part that pass the filter, in order.
    public func items(in part: ReadingList.Part) -> [ReadingList.Item] {
        items.filter { $0.part == part.key && passes($0) }
    }

    func passes(_ i: ReadingList.Item) -> Bool {
        switch filter {
        case .all: true
        case .unread: !i.isRead
        case .changed: i.changed
        }
    }

    /// The parts with any page that passes the filter.
    public var shownParts: [ReadingList.Part] { parts.filter { !items(in: $0).isEmpty } }

    public func item(_ ref: String) -> ReadingList.Item? {
        items.first { $0.page.ref == ref || $0.page.id == ref }
    }

    /// The page before or after one, in the list's order.
    public func neighbour(of ref: String, by step: Int) -> ReadingList.Item? {
        let all = items
        guard let i = all.firstIndex(where: { $0.page.ref == ref || $0.page.id == ref }) else { return nil }
        let j = i + step
        return all.indices.contains(j) ? all[j] : nil
    }

    /// Time left in words: "about 2 h 5 min", "about 4 min".
    public static func timeLeft(_ minutes: Int) -> String {
        let (h, m) = (minutes / 60, minutes % 60)
        if h > 0 { return m > 0 ? "about \(h) h \(m) min" : "about \(h) h" }
        return "about \(max(m, 0)) min"
    }

    /// The moment the list was built, as the server wrote it, for "built on …".
    public var builtAt: Date? { info?.createdAt.flatMap(Self.parseDate) }

    /// A server time (ISO 8601, with or without fractions of a second).
    public static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: changes

    public func loadMore() async {
        guard let cursor = more.isEmpty ? list?.nextCursor : moreCursor, let id = info?.id else { return }
        do {
            let next = try await context.repository.client.get(API.readingList(id, limit: limit, cursor: cursor),
                                                               world: context.world).value
            more += next.items
            moreCursor = next.nextCursor
        } catch let e as APIError {
            actionError = e
        } catch {
            actionError = .offline("")
        }
    }

    /// Marks pages read (or unread again). The answer's progress and next page are shown at once.
    @discardableResult
    public func mark(_ refs: [String], read: Bool = true) async -> ReadingMarkResult? {
        guard let id = info?.id, !refs.isEmpty else { return nil }
        guard let result = await run({ try await $0.send(API.markRead(list: id, refs: refs, read: read), world: $1) }) else {
            return nil
        }
        apply(result)
        return result
    }

    func apply(_ r: ReadingMarkResult) {
        guard var value = loader.value else { return }
        let changed = Dictionary(r.items.map { ($0.page.id, $0) }, uniquingKeysWith: { a, _ in a })
        func update(_ items: inout [ReadingList.Item]) {
            for k in items.indices {
                if let c = changed[items[k].page.id] {
                    items[k].readAt = c.readAt
                    items[k].changed = c.changed
                }
            }
        }
        update(&value.items)
        update(&more)
        value.progress = r.progress
        value.parts = r.parts
        value.upNext = r.upNext
        loader.show(value)
    }

    /// Builds a new list of the whole world (the server's order and defaults) and shows it.
    @discardableResult
    public func build(title: String? = nil) async -> Bool {
        guard let r = await run({ try await $0.send(API.buildReadingList(title: title), world: $1) }),
              let built = r.readingList else { return false }
        await open(built.id)
        return true
    }

    /// Adds the pages made or approved since the list was built to its end, keeping every mark.
    public func addNewPages() async {
        guard let id = info?.id, await run({ try await $0.send(API.addNewPages(to: id), world: $1) }) != nil else { return }
        await refresh()
    }

    public func rename(_ title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = info?.id, !t.isEmpty,
              await run({ try await $0.send(API.renameReadingList(id, title: t), world: $1) }) != nil else { return }
        if var v = loader.value {
            v.readingList?.title = t
            if let i = v.lists.firstIndex(where: { $0.id == id }) { v.lists[i].title = t }
            loader.show(v)
        }
    }

    /// Deletes the list shown and its marks, then shows the reader's newest list (if any).
    public func delete() async {
        guard let id = info?.id, await run({ try await $0.send(API.deleteReadingList(id), world: $1) }) != nil else { return }
        await open(nil)
    }

    /// Shows another of the reader's lists.
    public func open(_ id: String?) async {
        listID = id
        more = []
        moreCursor = nil
        loader = context.loader(API.readingList(id, limit: limit))
        await loader.refresh()
    }

    /// What changed on a page since the reader read it: the page with each section's word diff.
    public func changes(_ item: ReadingList.Item) -> Loader<EntityDetail>? {
        guard item.changed, let since = item.readAt else { return nil }
        return context.loader(API.entity(item.page.ref, diffSince: since))
    }

    private func run<T: Sendable>(_ send: @Sendable (APIClient, String?) async throws -> T) async -> T? {
        isWorking = true
        defer { isWorking = false }
        do {
            let r = try await send(context.repository.client, context.world)
            actionError = nil
            return r
        } catch let e as APIError {
            actionError = e
        } catch {
            actionError = .offline("")
        }
        return nil
    }
}
