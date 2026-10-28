import Foundation
import Observation

/// The timeline (F-6): a reading list by decade, or a strip you pinch to zoom, optionally in
/// lanes, with claims shown or not.
@Observable
@MainActor
public final class TimelineModel {
    public enum Display: String, CaseIterable, Sendable, Identifiable {
        case list, strip

        public var id: String { rawValue }
        public var label: String { self == .list ? "List" : "Strip" }
    }

    public private(set) var options: TimelineOptions
    public private(set) var loader: Loader<Timeline>
    public var display: Display = .list
    /// The strip's visible years; nil shows everything.
    public var window: TimeWindow?
    public var selected: String?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored private var memo: (items: [Timeline.Item], layout: TimelineLayout)?

    public init(options: TimelineOptions, context: ReadContext) {
        self.options = options
        self.context = context
        loader = context.loader(Self.endpoint(options))
    }

    static func endpoint(_ o: TimelineOptions) -> Endpoint<Timeline> {
        API.timeline(about: o.about, from: o.from, to: o.to, lanes: o.lanes, claims: o.claims)
    }

    public func load() async { await loader.load() }

    public func refresh() async { await loader.refresh() }

    public func set(_ options: TimelineOptions) async {
        guard options != self.options else { return }
        self.options = options
        window = nil
        loader = context.loader(Self.endpoint(options))
        await loader.load()
    }

    /// The layout of the current items, made once per answer.
    public var layout: TimelineLayout? {
        guard let items = loader.value?.items else { return nil }
        if let memo, memo.items == items { return memo.layout }
        let layout = TimelineLayout(items: items, present: context.present)
        memo = (items, layout)
        return layout
    }

    /// The window the strip shows.
    public var shownWindow: TimeWindow? { window ?? layout?.extent }

    /// Pinch on the strip around a year.
    public func zoom(by factor: Double, around year: Double) {
        guard let layout, let w = shownWindow else { return }
        window = w.zoomed(by: factor, around: year, within: layout.extent)
    }

    /// Drag on the strip by a number of years.
    public func pan(by years: Double) {
        guard let layout, let w = shownWindow else { return }
        window = w.panned(by: years, within: layout.extent)
    }

    public var item: Timeline.Item? { loader.value?.items.first { $0.id == selected } }

    public var shareURL: URL { context.shareURL(.timeline(options)) }
}

/// The family tree (F-8): drawn around a person, with the kinship between the root and a second
/// person picked on the tree.
@Observable
@MainActor
public final class FamilyModel {
    public let ref: String
    public private(set) var options: FamilyOptions
    public private(set) var loader: Loader<FamilyTree>
    /// The second person, for kinship (F-8.6).
    public private(set) var selected: String?
    public private(set) var kinship: Loader<Kinship>?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored private var memo: (tree: FamilyTree, year: Double?, layout: FamilyLayout)?

    public init(ref: String, options: FamilyOptions = FamilyOptions(), context: ReadContext) {
        self.ref = ref
        self.options = options
        self.context = context
        loader = context.loader(Self.endpoint(ref, options))
    }

    static func endpoint(_ ref: String, _ o: FamilyOptions) -> Endpoint<FamilyTree> {
        API.familyTree(ref, up: o.up, down: o.down, mode: o.mode.rawValue, account: o.account)
    }

    public func load() async { await loader.load() }

    public func refresh() async {
        await loader.refresh()
        if let kinship { await kinship.refresh() }
    }

    public func set(_ options: FamilyOptions) async {
        guard options != self.options else { return }
        self.options = options
        loader = context.loader(Self.endpoint(ref, options))
        await loader.load()
    }

    /// Generations up and down, within the server's limits.
    public func more(up: Int = 0, down: Int = 0) async {
        var o = options
        o.up = max(0, min(10, o.up + up))
        o.down = max(0, min(10, o.down + down))
        await set(o)
    }

    /// The year the tree is drawn at: the view's, else the present.
    public var year: Double { context.view.asOf ?? context.present }

    public var layout: FamilyLayout? {
        guard let tree = loader.value else { return nil }
        if let memo, memo.tree == tree, memo.year == year { return memo.layout }
        let layout = FamilyLayout(tree: tree, year: year)
        memo = (tree, year, layout)
        return layout
    }

    /// The root person's ref as the tree names it.
    public var rootRef: String { loader.value?.root.ref ?? ref }

    /// Picks a second person to see how they are related; picking the root or the same person
    /// again clears it.
    public func select(_ person: String?) async {
        guard let person, person != rootRef, person != selected else {
            selected = nil
            kinship = nil
            return
        }
        selected = person
        let k = context.loader(API.kinship(rootRef, person))
        kinship = k
        await k.load()
    }

    /// The lines to highlight: the kinship path between the two.
    public var highlighted: [FamilyLayout.Line] {
        guard let path = kinship?.value?.path?.map(\.ref), path.count > 1, let layout else { return [] }
        return layout.lines(along: path)
    }

    public var shareURL: URL { context.shareURL(.family(ref, options), selected: selected) }
}

