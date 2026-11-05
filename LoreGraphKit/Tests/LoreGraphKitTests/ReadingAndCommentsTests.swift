import Foundation
import Testing
@testable import LoreGraphKit

/// Fixtures recorded from the Testmark world on a loregraph server with reading lists (ADR D-83)
/// and comments on page text (ADR D-84).
let auditList = "01a1a84f-303b-7585-936f-87ffe9a4dc84"
let secondList = "01a1a84f-cbd7-713e-a0e5-6837a283fd23"
let lampsComment = "01a1a84f-cd4e-73a3-ba7c-a5fb969676ba"
let leadComment = "01a1a84f-cdca-7db5-953c-6160908d3a85"

extension FakeServer {
    /// The Testmark server with a reading list and comments.
    static func reading() -> FakeServer {
        let s = FakeServer.testmark()
        s.json("/reading-lists", "reading-list")
        s.json("/reading-lists/\(auditList)", "reading-list")
        s.json("/reading-lists/\(secondList)", "reading-list")
        s.json("/comments", "comments-lampton", query: ["ref": "lampton"])
        s.json("/comments", "comments-all", query: ["status": "open"])
        s.json("/entities/lampton", "entity-lampton-now")
        s.json("/entities/lampton", "entity-lampton-diff", query: ["diff_since": "2026-11-04T20:46:04.259793Z"])
        return s
    }

    /// A route for one method answering with a fixture.
    func change(_ method: String, _ path: String, _ fixture: String, status: Int = 200) {
        let body = Fixture.data(fixture)
        on(path, method: method) { _ in HTTPResponse(status: status, body: body) }
    }

    func last(_ method: String, _ path: String) -> HTTPRequest? {
        requests.last { $0.method == method && $0.url.path == "/api/v1" + path }
    }
}

extension HTTPRequest {
    var json: [String: JSONValue] {
        (try? JSONDecoder().decode([String: JSONValue].self, from: body ?? Data())) ?? [:]
    }
}

@Suite struct ReadingAndCommentModelTests {
    @Test func decodesTheRecordedAnswers() throws {
        let list = try Fixture.decode(ReadingList.self, "reading-list")
        #expect(list.readingList?.title == "Lore audit, 4 November 2026")
        #expect(list.progress?.read == 3 && list.progress?.pages == 24 && list.progress?.changed == 1)
        #expect(list.parts.map(\.key) == ["places", "factions", "history", "people", "accounts", "no-text"])
        #expect(list.parts[0].isDone && !list.parts[1].isDone)
        #expect(list.upNext?.page.ref == "testmark" && list.upNext?.minutes == 1)
        let lampton = try #require(list.items.first { $0.page.ref == "lampton" })
        #expect(lampton.isRead && lampton.changed && !lampton.isDone && lampton.id == lampton.page.id)
        #expect(list.lists.map(\.title) == ["Second pass", "Lore audit, 4 November 2026"])
        #expect(list.lists[1].read == 3)

        let none = try Fixture.decode(ReadingList.self, "reading-none")
        #expect(none.readingList == nil && none.items.isEmpty && none.lists.isEmpty)

        let built = try Fixture.decode(ReadingBuildResult.self, "reading-build")
        #expect(built.readingList?.title == "Second pass" && built.added == 24 && built.readingList?.parts?.count == 6)
        let deleted = try Fixture.decode(ReadingBuildResult.self, "reading-delete")
        #expect(deleted.readingList == nil)
        let mark = try Fixture.decode(ReadingMarkResult.self, "reading-mark")
        #expect(mark.changed == 3 && mark.items.allSatisfy(\.isRead) && mark.upNext?.page.ref == "testmark")

        let comments = try Fixture.decode(CommentList.self, "comments-lampton")
        #expect(comments.open == 4 && comments.resolved == 1 && comments.comments.count == 5)
        let section = try #require(comments.comments.first)
        #expect(section.anchor.status == .section && !section.anchor.isPlaced && section.status == .resolved)
        #expect(section.author.shown == "Owner" && section.author.mine && section.canEdit)
        let other = comments.comments[1]
        #expect(other.anchor.status == .exact && other.anchor.text == "Kingdom of Testmark" && !other.author.mine && !other.canEdit)
        let changed = try #require(comments.comments.last)
        #expect(changed.anchor.status == .changed && changed.anchor.quote == "broke the Eastmarch"
                && changed.anchor.text == "and met the Eastmarch" && changed.anchor.isPlaced)
        let lamps = try #require(comments.comments.first { $0.id == lampsComment })
        #expect(lamps.replies.count == 1 && lamps.replies[0].bodyMd == "Yes: the new lamps were lit in 1091.")

        let reply = try Fixture.decode(CommentResult.self, "comment-reply")
        #expect(reply.comment?.replies.count == 1)
        #expect(try Fixture.decode(CommentResult.self, "comment-delete").comment == nil)
        #expect(CommentList(comments: [section]).open == 0 && CommentList(comments: [section]).resolved == 1)

