import Foundation

/// Lays out a family tree on the phone (F-8.2): one row per generation, partners side by side
/// with a union dot between them, children hanging from their parents' dot, a parent known
/// alone (or a designer-only parent) on a dot of its own. Rows are ordered by barycentre sweeps
/// so lines cross as little as a small tree allows.
public struct FamilyLayout: Sendable {
    public enum Status: String, Hashable, Sendable { case alive, dead, unknown }

    public struct Card: Hashable, Sendable, Identifiable {
        public var id: String { person.ref }
        public var person: FamilyTree.Person
        public var frame: Rect
        public var isRoot: Bool
        public var status: Status
    }

    public struct UnionDot: Hashable, Sendable, Identifiable {
        public var id: String
        public var centre: Point
        public var partners: [String]
    }

    public struct Line: Hashable, Sendable, Identifiable {
        public enum Kind: String, Hashable, Sendable { case partner, child }

        public var id: String
        public var kind: Kind
        public var points: [Point]
        /// Adoption, fostering or a claimed parentage: drawn dashed.
        public var dashed: Bool
        public var visibility: Visibility
        public var disputed: Bool
        /// The account that claims this parentage, if it is a claim.
        public var accordingTo: String?
        public var child: String?
    }

    public static let cardSize = Size(156, 66)
    static let partnerGap = 30.0
    static let blockGap = 40.0
    static let rowGap = 76.0
    static let margin = 24.0

    public let cards: [Card]
    public let unions: [UnionDot]
    public let lines: [Line]
    public let size: Size

