import Foundation
import Testing
@testable import LoreGraphKit

extension FakeServer {
    /// A route answering with JSON written out in the test.
    func raw(_ path: String, _ json: String, query: [String: String] = [:], status: Int = 200) {
        let body = Data(json.utf8)
        on(path, query: query) { _ in HTTPResponse(status: status, body: body) }
    }
}

@Suite @MainActor struct PageModelTests {
    @Test func actionsFitThePage() async {
        let stack = Stack()
        let expected: [String: [PageAction]] = [
            "dirk": [.family, .timeline, .graph, .beliefs, .records, .links],
            "lampton": [.map, .timeline, .graph, .beliefs, .records, .links],
            "battle-at-the-ford": [.map, .timeline, .graph, .accounts, .records, .links],
            "testmark": [.faction, .timeline, .graph, .beliefs, .records, .links],
            "testmark-chronicle": [.timeline, .graph, .records, .links],
        ]
        for (ref, actions) in expected {
            let model = PageModel(ref: ref, context: stack.context())
            await model.load()
            #expect(model.actions == actions, "\(ref)")
        }
        for a in PageAction.allCases {
            #expect(a.id == a.rawValue && !a.label.isEmpty && !a.symbol.isEmpty)
        }
        #expect(PageAction.records.route("dirk") == .records("dirk"))
        #expect(PageAction.links.route("dirk") == .links("dirk"))
        #expect(PageAction.family.route("dirk") == .family("dirk", FamilyOptions()))
        #expect(PageAction.faction.route("testmark") == .faction("testmark"))
        #expect(PageAction.graph.route("dirk") == .graph(GraphOptions(focus: ["dirk"])))
        #expect(PageAction.timeline.route("dirk") == .timeline(TimelineOptions(about: ["dirk"])))
        #expect(PageAction.map.route("lampton") == .map(MapOptions(select: "lampton")))
        #expect(PageAction.accounts.route("battle-at-the-ford") == .compare("battle-at-the-ford"))
        #expect(PageAction.beliefs.route("dirk") == .beliefs("dirk"))
    }

    @Test func loadsThePageItsTextAndItsLinks() async throws {
        let stack = Stack()
        let model = PageModel(ref: "dirk", context: stack.context())
        #expect(model.title == "dirk" && model.actions.isEmpty && model.card == nil)
        #expect(model.shareURL.absoluteString.contains("dirk"))
        await model.load()
        #expect(model.title == "Dirk")
        #expect(model.card?.ref == "dirk")
        #expect(model.shareURL.absoluteString.hasPrefix(testServer.absoluteString))

        var section = try #require(model.page.value?.sections?.first { ($0.html ?? "").isEmpty == false })
        let blocks = model.blocks(section)
        #expect(!blocks.isEmpty)
        #expect(model.blocks(section) == blocks)
        section.html = "<p>Changed</p>"
        #expect(model.blocks(section) == HTMLContent.parse("<p>Changed</p>"))
        section.html = nil
        #expect(model.blocks(section).isEmpty)

        #expect(model.backlinks == nil)
        await model.loadBacklinks()
        #expect(model.backlinks?.value != nil)
        await model.loadBacklinks()
        let pages = stack.server.count("/entities/dirk")
        let links = stack.server.count("/entities/dirk/backlinks")
        await model.refresh()
        #expect(stack.server.count("/entities/dirk") == pages + 1)
        #expect(stack.server.count("/entities/dirk/backlinks") == links + 1)
    }

    @Test func refreshWithoutLinksReadsOnlyThePage() async {
        let stack = Stack()
        let model = PageModel(ref: "lampton", context: stack.context())
        await model.load()
        await model.refresh()
        #expect(stack.server.count("/entities/lampton/backlinks") == 0)
        #expect(model.page.value?.entity.ref == "lampton")
    }
}

