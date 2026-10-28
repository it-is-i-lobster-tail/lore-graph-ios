import LoreGraphKit
import SwiftUI

/// The Family tab: the last tree you opened, or a people picker (F-8.8).
struct FamilyTab: View {
    @Environment(Navigation.self) private var nav

    var body: some View {
        if let ref = nav.lastFamily {
            FamilyScreen(ref: ref, options: FamilyOptions())
                .id(ref)
        } else {
            PeoplePicker(title: "Family trees", prompt: "Whose family?") { card in
                nav.lastFamily = card.ref
            }
        }
    }
}

/// Picks a page by name, starting from pages read recently (family and graph tabs).
struct PeoplePicker: View {
    let title: String
    let prompt: String
    var types: [EntityType] = [.individual]
    let pick: (EntityCard) -> Void
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var hits: [Suggestions.Candidate] = []

    var body: some View {
        List {
            if hits.isEmpty {
                let recent = app.recentPages.filter { types.contains($0.type ?? .misc) }
                if recent.isEmpty {
                    ContentUnavailableView(prompt, systemImage: "magnifyingglass",
                                           description: Text("Search for a name to start."))
                } else {
                    Section("Recently read") {
                        ForEach(recent, id: \.ref) { c in
                            Button { pick(c) } label: { EntityRow(card: c) }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                ForEach(hits) { c in
                    Button { pick(c.card) } label: { EntityRow(card: c.card) }.buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: prompt)
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2, let c = app.context else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hits = (try? await c.repository.client.get(API.suggest(q, types: types), world: c.world, view: c.view).value.candidates) ?? []
        }
        .navigationTitle(title)
    }
}

/// A family tree around a person (F-8.1 to F-8.7).
struct FamilyScreen: View {
    let ref: String
    let options: FamilyOptions
    @Environment(Navigation.self) private var nav

    var body: some View {
        ContextModel(make: { FamilyModel(ref: ref, options: options, context: $0) }, load: { await $0.load() }) { model in
            FamilyContent(model: model)
        }
        .onAppear { nav.lastFamily = ref }
    }
}

struct FamilyContent: View {
    let model: FamilyModel
    @Environment(Navigator.self) private var navigator
    @Environment(AppModel.self) private var app
    @State private var scale = 1.0
    @State private var pinchBase = 1.0
    @State private var asList = false
    @State private var accounts: Loader<AccountList>?

    var body: some View {
        Group {
            if asList {
                FamilyList(model: model)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Loaded(loader: model.loader) { _ in
                        if let layout = model.layout {
                            FamilyCanvas(model: model, layout: layout, scale: scale)
                        }
                    }
                }
                .defaultScrollAnchor(.center)
                .gesture(MagnifyGesture()
                    .onChanged { scale = max(0.35, min(2.5, pinchBase * $0.magnification)) }
                    .onEnded { _ in pinchBase = scale })
                .refreshable { await model.refresh() }
            }
        }
        .staleBanner(model.loader)
        .safeAreaInset(edge: .bottom) { KinshipCard(model: model) }
        .navigationTitle(model.loader.value?.root.shownTitle ?? "Family tree")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Shape", selection: Binding(get: { model.options.mode }, set: { mode in
                        var o = model.options
                        o.mode = mode
                        Task { await model.set(o) }
                    })) {
                        Text("Hourglass").tag(FamilyOptions.Mode.hourglass)
                        Text("Ancestors").tag(FamilyOptions.Mode.ancestors)
                        Text("Descendants").tag(FamilyOptions.Mode.descendants)
                    }
                    Button("One more generation up", systemImage: "arrow.up") { Task { await model.more(up: 1) } }
                    Button("One more generation down", systemImage: "arrow.down") { Task { await model.more(down: 1) } }
                    if let list = accounts?.value?.accounts, !list.isEmpty {
                        Picker("Version", selection: Binding(get: { model.options.account }, set: { a in
                            var o = model.options
                            o.account = a
                            Task { await model.set(o) }
                        })) {
                            Text("The record").tag(String?.none)
                            ForEach(list, id: \.account.ref) { Text("As \($0.account.shownTitle) tells it").tag(String?.some($0.account.ref)) }
                        }
                    }
                    Toggle("Show as a list", isOn: $asList)
                    ShareLink("Share web link", item: model.shareURL)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Tree options")
            }
        }
        .task {
            guard accounts == nil, let c = app.context else { return }
            let l = c.loader(API.accounts(model.ref))
            accounts = l
            await l.load()
        }
    }
}

