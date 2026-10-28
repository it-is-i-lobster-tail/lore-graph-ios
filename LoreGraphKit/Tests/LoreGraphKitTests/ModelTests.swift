import Foundation
import Testing
@testable import LoreGraphKit

@Suite struct CommonModelTests {
    @Test func visibilityIsOrderedAndUnknownIsPrivate() throws {
        #expect(Visibility.public < .restricted && Visibility.restricted < .designer)
        let decoded = try JSONDecoder().decode([Visibility].self, from: Data(#"["public","secret"]"#.utf8))
        #expect(decoded == [.public, .designer])
        #expect(Visibility.allCases.map(\.label) == ["Public", "Restricted", "Designer only"])
    }

    @Test func canonIsOpen() throws {
        let c = try JSONDecoder().decode([Canon].self, from: Data(#"["approved","author_canon","proposed","brand_new"]"#.utf8))
        #expect(c.map(\.isCanon) == [true, true, false, false])
        #expect(c.map(\.label) == ["Approved", "Author canon", "Proposed", "Brand_new"])
        #expect(String(decoding: try JSONEncoder().encode(Canon.retired), as: UTF8.self) == "\"retired\"")
        #expect(Canon.draft.rawValue == "draft")
    }

    @Test func entityTypesHaveWords() throws {
        #expect(try JSONDecoder().decode(EntityType.self, from: Data(#""dragon""#.utf8)) == .misc)
        for t in EntityType.allCases {
            #expect(!t.label.isEmpty && !t.plural.isEmpty && !t.symbol.isEmpty)
        }
        #expect(EntityType.individual.label == "Person")
        #expect(EntityType.story.plural == "Stories")
    }

    @Test func dateSpans() {
        let d = DateSpan(from: 1020, to: 1022, label: "YV 1020 to 1022")
        #expect(d.text == "YV 1020 to 1022")
        #expect(DateSpan(from: 1, to: nil, formatted: "since 1").text == "since 1")
        #expect(DateSpan(from: nil, to: nil).text == "")
        #expect(!d.isCirca)
        #expect(d.drawnRange == 1020...1022)
        let c = DateSpan(from: 1020, to: 1021, outer: .init(from: 1015, to: 1025))
        #expect(c.isCirca)
        #expect(c.drawnRange == 1015...1025)
        #expect(DateSpan(from: nil, to: 1000).drawnRange == 1000...1000)
        #expect(DateSpan(from: nil, to: nil).drawnRange == nil)
        #expect(d.contains(1020) && !d.contains(1022) && !d.contains(1019))
        #expect(DateSpan(from: nil, to: nil).contains(5))
    }

    @Test func cardsAndKinds() {
        var c = EntityCard(ref: "dirk", id: "1", title: "Dirk")
        #expect(c.shownTitle == "Dirk")
        c.displayTitle = "Grey Dirk"
        #expect(c.shownTitle == "Grey Dirk")
        c.nameHere = "The Marshal"
        #expect(c.shownTitle == "The Marshal")
        #expect(kindLabel("event.battle") == "Battle")
        #expect(kindLabel("location.trade_town") == "Trade town")
        #expect(kindLabel("") == nil)
        #expect(kindLabel(nil) == nil)
    }
}

@Suite struct FixtureDecodingTests {
    @Test func everyRecordedAnswerDecodes() throws {
        _ = try Fixture.decode(Me.self, "me")
        _ = try Fixture.decode(Me.self, "me.public")
        _ = try Fixture.decode(WorldList.self, "worlds")
        _ = try Fixture.decode(WorldList.self, "worlds.public")
        _ = try Fixture.decode(About.self, "about.public")
        _ = try Fixture.decode(HistoryHead.self, "history-latest.public")
        _ = try Fixture.decode(PageHistory.self, "history-dirk")
        _ = try Fixture.decode(Page<EntityListItem>.self, "entities-list")
        _ = try Fixture.decode(Page<EntityListItem>.self, "entities-list-individual")
        for f in ["entity-dirk", "entity-dirk.public", "entity-dirk-1055", "entity-lampton", "entity-battle", "entity-testmark",
                  "entity-chronicle", "entity-aldo-viewpoint"] {
            _ = try Fixture.decode(EntityDetail.self, f)
        }
        _ = try Fixture.decode(Backlinks.self, "backlinks-dirk")
        _ = try Fixture.decode(AccountList.self, "accounts-battle")
        _ = try Fixture.decode(SearchResults.self, "search-ford")
        _ = try Fixture.decode(Suggestions.self, "resolve-lam")
        _ = try Fixture.decode(StatementDetail.self, "statement-one")
        _ = try Fixture.decode(WhoKnows.self, "who-knows")
        _ = try Fixture.decode(Timeline.self, "timeline-dirk")
        _ = try Fixture.decode(FamilyTree.self, "family-cato")
        _ = try Fixture.decode(FamilyTree.self, "family-dirk.public")
        _ = try Fixture.decode(Neighbourhood.self, "graph-dirk.public")
        _ = try Fixture.decode(GraphPaths.self, "path")
        _ = try Fixture.decode(BeliefsOf.self, "beliefs-dirk")
        _ = try Fixture.decode(BeliefsOf.self, "beliefs-testmark")
        _ = try Fixture.decode(BeliefLineage.self, "lineage")
        _ = try Fixture.decode(BeliefHolders.self, "holders-ford")
        _ = try Fixture.decode(FactionTree.self, "faction-tree")
        _ = try Fixture.decode(Memberships.self, "memberships")
        _ = try Fixture.decode(PlacesAt.self, "map-at")
        _ = try Fixture.decode(PlacesAt.self, "map-at-1020")
        _ = try Fixture.decode(Distance.self, "map-distance")
        _ = try Fixture.decode(GeoJSONCollection.self, "features-derived")
        _ = try Fixture.decode(GeoJSONCollection.self, "features-ref")
        _ = try Fixture.decode(GeoJSONCollection.self, "territories")
        _ = try Fixture.decode(DateConversion.self, "dates-convert")
        _ = try Fixture.decode(MapVersion.self, "map-version")
        _ = try Fixture.decode(Problem.self, "problem-422")
        _ = try Fixture.decode(JSONValue.self, "protected-resource")
    }

    @Test func aboutAndAccount() throws {
        let about = try Fixture.decode(About.self, "about")
        #expect(about.presentYear == 1131.25)
        #expect(about.counts?.totalPages == 28)
        #expect(About().presentYear == 1131.25)
        #expect(About.Counts().totalPages == 0)
        var me = try Fixture.decode(Me.self, "me")
        #expect(me.seesSecrets)
        #expect(me.preferredCalendar == nil)
        me.preferences = ["calendar": .string("lc")]
        #expect(me.preferredCalendar == "lc")
        me.preferences = ["calendar": .string("yv")]
        #expect(me.preferredCalendar == nil)
        #expect(try !Fixture.decode(Me.self, "me.public").seesSecrets)
        let w = World(key: "k", name: "K", description: "d", isDefault: true, visibility: .public, pages: 3, present: "now")
        #expect(w.id == "k")
        #expect(try Fixture.decode(HistoryHead.self, "history-latest").newest?.id == 236)
        #expect(HistoryHead(groups: []).newest == nil)
    }

    @Test func entityPages() throws {
        let dirk = try Fixture.decode(EntityDetail.self, "entity-dirk")
        #expect(dirk.entity.card.ref == "dirk")
        #expect(dirk.shownSections.allSatisfy { !$0.isEmpty })
        #expect(dirk.shownSections.count < (dirk.sections ?? []).count)
        #expect(dirk.alsoKnownAs.allSatisfy { $0.kind != "primary" })
        #expect(dirk.locatorPoint == nil)
        #expect(dirk.infoboxImage == nil)
        let lampton = try Fixture.decode(EntityDetail.self, "entity-lampton")
        #expect(lampton.locatorPoint?.lon == 11.0)
        #expect(lampton.infoboxImage?.role == "gallery")
        let battle = try Fixture.decode(EntityDetail.self, "entity-battle")
        #expect(battle.locatorPoint?.lat == 45.6)
    }

    @Test func mediaAddresses() {
        func media(url: String? = nil, path: String? = nil, mime: String? = nil, kind: String? = nil, role: String? = nil) -> EntityDetail.Media {
            EntityDetail.Media(id: "m", kind: kind, title: nil, caption: nil, credit: nil, url: url, storagePath: path, mimeType: mime,
                               widthPx: nil, heightPx: nil, role: role, visibility: nil)
        }
        #expect(media(url: "https://cdn.test/a.png").address(base: testServer)?.absoluteString == "https://cdn.test/a.png")
        #expect(media(path: "/a/b.png").address(base: testServer)?.absoluteString == "https://lore.example.test/media/a/b.png")
        #expect(media(url: "media/x.png").address(base: testServer)?.absoluteString == "https://lore.example.test/media/x.png")
        #expect(media().address(base: testServer) == nil)
        #expect(media(mime: "image/png").isImage)
        #expect(!media(mime: "application/pdf").isImage)
        #expect(!media(kind: "document").isImage)
        var page = EntityDetail(entity: .init(id: "1", ref: "r", title: "T", type: .location, visibility: .public))
        page.media = [media(mime: "image/png", role: "gallery"), media(mime: "image/png", role: "portrait")]
        #expect(page.infoboxImage?.role == "portrait")
        page.shapes = [EntityDetail.Shape(id: "s", geometry: nil), EntityDetail.Shape(id: "t", geometry: .point(LonLat(3, 4)))]
        #expect(page.locatorPoint?.lon == 3)
    }

    @Test func trailsAndViews() throws {
        let v = try Fixture.decode(ViewsAndTrails.self, "views")
        let trail = try #require(v.trails?.first { $0.slug == "start-here" })
        let mid = try #require(trail.neighbours(of: "lampton"))
        #expect(mid.previous?.ref == "testmark")
        #expect(mid.next?.ref == "hidden-hamlet")
        #expect(trail.neighbours(of: "testmark")?.previous == nil)
        #expect(trail.neighbours(of: "battle-at-the-ford")?.next == nil)
        #expect(trail.neighbours(of: "nowhere") == nil)
        let list = try Fixture.decode(Page<EntityListItem>.self, "entities-list")
        #expect(list.items.first?.card.ref == list.items.first?.ref)
        let b = try Fixture.decode(Backlinks.self, "backlinks-dirk")
        #expect(b.page.ref == "dirk")
    }

    @Test func statementsAndAccounts() throws {
        let list = try Fixture.decode(StatementList.self, "statements-dirk")
        #expect(list.record.count == 6 && list.claims.isEmpty)
        #expect(list.items[0].shownSentence.hasPrefix("Dirk commanded"))
        var s = list.items[0]
        s.sentence = nil
        s.label = nil
        #expect(s.shownSentence.contains("commanded"))
        s.object = nil
        s.value = .number(3)
        #expect(s.shownSentence.hasSuffix("3"))
        #expect(!s.isClaim)
        s.accordingTo = EntityCard(ref: "a", id: "a", title: "A")
        #expect(s.isClaim)

        let compared = try Fixture.decode(AccountsCompared.self, "compare-battle")
        let recordID = compared.record[2].id
        #expect(compared.cell(account: "testmark-chronicle", record: recordID)?.leftOut == true)
        #expect(compared.cell(account: "nobody", record: recordID) == nil)
        for r in ["agrees", "contradicts", "exaggerates", "minimizes", "minimises", "distorts", "invents", "unverifiable", "made_up"] {
            #expect(!AccountsCompared.relationWord(r).isEmpty)
        }
        #expect(AccountsCompared.relationWord(nil) == "agrees")
        #expect(AccountsCompared.relationWord("made_up") == "made up")
        #expect(AccountsCompared.relationWord("unverifiable") == "cannot be checked")
    }

    @Test func beliefs() throws {
        var b = try Fixture.decode(BeliefsOf.self, "beliefs-fenn")
        let first = b.beliefs[0]
        var second = first
        second.id = "x"
        second.overriddenBy = "y"
        var third = first
        third.id = "z"
        third.propositionKey = nil
        third.proposition = "Other"
        b.beliefs = [first, second, third]
        let groups = b.byQuestion
        #expect(groups.map(\.key) == [first.propositionKey!, "Other"])
        #expect(groups[0].beliefs.count == 2)
        #expect(second.isOverridden && !first.isOverridden)
    }

    @Test func timelinesAndPeople() throws {
        let t = try Fixture.decode(Timeline.self, "timeline-lanes")
        #expect(t.items[0].lane("faction") == "testmark")
        #expect(t.items[0].lane("place") == nil)
        #expect(t.items[0].lane("nothing") == nil)
        var item = t.items[0]
        item.claim = true
        #expect(item.isClaim)
        let tree = try Fixture.decode(FamilyTree.self, "family-dirk")
        #expect(tree.parents.allSatisfy { $0.isBiological })
        var link = tree.parents[0]
        link.kind = "adoptive"
        #expect(!link.isBiological)
        link.kind = nil
        #expect(link.isBiological)
        #expect(tree.people[0].shownTitle == "Dirk")
        let g = try Fixture.decode(Neighbourhood.self, "graph-dirk")
        #expect(g.nodes[0].card.ref == g.nodes[0].ref)
        #expect(g.nodes[0].shownTitle == g.nodes[0].displayTitle ?? g.nodes[0].title)
        #expect(!g.edges[0].isClaim)
    }

    @Test func mapLayers() throws {
        let m = try Fixture.decode(MapLayers.self, "map-layers")
        let places = try #require(m.layers.first { $0.key == "places" })
        #expect(places.isVectorTiled && !places.isBaseGeometry && places.isCurrent && !places.isDerived && !places.isRaster)
        let rivers = try #require(m.layers.first { $0.key == "base-rivers" })
        #expect(rivers.isBaseGeometry)
        #expect(m.layers.first { $0.key == "events" }?.isDerived == true)
        #expect(places.baseMap == nil)
        func raster(_ key: String, _ title: String) -> MapLayers.Layer {
            MapLayers.Layer(id: key, key: key, title: title, kind: "raster", group: "Base maps")
        }
        #expect(raster("relief", "Relief").baseMap == .relief)
        #expect(raster("hs", "Hillshade").baseMap == .relief)
        #expect(raster("atlas", "Painted atlas").baseMap == .atlas)
        #expect(raster("old", "Old map").baseMap == nil)
        #expect(BaseMap.allCases.map(\.label) == ["Atlas", "Relief", "Plain"])
        #expect(Distance.modes.count == 7)
        let suggestions = try Fixture.decode(Suggestions.self, "resolve-lam")
        #expect(suggestions.candidates[0].card.ref == "lampton")
    }
}

@Suite struct HTMLContentTests {
    @Test func paragraphsAndLinks() {
        let html = #"<p>Dirk was marshal of <a class="wikilink" href="/wiki/testmark" data-slug="testmark">Kingdom   of Testmark</a>.</p>"#
        let blocks = HTMLContent.parse(html)
        #expect(blocks == [.paragraph([.text("Dirk was marshal of "), .link(.page("testmark"), [.text("Kingdom of Testmark")]), .text(".")])])
        #expect(blocks[0].plainText == "Dirk was marshal of Kingdom of Testmark.")
    }

    @Test func everyBlockKind() {
        let html = """
        <h2>Title <em>here</em></h2>
        <p>One<br>two &amp; <strong>bold</strong> <del>gone</del> <code>x&lt;y</code> <img src="a.png" alt="Map"></p>
        <ol start="3"><li>first</li><li><p>second</p><ul><li>nested</li></ul></li></ol>
        <blockquote><p>quoted</p></blockquote>
        <pre><code>let x = 1
        </code></pre>
        <hr/>
        <div>loose <i>text</i></div>
        <table><thead><tr><th style="text-align: center">A</th><th style="text-align:right">B</th><th>C</th></tr></thead>
        <tbody><tr><td>1</td><td>2</td><td>3</td></tr></tbody></table>
        trailing <b>words</b>
        """
        let blocks = HTMLContent.parse(html)
        guard blocks.count == 9 else {
            Issue.record("got \(blocks)")
            return
        }
        #expect(blocks[0] == .heading(level: 2, [.text("Title "), .emphasis([.text("here")])]))
        if case .paragraph(let i) = blocks[1] {
            #expect(i.contains(.lineBreak))
            #expect(i.contains(.strong([.text("bold")])))
            #expect(i.contains(.strike([.text("gone")])))
            #expect(i.contains(.code("x<y")))
            #expect(i.contains(.image(src: "a.png", alt: "Map")))
        } else {
            Issue.record("not a paragraph")
        }
        if case .list(let ordered, let start, let items) = blocks[2] {
            #expect(ordered && start == 3 && items.count == 2)
            #expect(items[1].count == 2)
        } else {
            Issue.record("not a list")
        }
        #expect(blocks[3] == .quote([.paragraph([.text("quoted")])]))
        #expect(blocks[4] == .code("let x = 1"))
        #expect(blocks[5] == .rule)
        #expect(blocks[6] == .paragraph([.text("loose "), .emphasis([.text("text")])]))
        if case .table(let header, let rows, let align) = blocks[7] {
            #expect(header.count == 3 && rows.count == 1)
            #expect(align == [.centre, .trailing, .leading])
        } else {
            Issue.record("not a table")
        }
        #expect(blocks[8] == .paragraph([.text("trailing "), .strong([.text("words")])]))
        for b in blocks { _ = b.plainText }
        #expect(Block.rule.plainText == "")
        #expect(blocks[7].plainText.contains("A\tB\tC"))
    }

    @Test func linksOnlyWhereTheReaderMayGo() {
        func target(_ a: String) -> [Inline] {
            if case .paragraph(let i) = HTMLContent.parse("<p>\(a)</p>").first { return i }
            return []
        }
        #expect(target(#"<a href="/wiki/hidden" class="wikilink wikilink-missing">Hidden</a>"#) == [.text("Hidden")])
        #expect(target(#"<a data-missing href="/wiki/x">X</a>"#) == [.text("X")])
        #expect(target(#"<a href="/wiki/some%20page#history">S</a>"#) == [.link(.page("some page"), [.text("S")])])
        #expect(target(#"<a href="/wiki/">S</a>"#) == [.text("S")])
        #expect(target(#"<a href="https://example.test/a">W</a>"#) == [.link(.web(URL(string: "https://example.test/a")!), [.text("W")])])
        #expect(target(#"<a href="javascript:alert(1)">J</a>"#) == [.text("J")])
        #expect(target(#"<a>none</a>"#) == [.text("none")])
        #expect(target(#"<a href=mailto:a@b.test>M</a>"#).count == 1)
    }

    @Test func toleratesMessyHTML() throws {
        // unclosed paragraphs and list items close as browsers close them
        let blocks = HTMLContent.parse("<p>one<p>two<ul><li>a<li>b</ul><!-- note --><!doctype x>< not a tag </p></span>")
        try #require(blocks.count == 4)
        #expect(blocks[0] == .paragraph([.text("one")]))
        #expect(blocks[1] == .paragraph([.text("two")]))
        if case .list(_, _, let items) = blocks[2] { #expect(items.count == 2) } else { Issue.record("no list") }
        #expect(blocks[3] == .paragraph([.text("< not a tag")]))
        #expect(HTMLContent.parse("a < b and c > d").first == .paragraph([.text("a < b and c > d")]))
        #expect(HTMLContent.parse("x <span").first == .paragraph([.text("x <span")]))
        #expect(HTMLContent.parse("   ").isEmpty)
        #expect(HTMLContent.parse("<p>  </p>").isEmpty)
    }

    @Test func entitiesAndAttributes() {
        #expect(HTMLContent.decodeEntities("a &amp; b &#65; &#x42; &mdash; &unknown; &") == "a & b A B \u{2014} &unknown; &")
        let (name, attrs) = HTMLContent.Tokenizer.parseTag(#"A HREF='x' data-slug="s" checked title=plain"#)
        #expect(name == "a")
        #expect(attrs == ["href": "x", "data-slug": "s", "checked": "", "title": "plain"])
        #expect(HTMLContent.collapse("a \n\t b") == "a b")
        #expect(HTMLContent.trim([.text("  "), .text(" a "), .text("  ")]) == [.text("a")])
        #expect(Inline.lineBreak.plainText == "\n")
        #expect(Inline.image(src: "", alt: "alt").plainText == "alt")
        #expect(Inline.code("c").plainText == "c")
    }
}

@Suite struct ProseTests {
    @Test func runsJoinNeighbours() {
        let runs = Prose.runs([
            .text("a"), .text("b"), .emphasis([.text("c"), .strong([.text("d")])]), .code("e"), .lineBreak,
            .link(.page("dirk"), [.text("Dirk")]), .link(.web(URL(string: "https://x.test")!), [.strike([.text("w")])]),
            .image(src: "s", alt: "pic"), .image(src: "s", alt: ""), .text(""),
        ])
        #expect(runs.map(\.text) == ["ab", "c", "d", "e", "\n", "Dirk", "w", "[pic]"])
        #expect(runs[2].style == [.emphasis, .strong])
        #expect(runs[3].style == .code)
        #expect(runs[5].link == URL(string: "loregraph://wiki/dirk"))
        #expect(runs[6].style == .strike)
        #expect(Prose.pageURL("a b").absoluteString == "loregraph://wiki/a%20b")
    }

    @Test func linkedPagesInOrder() {
        let blocks: [Block] = [
            .heading(level: 2, [.link(.page("a"), [.text("A")])]),
            .paragraph([.emphasis([.link(.page("b"), [.strong([.link(.page("c"), [.text("C")])])])]), .link(.page("a"), [])]),
            .list(ordered: false, start: 1, items: [[.paragraph([.link(.page("d"), [])])]]),
            .quote([.paragraph([.strike([.link(.web(URL(string: "https://x.test")!), [.link(.page("e"), [])])])])]),
            .table(header: [[.link(.page("f"), [])]], rows: [[[.link(.page("g"), [])]]], alignments: [.leading]),
            .code("x"), .rule,
        ]
        #expect(Prose.linkedPages(blocks) == ["a", "b", "c", "d", "e", "f", "g"])
    }
}

@Suite struct RouteTests {
    func parse(_ s: String) -> WebLink? { WebLink.parse(URL(string: s)!, server: testServer) }

    @Test func readsWebLinks() {
        #expect(parse("https://lore.example.test/")?.route == .home)
        #expect(parse("https://lore.example.test/wiki?type=event")?.route == .browse(type: .event))
        #expect(parse("https://lore.example.test/wiki/dirk/")?.route == .page("dirk"))
        #expect(parse("https://lore.example.test/wiki/dirk/records")?.route == .records("dirk"))
        #expect(parse("https://lore.example.test/wiki/dirk/links")?.route == .links("dirk"))
        #expect(parse("https://lore.example.test/wiki/dirk/history")?.route == .history("dirk"))
        #expect(parse("https://lore.example.test/wiki/dirk/other") == nil)
        #expect(parse("https://lore.example.test/records/s1")?.route == .record("s1"))
        #expect(parse("https://lore.example.test/compare/b")?.route == .compare("b"))
        #expect(parse("https://lore.example.test/beliefs/fenn")?.route == .beliefs("fenn"))
        #expect(parse("https://lore.example.test/beliefs/q/ford:commander")?.route == .beliefQuestion("ford:commander"))
        #expect(parse("https://lore.example.test/beliefs/trace/b1")?.route == .beliefTrace("b1"))
        #expect(parse("https://lore.example.test/factions/testmark")?.route == .faction("testmark"))
        #expect(parse("https://lore.example.test/trails/start-here")?.route == .trail("start-here"))
        #expect(parse("https://lore.example.test/v/my-view")?.route == .savedView("my-view"))
        #expect(parse("https://lore.example.test/categories/river")?.route == .category("river", title: nil))
        #expect(parse("https://lore.example.test/categories") == nil)
        #expect(parse("https://lore.example.test/family")?.route == .home)
        #expect(parse("https://lore.example.test/search?q=ford")?.route == .search("ford"))
        #expect(parse("https://lore.example.test/search")?.route == .search(""))
        #expect(parse("https://lore.example.test/nothing") == nil)
        #expect(parse("https://lore.example.test/x/y") == nil)
        #expect(parse("https://lore.example.test/a/b/c/d") == nil)
        #expect(parse("https://elsewhere.test/wiki/dirk") == nil)
        #expect(parse("https://lore.example.test:444/wiki/dirk") == nil)
        #expect(parse("ftp://lore.example.test/wiki/dirk") == nil)
        #expect(WebLink.parse(URL(string: "https://lore.example.test/wiki/dirk")!, server: nil) == nil)
        #expect(WebLink.parse(URL(string: "loregraph://wiki/dirk")!, server: nil)?.route == .page("dirk"))
        #expect(WebLink.parse(URL(string: "loregraph://oauth/callback?code=x")!, server: nil) == nil)
    }

    @Test func readsTheView() throws {
        let link = try #require(parse("https://lore.example.test/wiki/dirk?w=elsewhere&y=1020.5&vp=aldo&cal=lc&as=public&sel=x"))
        #expect(link.world == "elsewhere")
        #expect(link.view.asOf == 1020.5)
        #expect(link.view.viewpoint?.ref == "aldo")
        #expect(link.view.calendar == "lc")
        #expect(link.view.viewAs == .public)
        #expect(link.selected == "x")
        let plain = try #require(parse("https://lore.example.test/wiki/dirk?w=&as=designer"))
        #expect(plain.world == nil)
        #expect(plain.view.isDefault)
    }

    @Test func readsExploreOptions() {
        #expect(parse("https://lore.example.test/family/dirk?up=20&down=-1&mode=ancestors&account=x")?.route
            == .family("dirk", FamilyOptions(up: 10, down: 0, mode: .ancestors, account: "x")))
        #expect(parse("https://lore.example.test/family/dirk")?.route == .family("dirk", FamilyOptions()))
        #expect(parse("https://lore.example.test/graph?focus=a,%20b&depth=9&path=a,c")?.route
            == .graph(GraphOptions(focus: ["a", "b"], depth: 3, path: ["a", "c"])))
        #expect(parse("https://lore.example.test/graph")?.route == .graph(GraphOptions()))
        #expect(parse("https://lore.example.test/timeline?about=dirk&from=1000&to=1100&lanes=type&claims=yes")?.route
            == .timeline(TimelineOptions(about: ["dirk"], from: "1000", to: "1100", lanes: "type", claims: true)))
        let map = parse("https://lore.example.test/map?c=11.1,45.5&z=7.5&l=places,routes&base=relief&place=1,2&pts=1,2;3,4;bad;500,1&tool=measure&sel=lampton")?.route
        #expect(map == .map(MapOptions(centre: LonLat(11.1, 45.5), zoom: 7.5, layers: ["places", "routes"], base: .relief,
                                       place: LonLat(1, 2), points: [LonLat(1, 2), LonLat(3, 4)], measuring: true, select: "lampton")))
        #expect(WebLink.lonLat(nil) == nil)
        #expect(WebLink.lonLat("1") == nil)
    }