@Suite @MainActor struct BrowseModelTests {
    @Test func browsesSortsAndPages() async {
        let stack = Stack()
        stack.server.json("/entities", "entities-list", query: ["cursor": "eyJvIjo1fQ"])
        let model = BrowseModel(type: nil, context: stack.context())
        #expect(model.items.isEmpty && !model.canLoadMore)
        await model.load()
        #expect(model.items.count == 28)
        #expect(!model.canLoadMore)
        await model.loadMore()
        #expect(model.items.count == 28)

        await model.set(type: .individual, sort: .title)
        #expect(model.type == .individual && model.items.count == 5 && model.canLoadMore)
        await model.set(type: .individual, sort: .title)
        #expect(stack.server.requests.filter { $0.query["type"] == ["individual"] }.count == 1)
        await model.loadMore()
        #expect(model.items.count == 33)
        #expect(!model.canLoadMore && model.nextCursor == nil && model.moreError == nil && !model.isLoadingMore)
        await model.loadMore()
        #expect(model.items.count == 33)

        await model.refresh()
        #expect(model.items.count == 5 && model.canLoadMore)

        await model.set(type: .individual, sort: .updated)
        #expect(model.sort == .updated)
        #expect(stack.server.requests.last?.query["sort"] == ["updated"])
        #expect(BrowseModel.Sort.title.label == "A to Z" && BrowseModel.Sort.updated.label == "Recently changed")
        #expect(BrowseModel.Sort.allCases.map(\.id) == ["title", "updated"])
    }

    @Test func aFailedPageIsShownAndCanBeRetried() async {
        let stack = Stack()
        stack.server.status("/entities", 500, query: ["cursor": "eyJvIjo1fQ"])
        let model = BrowseModel(type: .individual, context: stack.context())
        await model.load()
        await model.loadMore()
        #expect(model.moreError != nil)
        #expect(model.items.count == 5)
        stack.server.json("/entities", "entities-list", query: ["cursor": "eyJvIjo1fQ"])
        await model.loadMore()
        #expect(model.moreError == nil && model.items.count == 33)
    }
}

@Suite @MainActor struct SearchModelTests {
    @Test func suggestsSearchesAndClears() async {
        let stack = Stack()
        let model = SearchModel(context: stack.context(), text: "l")
        await model.suggest()
        #expect(model.suggestions.isEmpty)
        #expect(stack.server.count("/search/resolve") == 0)

        model.text = " lam "
        model.types = [.location, .event]
        await model.suggest()
        #expect(model.suggestions.first?.ref == "lampton")
        let sent = stack.server.requests.last
        #expect(sent?.query["q"] == ["lam"])

        model.text = "   "
        await model.submit()
        #expect(model.submitted == nil && model.results == nil)

        model.text = "ford"
        await model.submit()
        #expect(model.submitted == "ford" && model.suggestions.isEmpty)
        #expect(model.results?.value != nil)
        let before = stack.server.count("/search")
        await model.refresh()
        #expect(stack.server.count("/search") == before + 1)

        model.clear()
        #expect(model.text.isEmpty && model.submitted == nil && model.results == nil && model.suggestions.isEmpty)
        await model.refresh()
    }

    @Test func failedSuggestionsShowNothing() async {
        let stack = Stack()
        stack.server.status("/search/resolve", 500)
        let model = SearchModel(context: stack.context(), text: "lam")
        await model.suggest()
        #expect(model.suggestions.isEmpty)
    }
}

@Suite @MainActor struct TimelineModelTests {
    @Test func laysOutZoomsAndPans() async throws {
        let stack = Stack()
        let model = TimelineModel(options: TimelineOptions(), context: stack.context())
        #expect(model.layout == nil && model.shownWindow == nil && model.item == nil)
        model.zoom(by: 2, around: 1000)
        model.pan(by: 10)
        #expect(model.window == nil)

        await model.load()
        let layout = try #require(model.layout)
        #expect(model.layout?.extent == layout.extent)
        #expect(model.shownWindow == layout.extent)
        let mid = (layout.extent.from + layout.extent.to) / 2
        model.zoom(by: 4, around: mid)
        let zoomed = try #require(model.window)
        #expect(zoomed.to - zoomed.from < layout.extent.to - layout.extent.from)
        model.pan(by: -5)
        let panned = try #require(model.window)
        #expect(panned.from <= zoomed.from)

        let first = try #require(model.loader.value?.items.first)
        model.selected = first.id
        #expect(model.item?.id == first.id)
        #expect(TimelineModel.Display.list.label == "List" && TimelineModel.Display.strip.label == "Strip")
        #expect(TimelineModel.Display.allCases.map(\.id) == ["list", "strip"])

        await model.set(TimelineOptions())
        #expect(model.window != nil)
        await model.set(TimelineOptions(lanes: "type"))
        #expect(model.window == nil && model.options.lanes == "type")
        #expect(model.layout != nil)
        let count = stack.server.count("/timeline")
        await model.refresh()
        #expect(stack.server.count("/timeline") == count + 1)
        #expect(model.shareURL.absoluteString.contains("timeline"))
    }
}