        let diff = try Fixture.decode(EntityDetail.self, "entity-lampton-diff")
        let history = try #require(diff.sections?.first { $0.key == "history" })
        #expect(history.changedSince == true)
        #expect(history.diff?.map(\.op) == [.equal, .insert, .equal])
        #expect(history.diff?[1].text == " and her daughters")
        #expect(diff.sections?.first { $0.key == "lead" }?.changedSince == false)

        // an unknown status or operation from a newer server still decodes
        let odd = try JSONCoding.decoder.decode(PageComment.Anchor.self, from: Data(#"{"status":"floating"}"#.utf8))
        #expect(odd.status == .detached)
        let op = try JSONCoding.decoder.decode(WordChange.self, from: Data(#"{"op":"move","text":"x"}"#.utf8))
        #expect(op.op == .equal && WordChange(op: .insert, text: "y").op == .insert)
    }

    @Test func readsAndChangesAreAddressedAsTheServerExpects() throws {
        let base = testServer
        func url<T>(_ e: Endpoint<T>) -> String { e.url(base: base, world: "main", view: ViewState(asOf: 1020)).absoluteString }
        func url<T>(_ c: Change<T>) -> String { c.url(base: base, world: "main").absoluteString }

        #expect(url(API.readingList()) == "https://lore.example.test/api/v1/reading-lists?limit=5000&world=main")
        #expect(url(API.readingList("abc", limit: 0, cursor: "c1")) == "https://lore.example.test/api/v1/reading-lists/abc?limit=0&cursor=c1&world=main")
        #expect(API.readingList().freshness == .personal)
        #expect(url(API.comments(on: "lampton")) == "https://lore.example.test/api/v1/comments?ref=lampton&status=all&limit=200&world=main")
        #expect(url(API.comments(on: "lampton", viewAs: .public)).contains("view_as=public"))
        #expect(!url(API.comments(on: "lampton", viewAs: .designer)).contains("view_as"))
        #expect(url(API.allComments()) == "https://lore.example.test/api/v1/comments?status=open&limit=50&world=main")
        #expect(url(API.allComments(status: nil, cursor: "x")).contains("status=all"))
        let diff = API.entity("lampton", diffSince: "2026-11-04T20:46:04.259793Z")
        #expect(url(diff).contains("diff_since=2026-11-04T20:46:04.259793Z") && diff.freshness == .personal)

        let build = API.buildReadingList(title: "  Second pass ")
        #expect(build.method == "POST" && url(build) == "https://lore.example.test/api/v1/reading-lists?world=main")
        #expect(build.body == ["title": "Second pass"])
        #expect(API.buildReadingList(title: " ").body == [:])
        #expect(API.addNewPages(to: "abc").method == "PUT" && API.addNewPages(to: "abc").body == ["add_new": true])
        #expect(API.renameReadingList("abc", title: "T").body == ["title": "T"])
        let delete = API.deleteReadingList("abc")
        #expect(delete.method == "DELETE" && url(delete) == "https://lore.example.test/api/v1/reading-lists/abc?confirm=true&world=main"
                && delete.bodyData == nil)
        let mark = API.markRead(list: "abc", refs: ["lampton"], read: false)
        #expect(url(mark).hasSuffix("/reading-lists/abc/read?world=main") && mark.body == ["refs": ["lampton"], "read": false])
        #expect(String(decoding: mark.bodyData ?? Data(), as: UTF8.self) == #"{"read":false,"refs":["lampton"]}"#)

        let add = API.addComment(page: "lampton", section: "history", quote: "lamps", prefix: "The ", suffix: " of", body: "Why?")
        #expect(add.method == "POST" && url(add).hasSuffix("/comments?world=main"))
        #expect(add.body == ["ref": "lampton", "section": "history", "quote": "lamps", "prefix": "The ", "suffix": " of", "body_md": "Why?"])
        let whole = API.addComment(page: "lampton", section: "lead", quote: nil, prefix: "x", body: "Whole")
        #expect(whole.body == ["ref": "lampton", "section": "lead", "body_md": "Whole"])
        #expect(API.addComment(page: "l", section: "s", quote: "q", prefix: "", suffix: nil, body: "b").body?["prefix"] == nil)
        #expect(url(API.reply(to: "c1", body: "Yes", resolve: true)).hasSuffix("/comments/c1/replies?world=main"))
        #expect(API.reply(to: "c1", body: "Yes", resolve: true).body == ["body_md": "Yes", "resolve": true])
        #expect(url(API.resolveComment("c1")).hasSuffix("/comments/c1/resolve?world=main"))
        #expect(url(API.resolveComment("c1", resolved: false)).hasSuffix("/comments/c1/reopen?world=main"))
        #expect(API.editComment("c1", body: "New").method == "PATCH" && url(API.editComment("c1", body: "New")).hasSuffix("/comments/c1?world=main"))
        #expect(url(API.editComment("c1", reply: "r1", body: "New")).hasSuffix("/comments/c1/replies/r1?world=main"))
        #expect(url(API.deleteComment("c1")).hasSuffix("/comments/c1?confirm=true&world=main"))
        #expect(url(API.deleteComment("c1", reply: "r1")).hasSuffix("/comments/c1/replies/r1?confirm=true&world=main"))
    }

    @Test func sendsChangesWithTheTokenAndReadsRefusals() async throws {
        let stack = Stack(server: .reading())
        stack.server.change("POST", "/comments", "comment-add", status: 201)
        let r = try await stack.client.send(API.addComment(page: "lampton", section: "history", quote: "The lamps of Lampton burn all night.",
                                                           body: "Still true after the fire?"), world: "main")
        #expect(r.comment?.id == lampsComment)
        let sent = try #require(stack.server.last("POST", "/comments"))
        #expect(sent.headers["Authorization"] == "Bearer token-1" && sent.headers["Content-Type"] == "application/json")
        #expect(sent.json["quote"] == "The lamps of Lampton burn all night." && sent.query["world"] == ["main"])

        stack.server.change("POST", "/comments", "comment-error", status: 422)
        do {
            _ = try await stack.client.send(API.addComment(page: "lampton", section: "history", quote: "No such words here.", body: "x"),
                                            world: "main")
            Issue.record("expected a refusal")
        } catch let APIError.problem(p) {
            #expect(p.detail == "the quote is not in the text of Lampton, History" && p.hint?.hasPrefix("Copy the passage") == true)
            #expect(p.errors?.first?.field == "quote")
        }
        stack.server.on("/comments/x/resolve", method: "POST") { _ in HTTPResponse(status: 200, body: Data("nope".utf8)) }
        await #expect(throws: APIError.self) { try await stack.client.send(API.resolveComment("x"), world: nil) }
    }

    @Test @MainActor func personalAnswersAreShownFromTheCacheAndAlwaysCheckedAgain() async throws {
        let stack = Stack(server: .reading())
        let ctx = stack.context()
        let first = ctx.loader(API.readingList())
        await first.load()
        #expect(first.value?.progress?.read == 3)
        #expect(stack.server.count("/history") == 0)          // reading lists do not follow the lore mark
        stack.server.json("/reading-lists", "reading-none")
        let second = ctx.loader(API.readingList())
        await second.load()
        #expect(second.value?.readingList == nil)              // fetched again, though the cache had an answer
        #expect(stack.server.count("/reading-lists") == 2)
        stack.server.offline("/reading-lists")
        let third = ctx.loader(API.readingList())
        await third.load()
        #expect(third.value?.readingList == nil && third.isStale)   // offline: the saved copy
        third.show(try Fixture.decode(ReadingList.self, "reading-list"))
        #expect(third.value?.progress?.read == 3 && !third.isStale && third.error == nil && !third.isLoading)
    }
}

@Suite struct AnchorTests {
    @Test func takesTheSameTextAsTheServer() throws {
        // expected values from the server's html_text (backend/app/domain/anchors.py)
        let page = try Fixture.decode(EntityDetail.self, "entity-lampton-now")
        let text = Dictionary(uniqueKeysWithValues: (page.sections ?? []).compactMap { s in s.html.map { (s.key, Anchors.sectionText($0)) } })
        #expect(text["lead"] == "Lampton is a city on the Test River in the Test Vale, and the seat of the Kingdom of Testmark. Its lamps are kept by the Order of the Lamp.")
        #expect(text["history"] == "The lamps of Lampton burn all night. Loïse and her daughters kept them. In the summer of YV 1020 the host of Testmark crossed the ford below the city and met the Eastmarch at the Battle at the Ford.")
        #expect(Anchors.sectionText("<p>One  two\n three</p>\n<p>Four&nbsp;five &amp; six</p>\n") == "One two three Four five & six")
        #expect(Anchors.sectionText("<figure><img src=\"a.png\" alt=\"x\"><figcaption>Caption here</figcaption></figure>\n<p>After the <em>figure</em>.</p>")
                == "After the figure.")
        #expect(Anchors.sectionText("<ul>\n<li>First</li>\n<li>Second <strong>item</strong></li>\n</ul>\n<p>Tail\u{2003}with em space</p>")
                == "First Second item Tail with em space")
        #expect(Anchors.sectionText("<p>A<br>B</p><h2>Head</h2><p>𝔘nicode 𝔗ext</p>") == "ABHead𝔘nicode 𝔗ext")
        #expect(Anchors.sectionText("") == "" && Anchors.sectionText(" \n ") == "")
        #expect(Anchors.collapse("  a \u{00A0}\t b\u{FEFF} ") == "a b")
        #expect(Anchors.isSpace("\u{3000}") && !Anchors.isSpace("x"))
    }

