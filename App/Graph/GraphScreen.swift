import LoreGraphKit
import SwiftUI

/// The Graph tab: pick a page to start from (F-9.1).
struct GraphTab: View {
    @Environment(Navigator.self) private var navigator

    var body: some View {
        PeoplePicker(title: "Graph", prompt: "Start from a page", types: EntityType.allCases) { card in
            navigator.open(.graph(GraphOptions(focus: [card.ref])))
        }
    }
}

/// The graph around pages (F-9.1 to F-9.7).
struct GraphScreen: View {
    let options: GraphOptions

    var body: some View {
        ContextModel(make: { GraphModel(options: options, context: $0) }, load: { await $0.load() }) { model in
            GraphContent(model: model)
        }
    }
}

extension LinkFamily {
    /// A colour per link family, always shown with the family's name in the legend and cards.
    static func colour(_ key: String?) -> Color {
        switch key {
        case "kinship": Color(red: 0.75, green: 0.35, blue: 0.1)
        case "membership": Color(red: 0.15, green: 0.45, blue: 0.75)
        case "political": Color(red: 0.7, green: 0.15, blue: 0.2)
        case "event": Color(red: 0.55, green: 0.35, blue: 0.7)
        case "social": Color(red: 0.1, green: 0.55, blue: 0.45)
        case "spatial": Color(red: 0.35, green: 0.5, blue: 0.15)
        case "narrative": Color(red: 0.85, green: 0.45, blue: 0.05)
        case "culture": Color(red: 0.6, green: 0.45, blue: 0.2)
        case "life": Color(red: 0.4, green: 0.4, blue: 0.45)
        case "possession": Color(red: 0.5, green: 0.3, blue: 0.3)
        case "measure": Color(red: 0.3, green: 0.3, blue: 0.6)
        default: .secondary
        }
    }
}

struct GraphContent: View {
    let model: GraphModel
    @Environment(Navigator.self) private var navigator
    @State private var asList = false
    @State private var scale = 1.0
    @State private var pinchBase = 1.0
    @State private var pickingPathEnd = false

    var body: some View {
        Group {
            if model.loader == nil {
                ContentUnavailableView("Pick a page", systemImage: "circle.hexagongrid",
                                       description: Text("Open the graph from a page, or pick one in the Graph tab."))
            } else if asList {
                GraphList(model: model)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    if let loader = model.loader {
                        Loaded(loader: loader) { _ in GraphCanvas(model: model, scale: scale) }
                    }
                }
                .defaultScrollAnchor(.center)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(0.3, min(2.5, pinchBase * $0.magnification)) }
                    .onEnded { _ in pinchBase = scale })
                .refreshable { await model.refresh() }
            }
        }
        .staleBanner(model.loader)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.truncated {
                    Text("Some neighbours were left out. Double-tap a node to grow the graph.")
                        .font(.caption).padding(8).background(.thinMaterial, in: Capsule())
                }
                if let paths = model.paths { PathsCard(model: model, paths: paths) }
                if let id = model.selected, let node = model.nodes.first(where: { $0.id == id }) {
                    NodeCard(model: model, node: node)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Graph")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("Link families") {
                        Button("All families") { Task { await model.set(families: []) } }
                        ForEach(LinkFamily.all, id: \.key) { f in
                            Button {
                                var set = model.families
                                if set.contains(f.key) { set.remove(f.key) } else { set.insert(f.key) }
                                Task { await model.set(families: set) }
                            } label: {
                                if model.families.contains(f.key) { Label(f.label, systemImage: "checkmark") } else { Text(f.label) }
                            }
                        }
                    }
                    Toggle("Show claims", isOn: Binding(get: { model.claims }, set: { on in Task { await model.set(claims: on) } }))
                    Picker("Depth", selection: Binding(get: { model.options.depth }, set: { d in Task { await model.set(depth: d) } })) {
                        Text("One step").tag(1)
                        Text("Two steps").tag(2)
                        Text("Three steps").tag(3)
                    }
                    Button("How does it connect to…", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        pickingPathEnd = true
                    }
                    Toggle("Show as a list", isOn: $asList)
                    ShareLink("Share web link", item: model.shareURL)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Graph options")
            }
        }
        .sheet(isPresented: $pickingPathEnd) {
            NavigationStack {
                PeoplePicker(title: "Connect to", prompt: "Another page", types: EntityType.allCases) { card in
                    pickingPathEnd = false
                    if let start = model.options.focus.first {
                        Task { await model.findPaths(from: start, to: card.ref) }
                    }
                }
            }
        }
    }
}

/// Nodes as shapes over coloured edges; tap to select, double-tap to expand, long-press for the
/// menu (F-9.2, F-9.3, F-9.6).
struct GraphCanvas: View {
    let model: GraphModel
    let scale: Double
    @Environment(Navigator.self) private var navigator
    static let pad = 80.0