@Suite @MainActor struct FamilyModelTests {
    @Test func drawsTheTreeAndTheKinship() async throws {
        let stack = Stack()
        let model = FamilyModel(ref: "dirk", context: stack.context())
        #expect(model.layout == nil && model.rootRef == "dirk" && model.highlighted.isEmpty)
        #expect(model.year == 1131.25)
        await model.load()
        let layout = try #require(model.layout)
        #expect(model.layout?.cards.count == layout.cards.count)

        await model.select(nil)
        #expect(model.selected == nil)
        await model.select("dirk")
        #expect(model.selected == nil && model.kinship == nil)
        await model.select("edwin")
        #expect(model.selected == "edwin")
        #expect(model.kinship?.value?.relationship == "parent's sibling")
        _ = model.highlighted
        #expect(model.shareURL.absoluteString.contains("edwin"))

        let kin = stack.server.count("/people/kinship")
        await model.refresh()
        #expect(stack.server.count("/people/kinship") == kin + 1)
        await model.select("edwin")
        #expect(model.selected == nil && model.kinship == nil)
        await model.refresh()
        #expect(stack.server.count("/people/kinship") == kin + 1)

        await model.more(up: 1)
        #expect(model.options.up == 3)
        await model.more(up: 20, down: -5)
        #expect(model.options.up == 10 && model.options.down == 0)
        let trees = stack.server.count("/people/dirk/family-tree")
        await model.more(up: 1)
        #expect(stack.server.count("/people/dirk/family-tree") == trees)
        #expect(model.shareURL.absoluteString.contains("dirk"))
    }

    @Test func drawsAtTheViewsYear() async {
        let stack = Stack()
        let model = FamilyModel(ref: "dirk", context: stack.context(view: ViewState(asOf: 1032)))
        #expect(model.year == 1032)
        await model.load()
        #expect(model.layout != nil)
    }

    @Test func highlightsTheKinshipPath() async throws {
        let stack = Stack()
        stack.raw("/people/kinship", """
        {"relationship": "father", "inverse": "son", "path": [
          {"ref": "dirk", "id": "00000000-0000-7000-8000-000000000023", "title": "Dirk"},
          {"ref": "cato", "id": "00000000-0000-7000-8000-000000000022", "title": "Cato"}]}
        """)
        let model = FamilyModel(ref: "dirk", context: stack.context())
        await model.load()
        await model.select("cato")
        let layout = try #require(model.layout)
        #expect(model.highlighted == layout.lines(along: ["dirk", "cato"]))
    }
}

private let expansion = """
{"nodes": [
  {"ref": "cato", "id": "00000000-0000-7000-8000-000000000022", "title": "Cato", "type": "individual", "visibility": "public"},
  {"ref": "mira", "id": "m-1", "title": "Mira", "type": "individual", "visibility": "public"}],
 "edges": [
  {"id": "e-claim", "source": "00000000-0000-7000-8000-000000000022", "target": "m-1", "predicate": "parent_of",
   "family": "kinship", "visibility": "public",
   "according_to": {"ref": "testmark-chronicle", "id": "s-1", "title": "Testmark Chronicle"}},
  {"id": "e-plain", "source": "00000000-0000-7000-8000-000000000022", "target": "m-1", "predicate": "knows",
   "family": "social", "visibility": "public"},
  {"id": "e-dangling", "source": "m-1", "target": "nobody", "predicate": "knows", "family": "social", "visibility": "public"}],
 "truncated": true}
"""