    @Test func highlightsThePassagesTheServerFound() throws {
        let page = try Fixture.decode(EntityDetail.self, "entity-lampton-now")
        let comments = try Fixture.decode(CommentList.self, "comments-lampton")
        let history = try #require(page.sections?.first { $0.key == "history" }?.html)
        let marks = comments.comments.filter { $0.section.key == "history" && $0.anchor.isPlaced }
            .map { Anchors.Highlight(id: $0.id, anchor: $0.anchor) }
        #expect(marks.count == 3)
        let blocks = HTMLContent.parse(history, highlights: marks)
        // marks add no text
        #expect(blocks.map(\.plainText) == HTMLContent.parse(history).map(\.plainText))
        let runs = Prose.runs({ if case .paragraph(let i) = blocks[0] { return i } else { return [] } }())
        let marked = runs.filter { !$0.comments.isEmpty }
        #expect(marked.map(\.text) == ["The lamps of Lampton burn all night.", "and her daughters", "and met the ", "Eastmarch"])
        #expect(marked[0].comments == [lampsComment])
        // a passage over a link keeps the link and carries the comment
        #expect(marked[3].link == Prose.pageURL("eastmarch") && marked[3].comments == marked[2].comments)
        #expect(runs.filter { $0.comments.isEmpty }.map(\.text).joined().contains("Loïse "))

        // a passage that is no longer in the text is left out; no passages, the same blocks
        let gone = Anchors.Highlight(id: "x", anchor: .init(status: .exact, text: "not in the text", occurrence: 0))
        #expect(HTMLContent.parse(history, highlights: [gone]) == HTMLContent.parse(history))
        #expect(HTMLContent.parse(history, highlights: []) == HTMLContent.parse(history))
    }