/// The graph (F-9): a neighbourhood around the pages in focus, grown by expanding nodes, laid
/// out by force, filtered by link family, with claims hidden unless asked for.
@Observable
@MainActor
public final class GraphModel {
    public private(set) var options: GraphOptions
    /// Link families shown; empty shows them all (F-9.2).
    public private(set) var families: Set<String> = []
    public private(set) var claims = false
    public private(set) var loader: Loader<Neighbourhood>?
    public private(set) var expansions: [Neighbourhood] = []
    public private(set) var positions: [String: Point] = [:]
    public private(set) var isLayingOut = false
    public private(set) var expandError: APIError?
    public var selected: String?
    public private(set) var paths: Loader<GraphPaths>?
    @ObservationIgnored public let context: ReadContext
    @ObservationIgnored var layoutEngine = ForceLayout()

    public init(options: GraphOptions, context: ReadContext) {
        self.options = options
        self.context = context
        rebuildLoader()
        if options.path.count == 2 { paths = context.loader(API.paths(from: options.path[0], to: options.path[1])) }
    }

    private func rebuildLoader() {
        guard !options.focus.isEmpty else {
            loader = nil
            return
        }
        loader = context.loader(API.neighbourhood(roots: options.focus, depth: options.depth,
                                                  families: Array(families).sorted(), claims: claims))
    }

    public func load() async {
        await loader?.load()
        await paths?.load()
        await layout()
    }

    public func refresh() async {
        expansions = []
        await loader?.refresh()
        await paths?.refresh()
        await layout()
    }

    /// Starts again from other pages, depth or filters.
    public func set(focus: [String]? = nil, depth: Int? = nil, families: Set<String>? = nil, claims: Bool? = nil) async {
        if let focus { options.focus = focus }
        if let depth { options.depth = max(1, min(3, depth)) }
        if let families { self.families = families }
        if let claims { self.claims = claims }
        expansions = []
        positions = [:]
        selected = nil
        rebuildLoader()
        await load()
    }

    /// Adds a node's neighbours to the graph (F-9.3).
    public func expand(_ nodeID: String) async {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
        do {
            let more = try await context.repository.fetch(
                API.neighbourhood(roots: [node.ref], depth: 1, families: Array(families).sorted(), claims: claims),
                world: context.world, view: context.view).value
            expansions.append(more)
            expandError = nil
            await layout()
        } catch let e as APIError {
            expandError = e
        } catch {
            expandError = .offline("")
        }
    }

    /// The paths between two pages (F-9.5).
    public func findPaths(from a: String, to b: String) async {
        options.path = [a, b]
        let p = context.loader(API.paths(from: a, to: b))
        paths = p
        await p.load()
    }

    public func clearPaths() {
        options.path = []
        paths = nil
    }

    /// Every node, the neighbourhood's then the expansions', once each.
    public var nodes: [Neighbourhood.Node] {
        var seen = Set<String>()
        var out: [Neighbourhood.Node] = []
        for n in (loader?.value?.nodes ?? []) + expansions.flatMap(\.nodes) where !seen.contains(n.id) {
            seen.insert(n.id)
            out.append(n)
        }
        return out
    }

    /// Every edge between shown nodes, once each, claims only when asked for.
    public var edges: [Neighbourhood.Edge] {
        let ids = Set(nodes.map(\.id))
        var seen = Set<String>()
        var out: [Neighbourhood.Edge] = []
        for e in (loader?.value?.edges ?? []) + expansions.flatMap(\.edges) where !seen.contains(e.id) {
            guard ids.contains(e.source), ids.contains(e.target) else { continue }
            if e.isClaim && !claims { continue }
            if !families.isEmpty, !families.contains(e.family ?? "") { continue }
            seen.insert(e.id)
            out.append(e)
        }
        return out
    }

    /// The edges of the selected node, for its card.
    public var selectedEdges: [Neighbourhood.Edge] {
        guard let selected else { return [] }
        return edges.filter { $0.source == selected || $0.target == selected }
    }

    public var truncated: Bool { loader?.value?.truncated == true || expansions.contains { $0.truncated == true } }

    /// Lays the graph out again, keeping placed nodes where they were (off the main thread).
    public func layout() async {
        let ids = nodes.map(\.id)
        guard !ids.isEmpty else {
            positions = [:]
            return
        }
        let edgePairs = edges.map { ($0.source, $0.target) }
        let focusIDs = Set(nodes.filter { options.focus.contains($0.ref) || options.focus.contains($0.id) }.map(\.id))
        let pinned = positions.isEmpty ? Set(focusIDs.prefix(1)) : focusIDs.intersection(positions.keys)
        let initial = positions
        let engine = layoutEngine
        isLayingOut = true
        let result = await Task.detached(priority: .userInitiated) {
            engine.run(nodes: ids, edges: edgePairs, initial: initial, pinned: pinned)
        }.value
        positions = result
        isLayingOut = false
    }

    public var shareURL: URL { context.shareURL(.graph(options)) }
}
