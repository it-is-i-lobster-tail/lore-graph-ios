import Foundation
import Testing
@testable import LoreGraphKit

@Suite struct GeometryTests {
    @Test func pointsAndRects() {
        let a = Point(3, 4)
        #expect(a.length == 5)
        #expect(a + Point(1, 1) == Point(4, 5))
        #expect(a - Point(1, 1) == Point(2, 3))
        #expect(a * 2 == Point(6, 8))
        #expect(Point.zero.distance(to: a) == 5)
        let r = Rect(x: 0, y: 0, width: 10, height: 20)
        #expect(r.centre == Point(5, 10))
        #expect(r.maxX == 10 && r.maxY == 20 && r.minX == 0 && r.minY == 0)
        #expect(r.contains(Point(10, 20)) && !r.contains(Point(11, 0)))
        #expect(r.intersects(Rect(x: 9, y: 19, width: 5, height: 5)))
        #expect(!r.intersects(Rect(x: 10, y: 0, width: 5, height: 5)))
        #expect(r.insetBy(2) == Rect(x: 2, y: 2, width: 6, height: 16))
        #expect(r.insetBy(20).size == Size(0, 0))
        #expect(r.union(Rect(x: -5, y: 5, width: 1, height: 30)) == Rect(x: -5, y: 0, width: 15, height: 35))
        #expect(Rect(centre: Point(5, 5), size: Size(2, 4)) == Rect(x: 4, y: 3, width: 2, height: 4))
        #expect(Rect.bounding([]) == nil)
        #expect(Rect.bounding([Point(1, 2), Point(-1, 5)]) == Rect(x: -1, y: 2, width: 2, height: 3))
    }
}

@Suite struct ForceLayoutTests {
    @Test func placesLinkedNodesNearTheirIdealLength() {
        let layout = ForceLayout(idealLength: 100, iterations: 200)
        let pos = layout.run(nodes: ["a", "b", "c", "d"], edges: [("a", "b"), ("b", "c"), ("c", "a"), ("a", "d"), ("a", "a"), ("a", "zz")],
                             pinned: ["a"])
        #expect(pos.count == 4)
        #expect(pos["a"] == .zero)
        for (x, y) in [("a", "b"), ("b", "c"), ("a", "d")] {
            let d = pos[x]!.distance(to: pos[y]!)
            #expect(d > 30 && d < 300)
        }
        // deterministic
        #expect(layout.run(nodes: ["a", "b", "c", "d"], edges: [("a", "b"), ("b", "c"), ("c", "a"), ("a", "d")], pinned: ["a"])
            == layout.run(nodes: ["a", "b", "c", "d"], edges: [("a", "b"), ("b", "c"), ("c", "a"), ("a", "d")], pinned: ["a"]))
    }

    @Test func keepsKnownPlacesAndSeparatesCoincidentNodes() {
        let layout = ForceLayout(idealLength: 50, iterations: 20)
        #expect(layout.run(nodes: [], edges: []).isEmpty)
        let pos = layout.run(nodes: ["a", "b", "c", "lonely"], edges: [("a", "b")],
                             initial: ["a": Point(10, 10), "b": Point(10, 10), "c": Point(10, 10)], pinned: ["a"])
        #expect(pos["a"] == Point(10, 10))
        #expect(pos["b"]!.distance(to: pos["a"]!) > 1)
        #expect(pos["lonely"] != nil)
    }

    @Test func linkFamiliesHaveWords() {
        #expect(LinkFamily.label("kinship") == "Kinship")
        #expect(LinkFamily.label(nil) == "Other")
        #expect(LinkFamily.all.count == 11)
    }
}

@Suite struct TimelineLayoutTests {
    func items() throws -> [Timeline.Item] { try Fixture.decode(Timeline.self, "timeline").items }

    @Test func windowsZoomAndPanInsideTheirBounds() {
        let bounds = TimeWindow(from: 1000, to: 1100)
        let w = TimeWindow(from: 1080, to: 1020)
        #expect(w.from == 1020 && w.to == 1080)
        #expect(w.span == 60 && w.centre == 1050)
        let z = w.zoomed(by: 2, around: 1050, within: bounds)
        #expect(z.span == 30 && z.centre == 1050)
        #expect(w.zoomed(by: 1e9, around: 1050, within: bounds).span == TimeWindow.minSpan)
        #expect(w.zoomed(by: 0.0001, around: 1050, within: bounds) == bounds)
        #expect(TimeWindow(from: 5, to: 5).zoomed(by: 1, around: 5, within: bounds).from >= 1000)
        #expect(w.panned(by: 100, within: bounds) == TimeWindow(from: 1040, to: 1100))
        #expect(w.panned(by: -100, within: bounds) == TimeWindow(from: 1000, to: 1060))
        #expect(w.fraction(1050) == 0.5)
        #expect(TimeWindow(from: 1, to: 1).fraction(5) == 0)
        #expect(w.year(atFraction: 0.5) == 1050)
        #expect(w.overlaps(1000...1020) && !w.overlaps(1081...1090))
    }