    @Test func choosesTheRightOccurrence() {
        let html = "<p>The lamp is lit. The lamp is out.</p>"
        func marked(_ a: PageComment.Anchor) -> [String] {
            guard case .paragraph(let i)? = HTMLContent.parse(html, highlights: [.init(id: "c", anchor: a)]).first else { return [] }
            return Prose.runs(i).map { $0.comments.isEmpty ? $0.text : "[\($0.text)]" }
        }
        #expect(marked(.init(status: .exact, text: "The lamp", occurrence: 1)) == ["The lamp is lit. ", "[The lamp]", " is out."])
        // the copies count differently: the surroundings decide
        #expect(marked(.init(status: .exact, text: "The lamp", prefix: "lit. ", suffix: " is out", occurrence: 5))
                == ["The lamp is lit. ", "[The lamp]", " is out."])
        #expect(marked(.init(status: .exact, text: "The lamp", prefix: "", suffix: " is lit")) == ["[The lamp]", " is lit. The lamp is out."])
        // overlapping comments share the overlap
        let two = HTMLContent.parse(html, highlights: [.init(id: "a", anchor: .init(status: .exact, text: "lamp is lit", occurrence: 0)),
                                                       .init(id: "b", anchor: .init(status: .exact, text: "is lit. The", occurrence: 0))])
        guard case .paragraph(let i)? = two.first else { Issue.record("no paragraph"); return }
        #expect(Prose.runs(i).map(\.comments) == [[], ["a"], ["a", "b"], ["b"], []])
        #expect(Prose.linkedPages(two).isEmpty)
    }

    @Test func spacesAndBlocksAroundAPassage() {
        // a passage over two paragraphs takes no mark on the space between them
        let html = "<p>First  line ends.</p>\n<ul>\n<li>Item one</li>\n</ul>\n<figure><figcaption>Not text</figcaption></figure>"
        #expect(Anchors.sectionText(html) == "First line ends. Item one")
        let blocks = HTMLContent.parse(html, highlights: [.init(id: "c", anchor: .init(status: .exact, text: "line ends. Item", occurrence: 0))])
        #expect(blocks.map(\.plainText) == HTMLContent.parse(html).map(\.plainText))
        guard case .paragraph(let first)? = blocks.first, case .list(_, _, let items)? = blocks.dropFirst().first,
              case .paragraph(let item)? = items.first?.first else { Issue.record("unexpected blocks"); return }
        #expect(Prose.runs(first).map(\.comments) == [[], ["c"]])
        #expect(Prose.runs(first).last?.text == "line ends.")
        #expect(Prose.runs(item).first?.text == "Item" && Prose.runs(item).first?.comments == ["c"])
        // the extra spaces of a run inside a marked passage go with it
        let spaced = HTMLContent.parse("<p>a  b   c</p>", highlights: [.init(id: "c", anchor: .init(status: .exact, text: "a b c", occurrence: 0))])
        guard case .paragraph(let s)? = spaced.first else { Issue.record("no paragraph"); return }
        #expect(Prose.runs(s).map(\.comments) == [["c"]])
        // a mark element in the HTML without comment ids is just its text
        #expect(HTMLContent.parse("<p><mark>x</mark></p>") == HTMLContent.parse("<p>x</p>"))
    }

    @Test func picksAPassageAsTheServerWouldAnchorIt() throws {
        let page = try Fixture.decode(EntityDetail.self, "entity-lampton-now")
        let lead = Anchors.Selectable(html: try #require(page.sections?.first { $0.key == "lead" }?.html))
        #expect(!lead.isEmpty && lead.display == lead.text)
        let r = try #require(lead.display.range(of: "Kingdom of Testmark"))
        let picked = try #require(lead.pick(utf16: lead.display.utf16Range(r)))
        // the same quote and context the server stored for this passage (comments-lampton.json)
        #expect(picked == Anchors.Picked(quote: "Kingdom of Testmark", prefix: " Test Vale, and the seat of the ",
                                         suffix: ". Its lamps are kept by the Orde"))
        // spaces at the ends of a selection are left out; nothing selected is nothing picked
        let spaced = try #require(lead.display.range(of: " Kingdom of Testmark. "))
        #expect(lead.pick(utf16: lead.display.utf16Range(spaced))?.quote == "Kingdom of Testmark.")
        #expect(lead.pick(utf16: 3..<3) == nil && lead.pick(utf16: 0..<9999) == nil)
        #expect(lead.pick(utf16: lead.display.utf16Range(try #require(lead.display.range(of: " ")))) == nil)

        let comments = try Fixture.decode(CommentList.self, "comments-lampton")
        let other = try #require(comments.comments.first { $0.anchor.text == "Kingdom of Testmark" })
        #expect(lead.displayRange(of: other.anchor) == lead.display.utf16Range(r))
        #expect(lead.displayRange(of: .init(status: .detached)) == nil)

        // characters outside the basic plane count once, as the server counts them
        let astral = Anchors.Selectable(html: "<p>𝔘nicode 𝔗ext here</p>")
        let t = try #require(astral.display.range(of: "𝔗ext"))
        #expect(astral.pick(utf16: astral.display.utf16Range(t)) == Anchors.Picked(quote: "𝔗ext", prefix: "𝔘nicode ", suffix: " here"))
        #expect(astral.displayRange(of: .init(status: .exact, text: "𝔗ext", occurrence: 0)) == astral.display.utf16Range(t))
    }

    @Test func showsParagraphsOnLinesOfTheirOwn() throws {
        let s = Anchors.Selectable(html: "<p>One two.</p>\n<p>Three.</p>\n<ul>\n<li>Four</li>\n<li>Five</li>\n</ul>")
        #expect(s.text == "One two. Three. Four Five")
        #expect(s.display == "One two.\n\nThree.\n\nFour\nFive")
        // a selection across the break is the text across the space it stands for
        let r = try #require(s.display.range(of: "two.\n\nThree"))
        #expect(s.pick(utf16: s.display.utf16Range(r))?.quote == "two. Three")
        // a selection of only the break holds no text
        let br = try #require(s.display.range(of: "\n\n"))
        #expect(s.pick(utf16: s.display.utf16Range(br)) == nil)
        #expect(s.displayRange(of: .init(status: .exact, text: "Four Five", occurrence: 0)) == s.display.utf16Range(try #require(s.display.range(of: "Four\nFive"))))
        // no space between blocks: the break is shown, the text joins them
        let joined = Anchors.Selectable(html: "<p>A</p><p>B</p>")
        #expect(joined.text == "AB" && joined.display == "A\n\nB")
        #expect(Anchors.Selectable(html: "").isEmpty)
    }
}