/// The tree drawn: lines and union dots underneath, person cards on top.
struct FamilyCanvas: View {
    let model: FamilyModel
    let layout: FamilyLayout
    let scale: Double
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let highlighted = Set(model.highlighted.map(\.id))
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                ctx.scaleBy(x: scale, y: scale)
                for line in layout.lines {
                    var path = Path()
                    guard let first = line.points.first else { continue }
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for p in line.points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    let colour: Color = highlighted.contains(line.id) ? .accentInk
                        : line.accordingTo != nil ? .claim : Color.visibility(line.visibility == .public ? nil : line.visibility)
                    let dash: [CGFloat] = (line.dashed || line.disputed || line.visibility == .designer) ? [5, 4] : []
                    ctx.stroke(path, with: .color(colour.opacity(line.visibility == .public && !highlighted.contains(line.id) ? 0.7 : 1)),
                               style: StrokeStyle(lineWidth: highlighted.contains(line.id) ? 3 : 1.5, dash: dash))
                }
                for dot in layout.unions {
                    ctx.fill(Path(ellipseIn: CGRect(x: dot.centre.x - 4, y: dot.centre.y - 4, width: 8, height: 8)),
                             with: .color(.secondary))
                }
            }
            .frame(width: layout.size.width * scale, height: layout.size.height * scale)
            ForEach(layout.cards) { card in
                PersonCard(card: card, selected: model.selected == card.person.ref)
                    .frame(width: card.frame.size.width, height: card.frame.size.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(x: card.frame.minX * scale, y: card.frame.minY * scale)
                    .onTapGesture(count: 2) {
                        navigator.open(.family(card.person.ref, model.options))
                    }
                    .onTapGesture {
                        Task { await model.select(card.person.ref) }
                    }
                    .contextMenu {
                        Button("Open page", systemImage: "doc.text") { navigator.open(.page(card.person.ref)) }
                        Button("Centre the tree here", systemImage: "scope") { navigator.open(.family(card.person.ref, model.options)) }
                        Button("How are they related?", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            Task { await model.select(card.person.ref) }
                        }
                    }
            }
        }
        .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
    }
}

struct PersonCard: View {
    let card: FamilyLayout.Card
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(card.person.shownTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                if card.status == .dead { Text("†").accessibilityLabel("dead") }
                Spacer(minLength: 0)
                if let v = card.person.visibility, v != .public {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Color.visibility(v))
                        .accessibilityLabel(v.label)
                }
            }
            if let life = card.person.lifespan, !life.text.isEmpty {
                Text(life.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let d = card.person.shortDescription {
                Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.orange : card.isRoot ? Color.accentInk : Color.clear,
                                                           lineWidth: 2))
        .opacity(card.status == .dead ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// How the root and the picked person are related, with the path (F-8.6).
struct KinshipCard: View {
    let model: FamilyModel

    var body: some View {
        if let k = model.kinship {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(Color.accentInk)
                VStack(alignment: .leading, spacing: 4) {
                    if let v = k.value {
                        Text(v.sentence ?? v.relationship ?? "Not related on the record").font(.subheadline.weight(.medium))
                        if let common = v.commonAncestors, !common.isEmpty {
                            Text("Common ancestors: " + common.map(\.shownTitle).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let e = k.error {
                        Text(e.message).font(.subheadline)
                    } else {
                        ProgressView()
                    }
                }
                Spacer()
                Button("Close", systemImage: "xmark") { Task { await model.select(nil) } }
                    .labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding()
        }
    }
}

/// The tree as lists by generation, the way through it for VoiceOver (F-11.5).
struct FamilyList: View {
    let model: FamilyModel

    var body: some View {
        List {
            if let tree = model.loader.value {
                let gens = Array(Set(tree.people.map(\.generation))).sorted()
                ForEach(gens, id: \.self) { g in
                    Section(g == 0 ? "Generation of \(tree.root.shownTitle)" : g < 0 ? "\(-g) up" : "\(g) down") {
                        ForEach(tree.people.filter { $0.generation == g }) { p in
                            NavigationLink(value: Route.page(p.ref)) {
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(p.shownTitle)
                                        VisibilityChip(visibility: p.visibility, compact: true)
                                    }
                                    let parents = tree.parents.filter { $0.child == p.ref }.compactMap { link in
                                        tree.people.first { $0.ref == link.parent }?.shownTitle
                                    }
                                    if !parents.isEmpty {
                                        Text("Child of " + parents.joined(separator: " and ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
    }
}
