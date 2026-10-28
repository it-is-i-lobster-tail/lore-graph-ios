import Foundation

/// A force-directed layout for the graph (F-9.1): nodes repel, links pull, the start node is
/// pinned at the centre. Deterministic (no randomness), so the same graph always looks the same,
/// and incremental: nodes that already have a place keep it as a starting point.
public struct ForceLayout: Sendable {
    public var idealLength: Double = 120
    public var iterations: Int = 300
    public var repulsion: Double = 1

    public init(idealLength: Double = 120, iterations: Int = 300) {
        self.idealLength = idealLength
        self.iterations = iterations
    }

    /// Positions for `nodes` linked by `edges`, starting from `initial` where known; `pinned`
    /// nodes do not move. New nodes start on a circle around a placed neighbour.
    public func run(nodes: [String], edges: [(String, String)], initial: [String: Point] = [:],
                    pinned: Set<String> = []) -> [String: Point] {
        guard !nodes.isEmpty else { return [:] }
        let index = Dictionary(nodes.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let links = edges.compactMap { e -> (Int, Int)? in
            guard let a = index[e.0], let b = index[e.1], a != b else { return nil }
            return (a, b)
        }
        var neighbours = Array(repeating: [Int](), count: nodes.count)
        for (a, b) in links {
            neighbours[a].append(b)
            neighbours[b].append(a)
        }
        // starting positions: known ones, then around a placed neighbour, then a spiral
        var pos = Array(repeating: Point.zero, count: nodes.count)
        var placed = Array(repeating: false, count: nodes.count)
        for (i, n) in nodes.enumerated() {
            if let p = initial[n] {
                pos[i] = p
                placed[i] = true
            }
        }
        if !placed.contains(true) {
            pos[0] = .zero
            placed[0] = true
        }
        var changed = true
        var ring = Array(repeating: 0, count: nodes.count)
        while changed {
            changed = false
            for i in nodes.indices where !placed[i] {
                guard let anchor = neighbours[i].first(where: { placed[$0] }) else { continue }
                ring[anchor] += 1
                let angle = Double(ring[anchor]) * 2.399963   // golden angle
                pos[i] = pos[anchor] + Point(cos(angle), sin(angle)) * idealLength
                placed[i] = true
                changed = true
            }
        }
        for i in nodes.indices where !placed[i] {
            let angle = Double(i) * 2.399963
            pos[i] = Point(cos(angle), sin(angle)) * (idealLength * (1.5 + Double(i) * 0.15))
        }

        let pinnedIdx = Set(pinned.compactMap { index[$0] })
        let k = idealLength
        var temperature = idealLength
        let cooling = pow(0.01, 1 / Double(max(1, iterations)))
        var disp = Array(repeating: Point.zero, count: nodes.count)
        for _ in 0..<iterations {
            for i in disp.indices { disp[i] = .zero }
            for i in 0..<nodes.count {
                for j in (i + 1)..<nodes.count {
                    var d = pos[i] - pos[j]
                    var dist = d.length
                    if dist < 0.01 {
                        // separate coincident nodes deterministically
                        d = Point(Double(i - j) * 0.1 + 0.05, 0.07)
                        dist = d.length
                    }
                    let f = repulsion * k * k / dist
                    let push = d * (f / dist)
                    disp[i] = disp[i] + push
                    disp[j] = disp[j] - push
                }
            }
            for (a, b) in links {
                let d = pos[a] - pos[b]
                let dist = max(0.01, d.length)
                let f = dist * dist / k
                let pull = d * (f / dist)
                disp[a] = disp[a] - pull
                disp[b] = disp[b] + pull
            }
            for i in nodes.indices where !pinnedIdx.contains(i) {
                let len = disp[i].length
                guard len > 0 else { continue }
                pos[i] = pos[i] + disp[i] * (min(len, temperature) / len)
            }
            temperature *= cooling
        }
        return Dictionary(nodes.enumerated().map { ($1, pos[$0]) }, uniquingKeysWith: { a, _ in a })
    }
}

/// The link families of loregraph's link types (DESIGN.md Appendix A), in the order the graph's
/// filters list them, with their words (F-9.2, F-9.4).
public enum LinkFamily {
    public static let all: [(key: String, label: String)] = [
        ("kinship", "Kinship"), ("membership", "Membership"), ("political", "Political"), ("event", "Events"),
        ("social", "Social"), ("spatial", "Places"), ("narrative", "Accounts and stories"), ("culture", "Culture"),
        ("life", "Life"), ("possession", "Possession"), ("measure", "Measures"),
    ]

    public static func label(_ key: String?) -> String {
        all.first { $0.key == key }?.label ?? "Other"
    }
}