    @Test func barsInRowsWithoutOverlap() throws {
        let layout = TimelineLayout(items: try items(), present: 1131.25)
        #expect(layout.bars.count == 19)
        #expect(layout.rows >= 2)
        #expect(layout.extent.from < 1015 && layout.extent.to > 1131)
        var byRow: [Int: [TimelineLayout.Bar]] = [:]
        for b in layout.bars { byRow[b.row, default: []].append(b) }
        for (_, bars) in byRow {
            for (x, y) in zip(bars, bars.dropFirst()) {
                #expect((x.outer ?? x.range).upperBound <= (y.outer ?? y.range).lowerBound)
            }
        }
        // open spans run to the present; short ones are points (decades never)
        let open = try #require(layout.bars.first { $0.isOpen })
        #expect(open.range.upperBound == 1131.25)
        #expect(layout.bars.contains { $0.isPoint })
        #expect(!layout.bars.contains { $0.isPoint && $0.item.date.precision == "decade" })
        #expect(layout.bars(in: TimeWindow(from: 1019, to: 1021)).count < layout.bars.count)
    }

    @Test func envelopesAndOpenStarts() throws {
        var a = try items()[0]
        a.date = DateSpan(from: 1020, to: 1021, outer: .init(from: 1010, to: nil))
        var b = a
        b.id = "b"
        b.date = DateSpan(from: nil, to: 1050)
        var c = a
        c.id = "c"
        c.date = DateSpan(from: nil, to: nil)
        let layout = TimelineLayout(items: [a, b, c], present: 1131)
        #expect(layout.bars.count == 2)
        #expect(layout.bars[0].outer == 1010...1021)
        #expect(layout.bars[1].range == 1049...1050)
        #expect(layout.groups().last?.title == "Undated")
        let empty = TimelineLayout(items: [], present: 1131)
        #expect(empty.extent.to > 1131 && empty.extent.from < 1032)
    }

    @Test func readingListGroups() throws {
        let layout = TimelineLayout(items: try items(), present: 1131.25)
        let groups = layout.groups()
        #expect(groups.first?.title == "The 1010s")
        #expect(groups.map(\.items.count).reduce(0, +) == 19)
        let windowed = layout.groups(in: TimeWindow(from: 1049, to: 1051))
        #expect(windowed.allSatisfy { !$0.items.isEmpty })
        #expect(windowed.map(\.items.count).reduce(0, +) < 19)
        let long = TimelineLayout(items: try items(), present: 1131.25).groups(in: TimeWindow(from: 500, to: 1131))
        #expect(long.first?.title == "YV 1000 to 1099")
        #expect(groups.first?.id == groups.first?.title)
    }

    @Test func lanes() throws {
        let lanes = try Fixture.decode(Timeline.self, "timeline-lanes").items
        let layout = TimelineLayout(items: lanes, present: 1131.25)
        let byFaction = layout.lanes("faction")
        #expect(byFaction.last?.title == "Other")
        #expect(byFaction.contains { $0.title == "testmark" })
        #expect(layout.lanes("nothing").map(\.title) == ["Other"])
        let none = TimelineLayout(items: lanes.filter { $0.lane("faction") != nil }, present: 1131.25).lanes("faction")
        #expect(!none.contains { $0.title == "Other" })
    }

    @Test func ticksFromMillenniaToSeasons() {
        let wide = TimelineLayout.ticks(TimeWindow(from: 0, to: 3000), maxTicks: 6)
        #expect(wide.count <= 7 && wide.count >= 3)
        #expect(wide.first?.label == "0")
        let huge = TimelineLayout.ticks(TimeWindow(from: 0, to: 100_000), maxTicks: 5)
        #expect(huge.count <= 6)
        let seasons = TimelineLayout.ticks(TimeWindow(from: 1020, to: 1021), maxTicks: 8)
        #expect(seasons.map(\.label) == ["YV 1020", "spring", "summer", "autumn", "YV 1021"])
        #expect(seasons.first?.major == true)
        let years = TimelineLayout.ticks(TimeWindow(from: 1020, to: 1060), maxTicks: 8)
        #expect(years.first?.year == 1020)
        #expect(years.contains { $0.major })
        #expect(!TimelineLayout.ticks(TimeWindow(from: 1, to: 2), maxTicks: 0).isEmpty)
    }

    @Test func yearText() throws {
        #expect(YearText.label(1131.25) == "spring YV 1131")
        #expect(YearText.label(1131) == "winter YV 1131")
        #expect(YearText.label(1131.999) == "winter YV 1132")
        #expect(YearText.label(1020.5) == "summer YV 1020")
        let eras = try Fixture.decode(Timeline.self, "timeline").eras ?? []
        let range = YearText.sliderRange(eras: eras, present: 1131.25)
        #expect(range.upperBound == 1131.25)
        #expect(range.lowerBound <= 900)
        #expect(YearText.sliderRange(eras: [], present: 100) == 900...901)
    }
}