extension String {
    func utf16Range(_ r: Range<String.Index>) -> Range<Int> {
        utf16.distance(from: utf16.startIndex, to: r.lowerBound)..<utf16.distance(from: utf16.startIndex, to: r.upperBound)
    }
}

@Suite struct CommentLinkAndRouteTests {
    @Test func commentLinks() {
        let u = Prose.commentURL("01a1-x")
        #expect(u.absoluteString == "loregraph://comment/01a1-x" && Prose.commentID(u) == "01a1-x")
        #expect(Prose.commentID(Prose.pageURL("dirk")) == nil)
        #expect(Prose.commentID(URL(string: "loregraph://comment")!) == nil)
        #expect(Prose.commentID(URL(string: "https://lore.example.test/comment/x")!) == nil)
    }

    @Test func readingAndCommentRoutesRoundTrip() {
        func parse(_ s: String) -> Route? { WebLink.parse(URL(string: s)!, server: testServer)?.route }
        #expect(parse("https://lore.example.test/reading") == .reading(list: nil, page: nil))
        #expect(parse("https://lore.example.test/reading?list=abc&page=lampton&comments=open") == .reading(list: "abc", page: "lampton"))
        #expect(parse("https://lore.example.test/reading?list=&page=") == .reading(list: nil, page: nil))
        #expect(parse("https://lore.example.test/comments") == .comments(.open))
        #expect(parse("https://lore.example.test/comments?status=resolved") == .comments(.resolved))
        #expect(parse("https://lore.example.test/comments?status=all") == .comments(nil))
        #expect(parse("https://lore.example.test/wiki/lampton?comment=c1") == .pageComments("lampton", focus: "c1"))
        #expect(parse("https://lore.example.test/wiki/lampton?comments=resolved") == .pageComments("lampton", focus: nil))
        #expect(parse("https://lore.example.test/wiki/lampton?comment=") == .page("lampton"))
        for route: Route in [.reading(list: nil, page: nil), .reading(list: "abc", page: "lampton"), .comments(.open), .comments(.resolved),
                             .comments(nil), .pageComments("lampton", focus: "c1"), .pageComments("lampton", focus: nil)] {
            let url = WebLink(route: route).url(server: testServer)
            #expect(WebLink.parse(url, server: testServer)?.route == route, "\(url)")
        }
        #expect(WebLink(route: .comments(.open)).url(server: testServer).absoluteString == "https://lore.example.test/comments")
        #expect(WebLink(route: .reading(list: "abc", page: nil)).url(server: testServer).absoluteString
                == "https://lore.example.test/reading?list=abc")
    }
}

