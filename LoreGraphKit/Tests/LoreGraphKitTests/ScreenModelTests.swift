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
            "dirk": [.family, .beliefs, .records, .links],
            "lampton": [.map, .beliefs, .records, .links],
            "battle-at-the-ford": [.map, .accounts, .records, .links],
            "testmark": [.faction, .beliefs, .records, .links],
            "testmark-chronicle": [.records, .links],
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

    @Test func browsesACategory() async {
        let stack = Stack()
        let model = BrowseModel(type: nil, category: "river", context: stack.context())
        await model.load()
        #expect(model.category == "river" && model.items.count == 28)
        #expect(stack.server.requests.last?.query["category"] == ["river"])
        await model.set(type: .individual, sort: .updated)
        #expect(stack.server.requests.last?.query["category"] == ["river"])
        #expect(stack.server.requests.last?.query["sort"] == ["updated"])
        await model.loadMore()
        #expect(stack.server.requests.last?.query["category"] == ["river"])
        #expect(stack.server.requests.last?.query["cursor"] == ["eyJvIjo1fQ"])
        // browsing by type alone sends no category
        let all = BrowseModel(type: .event, context: stack.context())
        await all.load()
        #expect(all.category == nil && stack.server.requests.last?.query["category"] == nil)
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

extension Stack {
    func status(_ path: String, _ status: Int, query: [String: String] = [:]) { server.status(path, status, query: query) }
    func raw(_ path: String, _ json: String, query: [String: String] = [:]) { server.raw(path, json, query: query) }
}
