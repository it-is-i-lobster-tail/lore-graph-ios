import Foundation
import Observation

/// A way on from a page to another screen (F-4.9).
public enum PageAction: String, Hashable, Sendable, CaseIterable, Identifiable {
    case records, links, family, faction, graph, timeline, map, accounts, beliefs

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .records: "Records"
        case .links: "What links here"
        case .family: "Family tree"
        case .faction: "Faction tree"
        case .graph: "Graph"
        case .timeline: "Timeline"
        case .map: "Map"
        case .accounts: "Compare accounts"
        case .beliefs: "Beliefs"
        }
    }

    public var symbol: String {
        switch self {
        case .records: "list.bullet.rectangle"
        case .links: "arrow.uturn.backward"
        case .family: "figure.2.and.child.holdinghands"
        case .faction: "point.3.connected.trianglepath.dotted"
        case .graph: "circle.hexagongrid"
        case .timeline: "calendar.day.timeline.left"
        case .map: "map"
        case .accounts: "text.book.closed"
        case .beliefs: "brain.head.profile"
        }
    }

    /// The screen for a page.
    public func route(_ ref: String) -> Route {
        switch self {
        case .records: .records(ref)
        case .links: .links(ref)
        case .family: .family(ref, FamilyOptions())
        case .faction: .faction(ref)
        case .graph: .graph(GraphOptions(focus: [ref]))
        case .timeline: .timeline(TimelineOptions(about: [ref]))
        case .map: .map(MapOptions(select: ref))
        case .accounts: .compare(ref)
        case .beliefs: .beliefs(ref)
        }
    }

    /// The ways on that fit a page.
    public static func actions(for page: EntityDetail) -> [PageAction] {
        var out: [PageAction] = []
        let type = page.entity.type
        if type == .individual { out.append(.family) }
        if type == .faction { out.append(.faction) }
        if type == .location || page.locatorPoint != nil || !(page.shapes ?? []).isEmpty { out.append(.map) }
        out.append(.timeline)
        out.append(.graph)
        if type == .event { out.append(.accounts) }
        if [.individual, .faction, .location].contains(type) { out.append(.beliefs) }
        out += [.records, .links]
        return out
    }
}

/// A wiki page (F-4.5): the page itself, its text parsed once per section, and what links to it.
@Observable
@MainActor
public final class PageModel {
    public let ref: String
    public let page: Loader<EntityDetail>
    public private(set) var backlinks: Loader<Backlinks>?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored private var parsed: [String: (html: String, blocks: [Block])] = [:]

    public init(ref: String, context: ReadContext) {
        self.ref = ref
        self.context = context
        self.page = context.loader(API.entity(ref))
    }

    public func load() async {
        await page.load()
    }

    /// Pull to refresh: the page and, if open, its links.
    public func refresh() async {
        await page.refresh()
        if let backlinks { await backlinks.refresh() }
    }

    public func loadBacklinks() async {
        if backlinks == nil { backlinks = context.loader(API.backlinks(ref)) }
        await backlinks?.load()
    }

    /// A section's text as blocks, parsed once for each version of its HTML.
    public func blocks(_ section: EntityDetail.Section) -> [Block] {
        let html = section.html ?? ""
        if let hit = parsed[section.id], hit.html == html { return hit.blocks }
        let blocks = HTMLContent.parse(html)
        parsed[section.id] = (html, blocks)
        return blocks
    }

    public var title: String { page.value.map { $0.entity.displayTitle ?? $0.entity.title } ?? ref }

    public var actions: [PageAction] { page.value.map(PageAction.actions(for:)) ?? [] }

    public var shareURL: URL { context.shareURL(.page(page.value?.entity.slug ?? ref)) }

    /// The record of when the page was opened, for the recent list.
    public var card: EntityCard? { page.value?.entity.card }
}

/// Browsing pages by type (F-4.2), a page of fifty at a time.
@Observable
@MainActor
public final class BrowseModel {
    public enum Sort: String, CaseIterable, Sendable, Identifiable {
        case title, updated

        public var id: String { rawValue }
        public var label: String { self == .title ? "A to Z" : "Recently changed" }
        var wire: String { rawValue }
    }

    public private(set) var type: EntityType?
    public private(set) var sort: Sort = .title
    public private(set) var first: Loader<Page<EntityListItem>>
    public private(set) var more: [EntityListItem] = []
    public private(set) var nextCursor: String?
    public private(set) var isLoadingMore = false
    public private(set) var moreError: APIError?
    @ObservationIgnored public let context: ReadContext

    public init(type: EntityType?, context: ReadContext) {
        self.type = type
        self.context = context
        first = context.loader(API.entities(type: type, sort: Sort.title.wire))
    }

    public var items: [EntityListItem] { (first.value?.items ?? []) + more }

    public var canLoadMore: Bool { (more.isEmpty ? first.value?.nextCursor : nextCursor) != nil }

    public func load() async {
        await first.load()
    }

    public func refresh() async {
        more = []
        nextCursor = nil
        await first.refresh()
    }

    public func set(type: EntityType?, sort: Sort) async {
        guard type != self.type || sort != self.sort else { return }
        self.type = type
        self.sort = sort
        more = []
        nextCursor = nil
        first = context.loader(API.entities(type: type, sort: sort.wire))
        await first.load()
    }

    public func loadMore() async {
        guard !isLoadingMore, let cursor = more.isEmpty ? first.value?.nextCursor : nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = try await context.repository.fetch(API.entities(type: type, sort: sort.wire, cursor: cursor),
                                                          world: context.world, view: context.view).value
            more += next.items
            nextCursor = next.nextCursor
            moreError = nil
        } catch let e as APIError {
            moreError = e
        } catch {
            moreError = .offline("")
        }
    }
}

/// Search (F-10): suggestions as you type, full results with passages on submit.
@Observable
@MainActor
public final class SearchModel {
    public var text = ""
    public var types: Set<EntityType> = []
    public private(set) var suggestions: [Suggestions.Candidate] = []
    public private(set) var results: Loader<SearchResults>?
    public private(set) var submitted: String?
    @ObservationIgnored public let context: ReadContext

    public init(context: ReadContext, text: String = "") {
        self.context = context
        self.text = text
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Suggestions for the text so far (call after a short pause in typing). Never cached.
    public func suggest() async {
        let q = trimmed
        guard q.count >= 2 else {
            suggestions = []
            return
        }
        let answer = try? await context.repository.client.get(API.suggest(q, types: Array(types).sorted { $0.rawValue < $1.rawValue }),
                                                              world: context.world, view: context.view).value
        guard q == trimmed else { return }
        suggestions = answer?.candidates ?? []
    }

    /// Runs the full search for the text.
    public func submit() async {
        let q = trimmed
        guard !q.isEmpty else { return }
        submitted = q
        suggestions = []
        let loader = context.loader(API.search(q, types: Array(types).sorted { $0.rawValue < $1.rawValue }))
        results = loader
        await loader.load()
    }

    public func refresh() async {
        await results?.refresh()
    }

    public func clear() {
        text = ""
        submitted = nil
        results = nil
        suggestions = []
    }
}