@Suite @MainActor struct ReadingModelTests {
    @Test func showsTheListByPartWithFilters() async throws {
        let stack = Stack(server: .reading())
        let model = ReadingModel(context: stack.context())
        #expect(model.list == nil && !model.isEmpty && model.items.isEmpty && model.parts.isEmpty)
        await model.load()
        #expect(model.info?.id == auditList && model.progress?.percent == 12 && model.upNext?.page.ref == "testmark")
        #expect(model.items.count == 24 && model.shownParts.count == 6 && !model.canLoadMore)
        let places = model.parts[0]
        #expect(model.items(in: places).map(\.page.ref) == ["test-vale", "eastbrook", "lampton"])
        model.filter = .unread
        #expect(model.items(in: places).isEmpty && model.shownParts.count == 5)
        model.filter = .changed
        #expect(model.shownParts.map(\.key) == ["places"] && model.items(in: places).map(\.page.ref) == ["lampton"])
        model.filter = .all
        #expect(ReadingModel.Filter.allCases.map(\.label) == ["All", "Unread", "Changed"] && ReadingModel.Filter.all.id == "all")
        #expect(model.item("lampton")?.n == 3 && model.item("00000000-0000-7000-8000-000000000031")?.page.ref == "lampton")
        #expect(model.neighbour(of: "lampton", by: 1)?.page.ref == "testmark")
        #expect(model.neighbour(of: "lampton", by: -1)?.page.ref == "eastbrook")
        #expect(model.neighbour(of: "test-vale", by: -1) == nil && model.neighbour(of: "nowhere", by: 1) == nil)
        #expect(model.builtAt != nil)
        #expect(stack.server.last("GET", "/reading-lists")?.query["limit"] == ["5000"])

        // what changed on a page read before
        let lampton = try #require(model.item("lampton"))
        let changes = try #require(model.changes(lampton))
        await changes.load()
        #expect(changes.value?.sections?.first { $0.key == "history" }?.changedSince == true)
        #expect(model.changes(try #require(model.item("testmark"))) == nil)
        await model.refresh()
        #expect(model.items.count == 24)
    }

    @Test func marksPagesAndShowsTheAnswerAtOnce() async throws {
        let server = FakeServer.reading()
        server.json("/reading-lists", "reading-none")       // marks first, then the list as it was before them
        server.json("/reading-lists/\(auditList)", "reading-none")
        let stack = Stack(server: server)
        let model = ReadingModel(list: auditList, context: stack.context())
        await model.load()
        #expect(model.isEmpty && model.info == nil)
        #expect(await model.mark(["lampton"]) == nil)       // no list, nothing to mark
        server.json("/reading-lists/\(auditList)", "reading-list")
        await model.refresh()
        server.change("POST", "/reading-lists/\(auditList)/read", "reading-unmark")
        let r = try #require(await model.mark(["lampton"], read: false))
        #expect(r.changed == 1)
        let sent = try #require(server.last("POST", "/reading-lists/\(auditList)/read"))
        #expect(sent.json == ["refs": ["lampton"], "read": false])
        // the answer's pages, progress and next page are shown without fetching the list again
        let gets = server.count("/reading-lists/\(auditList)")
        let aldo = try #require(r.items.first)
        #expect(model.item(aldo.page.ref)?.readAt == aldo.readAt && model.progress == r.progress && model.upNext == r.upNext)
        #expect(server.count("/reading-lists/\(auditList)") == gets)
        #expect(await model.mark([]) == nil)
        server.status("/reading-lists/\(auditList)/read", 422, body: Fixture.data("comment-error"))
        #expect(await model.mark(["lampton"]) == nil)
        #expect(model.actionError?.message == "the quote is not in the text of Lampton, History")
        server.offline("/reading-lists/\(auditList)/read")
        #expect(await model.mark(["lampton"]) == nil && model.actionError?.isOffline == true)
    }