    var body: some View {
        let nodes = model.nodes
        let pos = model.positions
        let xs = pos.values.map(\.x), ys = pos.values.map(\.y)
        let minX = (xs.min() ?? 0) - Self.pad, minY = (ys.min() ?? 0) - Self.pad
        let width = max(320, (xs.max() ?? 0) + Self.pad - minX), height = max(320, (ys.max() ?? 0) + Self.pad - minY)
        let pathEdges = Set(model.paths?.value?.paths.flatMap { $0.steps.compactMap(\.statementId) } ?? [])
        func at(_ id: String) -> CGPoint? {
            guard let p = pos[id] else { return nil }
            return CGPoint(x: (p.x - minX) * scale, y: (p.y - minY) * scale)
        }
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for e in model.edges {
                    guard let a = at(e.source), let b = at(e.target) else { continue }
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    let colour: Color = e.isClaim ? .claim : e.visibility == .designer ? .designer : LinkFamily.colour(e.family)
                    let selected = model.selected != nil && (e.source == model.selected || e.target == model.selected)
                    let onPath = pathEdges.contains(e.id)
                    ctx.stroke(path, with: .color(colour.opacity(selected || onPath ? 1 : 0.55)),
                               style: StrokeStyle(lineWidth: onPath ? 4 : selected ? 2.5 : 1.3,
                                                  dash: e.isClaim || e.visibility == .designer ? [6, 4] : []))
                }
            }
            .frame(width: width * scale, height: height * scale)
            ForEach(nodes) { node in
                if let p = at(node.id) {
                    NodeView(node: node, selected: model.selected == node.id,
                             focus: model.options.focus.contains(node.ref))
                        .position(p)
                        .onTapGesture(count: 2) { Task { await model.expand(node.id) } }
                        .onTapGesture { model.selected = model.selected == node.id ? nil : node.id }
                        .contextMenu {
                            Button("Expand", systemImage: "plus.circle") { Task { await model.expand(node.id) } }
                            Button("Focus here", systemImage: "scope") { Task { await model.set(focus: [node.ref]) } }
                            Button("Open page", systemImage: "doc.text") { navigator.open(.page(node.ref)) }
                            if node.type == .location { Button("Map", systemImage: "map") { navigator.open(.map(MapOptions(select: node.ref))) } }
                            if node.type == .individual {
                                Button("Family tree", systemImage: "figure.2.and.child.holdinghands") {
                                    navigator.open(.family(node.ref, FamilyOptions()))
                                }
                            }
                            Button("Timeline", systemImage: "calendar") { navigator.open(.timeline(TimelineOptions(about: [node.ref]))) }
                        }
                }
            }
        }
        .frame(width: width * scale, height: height * scale, alignment: .topLeading)
        .overlay {
            if model.isLayingOut && pos.isEmpty { ProgressView() }
        }
    }
}

struct NodeView: View {
    let node: Neighbourhood.Node
    let selected: Bool
    let focus: Bool

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: node.type.symbol)
                    .font(.system(size: focus ? 20 : 15))
                    .foregroundStyle(.white)
                    .frame(width: focus ? 42 : 34, height: focus ? 42 : 34)
                    .background(Circle().fill(node.visibility == .designer ? Color.designer : Color.accentInk))
                    .overlay(Circle().stroke(selected ? Color.orange : .clear, lineWidth: 3))
                if let more = node.more, more > 0 {
                    Text("+\(more)").font(.caption2.weight(.bold)).padding(.horizontal, 4)
                        .background(Capsule().fill(.orange)).foregroundStyle(.white)
                        .offset(x: 10, y: -6)
                }
            }
            Text(node.shownTitle)
                .font(.caption.weight(focus ? .semibold : .regular))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 110)
                .padding(.horizontal, 4)
                .background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.shownTitle), \(node.type.label)" + (node.visibility == .designer ? ", designer only" : ""))
        .accessibilityAddTraits(.isButton)
    }
}

/// The selected node's card and its links (F-9.3).
struct NodeCard: View {
    let model: GraphModel
    let node: Neighbourhood.Node
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EntityRow(card: node.card)
                Spacer()
                Button("Open", systemImage: "arrow.right.circle") { navigator.open(.page(node.ref)) }
                    .labelStyle(.iconOnly)
                Button("Close", systemImage: "xmark") { model.selected = nil }.labelStyle(.iconOnly)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.selectedEdges) { e in
                        let outgoing = e.source == node.id
                        let other = model.nodes.first { $0.id == (outgoing ? e.target : e.source) }
                        Button {
                            navigator.open(.record(e.id))
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Circle().fill(LinkFamily.colour(e.family)).frame(width: 8, height: 8)
                                Text((outgoing ? e.label : e.inverseLabel ?? e.label) ?? e.predicate).foregroundStyle(.secondary)
                                Text(other?.shownTitle ?? "")
                                if let v = e.valid, !v.text.isEmpty { Text(v.text).foregroundStyle(.secondary) }
                                if let a = e.accordingTo { Text("per \(a.shownTitle)").foregroundStyle(Color.claim) }
                                VisibilityChip(visibility: e.visibility, compact: true)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Up to five shortest paths, as sentences (F-9.5).
struct PathsCard: View {
    let model: GraphModel
    let paths: Loader<GraphPaths>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("How they connect").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { model.clearPaths() }.labelStyle(.iconOnly)
            }
            if let p = paths.value {
                if p.paths.isEmpty { Text("No connection found.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(Array(p.paths.enumerated()), id: \.offset) { _, path in
                    Text(path.sentence ?? path.steps.compactMap(\.label).joined(separator: ", "))
                        .font(.reading(.subheadline))
                }
            } else if let e = paths.error {
                Text(e.message).font(.subheadline)
            } else {
                ProgressView()
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The graph as lists (F-9.7).
struct GraphList: View {
    let model: GraphModel

    var body: some View {
        List(model.nodes) { node in
            Section {
                NavigationLink(value: Route.page(node.ref)) { EntityRow(card: node.card) }
                ForEach(model.edges.filter { $0.source == node.id }) { e in
                    let other = model.nodes.first { $0.id == e.target }
                    NavigationLink(value: Route.record(e.id)) {
                        Text("\(e.label ?? e.predicate) \(other?.shownTitle ?? "")")
                            .font(.subheadline)
                            .foregroundStyle(e.isClaim ? Color.claim : .primary)
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }
}