    public init(tree: FamilyTree, year: Double? = nil) {
        // the unborn are left out at a year (F-8.3)
        let people = tree.people.filter { p in
            guard let year, let from = p.lifespan?.from else { return true }
            return year >= from
        }
        let byRef = Dictionary(people.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        let gens = Array(Set(people.map(\.generation))).sorted()
        let rowOf = Dictionary(gens.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

        // families: couples from the server, then single parents for links no couple covers
        struct Family {
            var id: String
            var partners: [String]
            var children: [String]
        }
        var families: [Family] = []
        var covered = Set<String>()   // "parent>child"
        for u in tree.unions {
            let partners = [u.a, u.b].compactMap { $0 }.filter { byRef[$0] != nil }
            guard !partners.isEmpty else { continue }
            let kids = u.children.filter { byRef[$0] != nil }
            families.append(Family(id: "u:" + partners.joined(separator: "+"), partners: partners, children: kids))
            for p in partners { for c in kids { covered.insert("\(p)>\(c)") } }
        }
        var solo: [String: Int] = [:]
        for link in tree.parents where byRef[link.parent] != nil && byRef[link.child] != nil {
            guard !covered.contains("\(link.parent)>\(link.child)") else { continue }
            if let i = solo[link.parent] {
                if !families[i].children.contains(link.child) { families[i].children.append(link.child) }
            } else {
                solo[link.parent] = families.count
                families.append(Family(id: "s:" + link.parent, partners: [link.parent], children: [link.child]))
            }
            covered.insert("\(link.parent)>\(link.child)")
        }

        // rows of blocks: partners in the same row kept together
        var rows: [[[String]]] = gens.map { g in
            let members = people.filter { $0.generation == g }.map(\.ref)
            var partnersOf: [String: [String]] = [:]
            for f in families where f.partners.count == 2 {
                let (a, b) = (f.partners[0], f.partners[1])
                if byRef[a]?.generation == g, byRef[b]?.generation == g {
                    partnersOf[a, default: []].append(b)
                    partnersOf[b, default: []].append(a)
                }
            }
            var seen = Set<String>()
            var blocks: [[String]] = []
            for m in members where !seen.contains(m) {
                // the component of m through partnerships
                var comp: [String] = []
                var stack = [m]
                while let x = stack.popLast() {
                    guard !seen.contains(x) else { continue }
                    seen.insert(x)
                    comp.append(x)
                    stack += partnersOf[x] ?? []
                }
                let hub = comp.max { (partnersOf[$0]?.count ?? 0) < (partnersOf[$1]?.count ?? 0) } ?? m
                let ps = (partnersOf[hub] ?? []).filter { comp.contains($0) }
                var left: [String] = [], right: [String] = []
                for (i, p) in ps.enumerated() { if i % 2 == 0 { right.append(p) } else { left.insert(p, at: 0) } }
                let rest = comp.filter { $0 != hub && !ps.contains($0) }
                blocks.append(left + [hub] + right + rest)
            }
            return blocks
        }

        let w = Self.cardSize.width, h = Self.cardSize.height
        var x: [String: Double] = [:]
        func place(row: Int, desired: [String: Double]) {
            // blocks in their order, each at its desired centre, pushed right to avoid overlap,
            // then the whole row shifted to sit as near the desires as it can
            var cursor = -Double.infinity
            var placed: [(String, Double)] = []
            var offsets: [Double] = []
            for block in rows[row] {
                let width = Double(block.count) * w + Double(block.count - 1) * Self.partnerGap
                let want = block.compactMap { desired[$0] }
                let centre = want.isEmpty ? (cursor.isFinite ? cursor + Self.blockGap + width / 2 : width / 2)
                    : want.reduce(0, +) / Double(want.count)
                var start = centre - width / 2
                if cursor.isFinite { start = max(start, cursor + Self.blockGap) }
                for (i, ref) in block.enumerated() {
                    let cx = start + Double(i) * (w + Self.partnerGap) + w / 2
                    placed.append((ref, cx))
                    if let d = desired[ref] { offsets.append(d - cx) }
                }
                cursor = start + width
            }
            let shift = offsets.isEmpty ? 0 : offsets.reduce(0, +) / Double(offsets.count)
            for (ref, cx) in placed { x[ref] = cx + shift }
        }
        func unionX(_ f: Family) -> Double? {
            let xs = f.partners.compactMap { x[$0] }
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func reorder(row: Int, key: (String) -> Double?) {
            rows[row].sort { a, b in
                let ka = a.compactMap(key), kb = b.compactMap(key)
                let ma = ka.isEmpty ? Double.infinity : ka.reduce(0, +) / Double(ka.count)
                let mb = kb.isEmpty ? Double.infinity : kb.reduce(0, +) / Double(kb.count)
                return ma < mb
            }
        }
        for r in rows.indices { place(row: r, desired: [:]) }
        for sweep in 0..<6 {
            let down = sweep % 2 == 0
            for r in down ? Array(rows.indices) : rows.indices.reversed() {
                // desired x: under the parents' dot (going down), over the children (going up)
                var desired: [String: Double] = [:]
                for f in families {
                    if down, let ux = unionX(f) {
                        for c in f.children where rowOf[byRef[c]!.generation] == r { desired[c] = desired[c].map { ($0 + ux) / 2 } ?? ux }
                    } else if !down {
                        let kids = f.children.compactMap { x[$0] }
                        guard !kids.isEmpty else { continue }
                        let mid = kids.reduce(0, +) / Double(kids.count)
                        for p in f.partners where rowOf[byRef[p]!.generation] == r { desired[p] = desired[p].map { ($0 + mid) / 2 } ?? mid }
                    }
                }
                if sweep < 4 { reorder(row: r) { desired[$0] ?? x[$0] } }
                place(row: r, desired: desired)
            }
        }

        // shift into view
        let minX = (x.values.min() ?? 0) - w / 2
        var cards: [Card] = []
        var centre: [String: Point] = [:]
        for p in people {
            guard let cx = x[p.ref], let r = rowOf[p.generation] else { continue }
            let c = Point(cx - minX + Self.margin, Self.margin + Double(r) * (h + Self.rowGap) + h / 2)
            centre[p.ref] = c
            var status = Status.unknown
            if let year, let span = p.lifespan {
                if let to = span.to, year >= to { status = .dead } else if span.from != nil { status = .alive }
            }
            cards.append(Card(person: p, frame: Rect(centre: c, size: Self.cardSize), isRoot: p.root == true || p.ref == tree.root.ref,
                              status: status))
        }

        var unions: [UnionDot] = []
        var lines: [Line] = []
        let linkFor = Dictionary(tree.parents.map { ("\($0.parent)>\($0.child)", $0) }, uniquingKeysWith: { a, _ in a })
        let marriageFor = Dictionary(tree.marriages.flatMap { [("\($0.a)+\($0.b)", $0), ("\($0.b)+\($0.a)", $0)] },
                                     uniquingKeysWith: { a, _ in a })
        for f in families {
            let ps = f.partners.compactMap { centre[$0] }
            guard !ps.isEmpty else { continue }
            let dot: Point
            if ps.count == 2 {
                dot = Point((ps[0].x + ps[1].x) / 2, (ps[0].y + ps[1].y) / 2)
                let m = marriageFor[f.partners.joined(separator: "+")]
                let (l, r) = ps[0].x <= ps[1].x ? (ps[0], ps[1]) : (ps[1], ps[0])
                lines.append(Line(id: f.id + ":partners", kind: .partner,
                                  points: [Point(l.x + w / 2, l.y), Point(r.x - w / 2, r.y)], dashed: false,
                                  visibility: m?.visibility ?? .public, disputed: false, accordingTo: nil, child: nil))
            } else {
                dot = Point(ps[0].x, ps[0].y + h / 2 + Self.rowGap * 0.3)
                lines.append(Line(id: f.id + ":stem", kind: .partner, points: [Point(ps[0].x, ps[0].y + h / 2), dot],
                                  dashed: false, visibility: .public, disputed: false, accordingTo: nil, child: nil))
            }
            unions.append(UnionDot(id: f.id, centre: dot, partners: f.partners))
            for c in f.children {
                guard let cc = centre[c] else { continue }
                let links = f.partners.compactMap { linkFor["\($0)>\(c)"] }
                let top = cc.y - h / 2
                let midY = top - Self.rowGap / 2
                lines.append(Line(
                    id: f.id + ">" + c, kind: .child,
                    points: [dot, Point(dot.x, midY), Point(cc.x, midY), Point(cc.x, top)],
                    dashed: links.contains { !$0.isBiological || $0.accordingTo != nil },
                    visibility: links.map(\.visibility).max() ?? .public,
                    disputed: links.contains { $0.disputed == true },
                    accordingTo: links.compactMap(\.accordingTo?.ref).first, child: c))
            }
        }
        // a stem's dot can sit on the partner line of a couple below; lines are drawn first
        self.cards = cards
        self.unions = unions
        self.lines = lines
        let maxX = cards.map(\.frame.maxX).max() ?? 0
        let maxY = cards.map(\.frame.maxY).max() ?? 0
        self.size = Size(maxX + Self.margin, maxY + Self.margin)
    }

    public func card(_ ref: String) -> Card? { cards.first { $0.person.ref == ref } }

    /// The lines on a kinship path, to highlight (F-8.6).
    public func lines(along path: [String]) -> [Line] {
        let pairs = Set(zip(path, path.dropFirst()).flatMap { [$0.0 + ">" + $0.1, $0.1 + ">" + $0.0] })
        return lines.filter { line in
            guard let child = line.child else { return false }
            let parents = line.id.split(separator: ">").first.map(String.init) ?? ""
            let partnerRefs = parents.dropFirst(2).split(separator: "+").map(String.init)
            return partnerRefs.contains { pairs.contains($0 + ">" + child) }
        }
    }
}