    @Test func buildsRenamesAddsToAndDeletesLists() async throws {
        let server = FakeServer.reading()
        server.change("POST", "/reading-lists", "reading-build", status: 201)
        server.change("PUT", "/reading-lists/\(auditList)", "reading-add-new")
        server.change("DELETE", "/reading-lists/\(auditList)", "reading-delete")
        let stack = Stack(server: server)
        let model = ReadingModel(context: stack.context())
        await model.load()
        #expect(model.isWorking == false)

        #expect(await model.build(title: "Second pass"))
        #expect(model.listID == secondList && server.last("POST", "/reading-lists")?.json == ["title": "Second pass"])
        await model.open(auditList)
        #expect(model.listID == auditList)

        await model.addNewPages()
        #expect(server.last("PUT", "/reading-lists/\(auditList)")?.json == ["add_new": true] && model.actionError == nil)
        await model.rename("  Audit  ")
        #expect(server.last("PUT", "/reading-lists/\(auditList)")?.json == ["title": "Audit"])
        #expect(model.info?.title == "Audit" && model.list?.lists.first { $0.id == auditList }?.title == "Audit")
        let puts = server.requests.filter { $0.method == "PUT" }.count
        await model.rename("   ")
        #expect(server.requests.filter { $0.method == "PUT" }.count == puts)

        await model.delete()
        #expect(server.last("DELETE", "/reading-lists/\(auditList)")?.query["confirm"] == ["true"])
        #expect(model.listID == nil)

        server.status("/reading-lists", 422, body: Fixture.data("comment-error"))
        #expect(await model.build() == false && model.actionError != nil)
    }

    @Test func loadsMorePagesOfALongList() async throws {
        let server = FakeServer.reading()
        var first = try Fixture.decode(ReadingList.self, "reading-list")
        let rest = Array(first.items.dropFirst(20))
        first.items = Array(first.items.prefix(20))
        first.nextCursor = "c20"
        var page2 = first
        page2.items = rest
        page2.nextCursor = nil
        server.json("/reading-lists", value: first)
        server.json("/reading-lists/\(auditList)", value: page2, query: ["cursor": "c20"])
        let stack = Stack(server: server)
        let model = ReadingModel(context: stack.context(), limit: 20)
        await model.load()
        #expect(model.items.count == 20 && model.canLoadMore)
        await model.loadMore()
        #expect(model.items.count == 24 && !model.canLoadMore)
        await model.loadMore()
        #expect(model.items.count == 24)
        // a mark updates pages from either answer
        var mark = try Fixture.decode(ReadingMarkResult.self, "reading-mark")
        mark.items = [rest[0]]
        mark.items[0].readAt = "2026-11-05T09:00:00Z"
        server.json("/reading-lists/\(auditList)/read", value: mark)
        await model.mark([rest[0].page.ref])
        #expect(model.item(rest[0].page.ref)?.readAt == "2026-11-05T09:00:00Z")
        server.offline("/reading-lists/\(auditList)")
        model.actionError = nil
        let fresh = ReadingModel(context: stack.context(), limit: 20)
        await fresh.load()
        await fresh.loadMore()
        #expect(fresh.actionError?.isOffline == true)
    }

    @Test func timeAndDates() {
        #expect(ReadingModel.timeLeft(0) == "about 0 min" && ReadingModel.timeLeft(21) == "about 21 min")
        #expect(ReadingModel.timeLeft(125) == "about 2 h 5 min" && ReadingModel.timeLeft(120) == "about 2 h")
        #expect(ReadingModel.parseDate("2026-11-04T20:46:04.259793Z") != nil)
        #expect(ReadingModel.parseDate("2026-11-04T20:46:04Z") != nil)
        #expect(ReadingModel.parseDate("yesterday") == nil)
    }
}

@Suite @MainActor struct CommentsModelTests {
    @Test func listsAPagesCommentsAndHighlightsThem() async throws {
        let stack = Stack(server: .reading())
        let page = PageModel(ref: "lampton", context: stack.context())
        await page.load()
        let c = page.comments
        #expect(c.openCount == 4 && c.resolvedCount == 1 && c.shown.count == 4)
        #expect(c.open(in: "history").count == 3 && c.highlights("history").count == 3 && c.highlights("lead").count == 1)
        #expect(c.groups.map(\.key) == ["lead", "history"] && c.groups[0].title == "Introduction" && c.groups[1].title == "History")
        c.showResolved = true
        #expect(c.shown.count == 5 && c.groups[0].comments.count == 2)
        #expect(c.comment(lampsComment)?.replies.count == 1 && c.comment("nope") == nil)
        #expect(stack.server.last("GET", "/comments")?.query == ["ref": ["lampton"], "status": ["all"], "limit": ["200"], "world": ["main"]])

        // the text carries the highlights, parsed again only when the comments change
        let history = try #require(page.page.value?.sections?.first { $0.key == "history" })
        let blocks = page.blocks(history)
        guard case .paragraph(let inlines)? = blocks.first else { Issue.record("no paragraph"); return }
        #expect(Prose.runs(inlines).contains { $0.comments == [lampsComment] })
        #expect(page.blocks(history) == blocks)
        #expect(page.commentableSections.map(\.key).contains("history"))
        await c.setResolved(lampsComment, true)          // not routed: the answer is a 404
        #expect(c.actionError != nil && page.blocks(history) == blocks)
        await page.refresh()
        #expect(c.openCount == 4)
    }