@Suite @MainActor struct GraphModelTests {
    let dirk = "00000000-0000-7000-8000-000000000023"
    let cato = "00000000-0000-7000-8000-000000000022"

    @Test func nothingInFocusDrawsNothing() async {
        let stack = Stack()
        let model = GraphModel(options: GraphOptions(), context: stack.context())
        await model.load()
        #expect(model.loader == nil && model.nodes.isEmpty && model.edges.isEmpty && model.positions.isEmpty)
        #expect(!model.truncated && model.selectedEdges.isEmpty)
        await model.refresh()
        #expect(stack.server.requests.isEmpty)
    }

    @Test func loadsLaysOutAndFilters() async {
        let stack = Stack()
        let model = GraphModel(options: GraphOptions(focus: ["dirk"], path: ["fenn", "dirk"]), context: stack.context())
        await model.load()
        #expect(model.nodes.count == 7 && model.edges.count == 7)
        #expect(model.positions.count == 7 && !model.isLayingOut)
        #expect(model.paths?.value?.paths.isEmpty == false)
        #expect(!model.truncated)
        model.selected = dirk
        #expect(model.selectedEdges.count == 6)

        await model.set(families: ["kinship"])
        #expect(model.selected == nil)
        #expect(model.edges.map(\.family) == ["kinship", "kinship"])
        #expect(stack.server.requests.last { $0.url.path.hasSuffix("/neighbourhood") }?.query["families"] == ["kinship"])
        await model.set(depth: 9)
        #expect(model.options.depth == 3)
        await model.set(depth: 0)
        #expect(model.options.depth == 1)
        await model.set(focus: ["cato"])
        #expect(model.options.focus == ["cato"])

        model.clearPaths()
        #expect(model.paths == nil && model.options.path.isEmpty)
        await model.findPaths(from: "fenn", to: "dirk")
        #expect(model.options.path == ["fenn", "dirk"] && model.paths?.value != nil)
        #expect(model.shareURL.absoluteString.contains("graph"))
    }

    @Test func expandsNodesAndShowsClaimsWhenAsked() async {
        let stack = Stack()
        stack.raw("/graph/neighbourhood", expansion, query: ["roots": "cato"])
        let model = GraphModel(options: GraphOptions(focus: ["dirk"]), context: stack.context())
        await model.load()
        let placed = model.positions
        await model.expand("nobody")
        #expect(model.expansions.isEmpty)
        await model.expand(cato)
        #expect(model.nodes.count == 8 && model.truncated)
        #expect(model.edges.contains { $0.id == "e-plain" })
        #expect(!model.edges.contains { $0.id == "e-claim" || $0.id == "e-dangling" })
        #expect(model.positions.count == 8)
        #expect(model.positions[dirk] == placed[dirk])

        await model.set(claims: true)
        #expect(model.claims && model.expansions.isEmpty)
        await model.expand(cato)
        #expect(model.edges.contains { $0.id == "e-claim" })

        await model.refresh()
        #expect(model.expansions.isEmpty && model.nodes.count == 7)
    }

    @Test func aFailedExpansionIsShown() async {
        let stack = Stack()
        stack.status("/graph/neighbourhood", 500, query: ["roots": "cato"])
        let model = GraphModel(options: GraphOptions(focus: ["dirk"]), context: stack.context())
        await model.load()
        await model.expand(cato)
        #expect(model.expandError != nil && model.expansions.isEmpty)
        stack.raw("/graph/neighbourhood", expansion, query: ["roots": "cato"])
        await model.expand(cato)
        #expect(model.expandError == nil && model.expansions.count == 1)
    }
}

extension Stack {
    func status(_ path: String, _ status: Int, query: [String: String] = [:]) { server.status(path, status, query: query) }
    func raw(_ path: String, _ json: String, query: [String: String] = [:]) { server.raw(path, json, query: query) }
}