    @Test func writesWebLinksBack() {
        let routes: [Route] = [
            .home, .browse(type: nil), .browse(type: .event), .page("dirk"), .records("dirk"), .links("dirk"), .history("dirk"),
            .record("s1"), .compare("b"), .beliefs("fenn"), .beliefQuestion("ford:commander"), .beliefTrace("b1"), .faction("t"),
            .family("dirk", FamilyOptions()), .family("dirk", FamilyOptions(up: 3, down: 1, mode: .descendants, account: "x")),
            .graph(GraphOptions()), .graph(GraphOptions(focus: ["a", "b"], depth: 2, path: ["a", "b"])),
            .timeline(TimelineOptions()), .timeline(TimelineOptions(about: ["dirk"], from: "1000", to: "1100", lanes: "type", claims: true)),
            .map(MapOptions()), .search(""), .search("ford"), .trail("t"), .savedView("v"), .category("river", title: nil),
        ]
        for r in routes {
            let view = ViewState(asOf: 1020, viewpoint: .init(ref: "aldo", title: "aldo"), calendar: "lc", viewAs: .public)
            // on the map, sel is the selected page itself
            var selected: String? = "sel"
            if case .map = r { selected = nil }
            let link = WebLink(route: r, world: "main", view: view, selected: selected)
            let back = WebLink.parse(link.url(server: testServer), server: testServer)
            #expect(back?.route == r, "round trip of \(r)")
            #expect(back?.view == view)
            #expect(back?.world == "main")
        }
        let map = WebLink(route: .map(MapOptions(centre: LonLat(11.1, 45.5), zoom: 7.456, layers: ["places"], base: .atlas,
                                                place: LonLat(1, 2), points: [LonLat(1, 2), LonLat(3, 4)], measuring: true,
                                                select: "lampton")), selected: "other")
        let url = map.url(server: testServer).absoluteString
        #expect(url.contains("c=11.1000,45.5000"))
        #expect(url.contains("z=7.46"))
        #expect(url.contains("tool=measure"))
        #expect(url.contains("sel=lampton"))
        #expect(!url.contains("sel=other"))
        #expect(WebLink(route: .home).url(server: testServer).absoluteString == "https://lore.example.test/")
        // a category's title is only the heading: its link is the slug, as the web app's
        #expect(WebLink(route: .category("river", title: "Rivers")).url(server: testServer).absoluteString
            == "https://lore.example.test/categories/river")
        #expect(WebLink(route: .home, view: ViewState(viewAs: .designer)).url(server: testServer).query == nil)
    }
}