    @Test func addsAnswersResolvesEditsAndDeletes() async throws {
        let server = FakeServer.reading()
        server.change("POST", "/comments", "comment-add", status: 201)
        server.change("POST", "/comments/\(lampsComment)/replies", "comment-reply", status: 201)
        server.change("POST", "/comments/\(leadComment)/resolve", "comment-resolve")
        server.change("PATCH", "/comments/\(lampsComment)", "comment-edit")
        server.change("DELETE", "/comments/\(lampsComment)", "comment-delete")
        server.change("DELETE", "/comments/\(lampsComment)/replies/r1", "comment-reply")
        let stack = Stack(server: server)
        let c = CommentsModel(ref: "lampton", context: stack.context())
        await c.load()

        let picked = Anchors.Picked(quote: "The lamps of Lampton burn all night.", prefix: "", suffix: " Loïse and her daughters kept th")
        #expect(await c.add(section: "history", picked: picked, body: "  ") == nil)
        let added = try #require(await c.add(section: "history", picked: picked, body: " Still true after the fire? "))
        #expect(added.id == lampsComment && c.all.count == 5)       // already in the list: replaced in place
        #expect(server.last("POST", "/comments")?.json == ["ref": "lampton", "section": "history", "body_md": "Still true after the fire?",
                                                           "quote": "The lamps of Lampton burn all night.",
                                                           "suffix": " Loïse and her daughters kept th"])

        #expect(await c.reply(to: lampsComment, body: "Yes: the new lamps were lit in 1091.", resolve: true))
        #expect(server.last("POST", "/comments/\(lampsComment)/replies")?.json["resolve"] == true)
        #expect(await c.reply(to: lampsComment, body: " ") == false)

        #expect(await c.setResolved(leadComment, true))
        #expect(c.comment(leadComment)?.status == .resolved)

        #expect(await c.edit(lampsComment, body: "Still true after the fire of 1090?"))
        #expect(c.comment(lampsComment)?.bodyMd == "Still true after the fire of 1090?")
        #expect(await c.edit(lampsComment, body: "") == false)

        #expect(await c.delete(lampsComment, reply: "r1"))
        #expect(c.comment(lampsComment) != nil)
        #expect(await c.delete(lampsComment))
        #expect(c.comment(lampsComment) == nil && c.all.count == 4 && c.loader.value?.counts["open"] == c.openCount)

        server.change("POST", "/comments", "comment-error", status: 422)
        #expect(await c.add(section: "history", picked: nil, body: "x") == nil)
        #expect(c.actionError?.hint?.hasPrefix("Copy the passage") == true && !c.isWorking)
        server.offline("/comments/\(leadComment)")
        #expect(await c.delete(leadComment) == false && c.actionError?.isOffline == true)
        #expect(c.warnings.isEmpty)
    }

    @Test func aNewCommentJoinsAnEmptyList() async throws {
        let server = FakeServer.reading()
        server.json("/comments", value: CommentList(), query: ["ref": "lampton"])
        server.change("POST", "/comments", "comment-add", status: 201)
        let stack = Stack(server: server)
        let c = CommentsModel(ref: "lampton", context: stack.context(view: ViewState(viewAs: .public)))
        await c.load()
        #expect(c.all.isEmpty && server.last("GET", "/comments")?.query["view_as"] == ["public"])
        _ = await c.add(section: "history", picked: nil, body: "Whole section")
        #expect(c.all.count == 1 && c.loader.value?.counts == ["open": 1, "resolved": 0])
        c.remove("nope")
        #expect(c.all.count == 1)
    }

    @Test func listsCommentsAcrossTheWorld() async throws {
        let server = FakeServer.reading()
        server.json("/comments", value: CommentList(), query: ["status": "all"])
        let stack = Stack(server: server)
        let all = AllCommentsModel(context: stack.context())
        await all.load()
        #expect(all.loader.value?.open == 4 && all.status == .open)
        await all.set(status: .open)
        await all.set(status: nil)
        #expect(all.status == nil && all.loader.value?.comments.isEmpty == true)
        await all.refresh()
        #expect(server.last("GET", "/comments")?.query["status"] == ["all"])
    }
}
