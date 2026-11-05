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

@Suite struct YearTextTests {
    @Test func yearText() {
        #expect(YearText.label(1131.25) == "spring YV 1131")
        #expect(YearText.label(1131) == "winter YV 1131")
        #expect(YearText.label(1131.999) == "winter YV 1132")
        #expect(YearText.label(1020.5) == "summer YV 1020")
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