@Suite struct FamilyLayoutTests {
    @Test func layoutOfDirksFamily() throws {
        let tree = try Fixture.decode(FamilyTree.self, "family-dirk")
        let layout = FamilyLayout(tree: tree, year: 1131.25)
        #expect(layout.cards.count == 4)
        let dirk = try #require(layout.card("dirk"))
        let cato = try #require(layout.card("cato"))
        let mira = try #require(layout.card("mira"))
        let edwin = try #require(layout.card("edwin"))
        #expect(dirk.isRoot)
        #expect(dirk.status == .dead)
        #expect(cato.status == .alive)
        #expect(layout.card("nobody") == nil)
        // generations in rows, partners side by side
        #expect(dirk.frame.minY < cato.frame.minY)
        #expect(cato.frame.minY == mira.frame.minY)
        #expect(cato.frame.minY < edwin.frame.minY)
        #expect(!cato.frame.intersects(mira.frame))
        // lines: the couple, Dirk's stem and child lines
        #expect(layout.lines.contains { $0.kind == .partner && $0.id.hasSuffix(":partners") })
        #expect(layout.lines.contains { $0.id.hasSuffix(":stem") })
        let toCato = try #require(layout.lines.first { $0.child == "cato" })
        #expect(toCato.visibility == .designer)
        #expect(layout.unions.count == 3)   // the couple, and Dirk and Cato each known alone as parents
        #expect(layout.size.width > 0 && layout.size.height > 0)
        #expect(layout.lines(along: ["edwin", "cato", "dirk"]).map(\.child).sorted { ($0 ?? "") < ($1 ?? "") } == ["cato", "edwin"])
        #expect(layout.lines(along: ["dirk"]).isEmpty)
    }

    @Test func theUnbornAreLeftOutAtAYear() throws {
        let tree = try Fixture.decode(FamilyTree.self, "family-dirk")
        let early = FamilyLayout(tree: tree, year: 1032)
        #expect(early.card("edwin") == nil)
        #expect(early.card("mira") == nil)
        #expect(early.card("cato")?.status == .alive)
        let timeless = FamilyLayout(tree: tree)
        #expect(timeless.cards.count == 4)
        #expect(timeless.cards.allSatisfy { $0.status == .unknown })
    }

    @Test func claimedAndAdoptedParentsAreDashed() throws {
        var tree = try Fixture.decode(FamilyTree.self, "family-dirk")
        tree.parents[1].kind = "adoptive"
        tree.parents[1].disputed = true
        tree.parents.append(FamilyTree.ParentLink(statementId: "s", parent: "mira", child: "edwin", role: nil, kind: nil, disputed: nil,
                                                  visibility: .public, accordingTo: EntityCard(ref: "ballad", id: "b", title: "Ballad")))
        tree.unions = []
        let layout = FamilyLayout(tree: tree, year: nil)
        let lines = layout.lines.filter { $0.child == "edwin" }
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.dashed })
        #expect(lines.contains { $0.disputed })
        #expect(lines.contains { $0.accordingTo == "ballad" })
        #expect(layout.unions.count == 3)
    }

    @Test func largerFamiliesKeepPartnersTogether() throws {
        func person(_ ref: String, _ gen: Int, root: Bool = false) -> FamilyTree.Person {
            FamilyTree.Person(ref: ref, id: ref, title: ref.capitalized, generation: gen, root: root)
        }
        func link(_ p: String, _ c: String) -> FamilyTree.ParentLink {
            FamilyTree.ParentLink(statementId: "\(p)>\(c)", parent: p, child: c, visibility: .public)
        }
        let people = [person("a", -1), person("b", -1), person("c", -1), person("x", 0, root: true), person("y", 0), person("z", 0),
                      person("k1", 1), person("k2", 1), person("k3", 1)]
        // a has two partners (b and c); x and y are a couple; z is single
        let tree = FamilyTree(root: EntityCard(ref: "x", id: "x", title: "X"), people: people,
                              parents: [link("a", "x"), link("b", "x"), link("a", "z"), link("c", "z"), link("x", "k1"), link("y", "k1"),
                                        link("y", "k2"), link("z", "k3"), link("ghost", "k3")],
                              marriages: [FamilyTree.Marriage(statementId: "m", a: "x", b: "y", visibility: .restricted)],
                              unions: [FamilyTree.Union(a: "a", b: "b", children: ["x"]), FamilyTree.Union(a: "a", b: "c", children: ["z"]),
                                       FamilyTree.Union(a: "x", b: "y", children: ["k1"]), FamilyTree.Union(a: nil, b: "ghost", children: ["k3"]),
                                       FamilyTree.Union(a: "nobody", b: nil, children: [])])
        let layout = FamilyLayout(tree: tree, year: nil)
        #expect(layout.cards.count == 9)
        for (i, c) in layout.cards.enumerated() {
            for d in layout.cards.dropFirst(i + 1) { #expect(!c.frame.intersects(d.frame)) }
        }
        let a = try #require(layout.card("a")), b = try #require(layout.card("b")), c = try #require(layout.card("c"))
        #expect(abs(a.frame.centre.x - b.frame.centre.x) < 400 && abs(a.frame.centre.x - c.frame.centre.x) < 400)
        #expect(layout.lines.contains { $0.kind == .partner && $0.visibility == .restricted })
        #expect(layout.card("x")?.isRoot == true)
    }
}

