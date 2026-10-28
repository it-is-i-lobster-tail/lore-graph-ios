import LoreGraphKit
import SwiftUI

/// The timeline (F-6): the whole history as a strip with the window you're reading, and below
/// it the items in that window by decade, or in lanes.
struct TimelineScreen: View {
    let options: TimelineOptions

    var body: some View {
        ContextModel(make: { TimelineModel(options: options, context: $0) }, load: { await $0.load() }) { model in
            TimelineContent(model: model)
        }
    }
}

struct TimelineContent: View {
    @Bindable var model: TimelineModel
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var lanes: String?

    var body: some View {
        List {
            Loaded(loader: model.loader) { timeline in
                if let layout = model.layout {
                    Section {
                        TimelineStrip(model: model, layout: layout, eras: timeline.eras ?? [])
                            .frame(height: 96)
                            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        if let w = model.window {
                            HStack {
                                Text("YV \(Int(w.from)) to \(Int(w.to))").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Show all") { model.window = nil }.font(.caption)
                            }
                        }
                    } footer: {
                        Text("Pinch the strip to zoom, drag to move through time.")
                    }
                    if timeline.items.isEmpty {
                        ContentUnavailableView("Nothing dated", systemImage: "calendar",
                                               description: Text("No events or dated records here yet."))
                    }
                    let groups = lanes.map { scheme in layout.lanes(scheme).map { g in
                        TimelineLayout.Group(title: g.title, items: g.items.filter { inWindow($0, layout) })
                    }.filter { !$0.items.isEmpty } } ?? layout.groups(in: model.window)
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.items) { item in
                                TimelineRow(item: item)
                                    .contextMenu { itemMenu(item) }
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
        .staleBanner(model.loader)
        .navigationTitle(model.options.about.isEmpty ? "Timeline" : "Timeline of \(model.options.about.joined(separator: ", "))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Group", selection: $lanes) {
                        Text("By decade").tag(String?.none)
                        Text("Lanes by type").tag(String?.some("type"))
                        Text("Lanes by faction").tag(String?.some("faction"))
                        Text("Lanes by place").tag(String?.some("place"))
                        Text("Lanes by person").tag(String?.some("person"))
                    }
                    Toggle("Show claimed dates", isOn: Binding(get: { model.options.claims }, set: { on in
                        var o = model.options
                        o.claims = on
                        Task { await model.set(o) }
                    }))
                    ShareLink("Share web link", item: model.shareURL)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Timeline options")
            }
        }
        .onChange(of: lanes) { _, scheme in
            var o = model.options
            o.lanes = scheme
            Task { await model.set(o) }
        }
    }

    func inWindow(_ item: Timeline.Item, _ layout: TimelineLayout) -> Bool {
        guard let w = model.window else { return true }
        guard let bar = layout.bars.first(where: { $0.item.id == item.id && $0.item.kind == item.kind }) else { return false }
        return w.overlaps(bar.outer ?? bar.range)
    }

    @ViewBuilder func itemMenu(_ item: Timeline.Item) -> some View {
        if let ref = item.ref {
            Button("Open page", systemImage: "doc.text") { navigator.open(.page(ref)) }
            Button("Show on map", systemImage: "map") {
                // the map at the item's year with its site selected (F-6.6)
                if let y = item.date.from ?? item.date.to {
                    var v = app.view
                    v.asOf = y
                    v.asOfLabel = item.date.label
                    app.setView(v)
                }
                navigator.open(.map(MapOptions(select: ref)))
            }
            Button("Timeline of this", systemImage: "calendar") { navigator.open(.timeline(TimelineOptions(about: [ref]))) }
        }
        if item.kind == "statement" {
            Button("Open the record", systemImage: "list.bullet.rectangle") { navigator.open(.record(item.id)) }
        }
    }
}

struct TimelineRow: View {
    let item: Timeline.Item

    var body: some View {
        NavigationLink(value: item.kind == "statement" ? Route.record(item.id) : Route.page(item.ref ?? item.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: item.kind == "statement" ? "link" : "diamond.fill")
                    .font(.caption)
                    .foregroundStyle(item.isClaim ? Color.claim : Color.accentInk)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.reading())
                    HStack(spacing: 6) {
                        Text(item.date.text).foregroundStyle(.secondary)
                        if item.date.isCirca { Chip(text: "approximate") }
                        if let a = item.accordingTo {
                            Text("claimed by \(a.shownTitle)").foregroundStyle(Color.claim)
                        }
                        VisibilityChip(visibility: item.visibility, compact: true)
                    }
                    .font(.caption)
                }
            }
        }
        .visibilityEdge(item.visibility)
    }
}

/// The overview strip: eras on top, every bar in its row, the window you're reading outlined.
struct TimelineStrip: View {
    let model: TimelineModel
    let layout: TimelineLayout
    let eras: [Timeline.Era]
    @State private var pinchBase: TimeWindow?
    @State private var dragBase: TimeWindow?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let extent = layout.extent
            Canvas { ctx, size in
                func x(_ y: Double) -> Double { extent.fraction(y) * size.width }
                // eras
                for (i, era) in eras.enumerated() {
                    guard let r = era.span.drawnRange else { continue }
                    let rect = CGRect(x: x(r.lowerBound), y: 0, width: max(1, x(r.upperBound) - x(r.lowerBound)), height: 6)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color.accentInk.opacity(i % 2 == 0 ? 0.25 : 0.4)))
                }
                // bars, rows squeezed into the space
                let rows = max(1, layout.rows)
                let rowH = min(8, (size.height - 30) / Double(rows))
                for bar in layout.bars {
                    let y = 10 + Double(bar.row) * rowH
                    if let o = bar.outer {
                        ctx.fill(Path(CGRect(x: x(o.lowerBound), y: y, width: max(2, x(o.upperBound) - x(o.lowerBound)), height: max(2, rowH - 1))),
                                 with: .color(.secondary.opacity(0.2)))
                    }
                    let colour: Color = bar.item.isClaim ? .claim : (bar.item.visibility == .designer ? .designer : .accentInk)
                    if bar.isPoint {
                        ctx.fill(Path(ellipseIn: CGRect(x: x(bar.range.lowerBound) - 2, y: y, width: 4, height: max(3, rowH - 1))),
                                 with: .color(colour))
                    } else {
                        ctx.fill(Path(CGRect(x: x(bar.range.lowerBound), y: y, width: max(2, x(bar.range.upperBound) - x(bar.range.lowerBound)),
                                             height: max(2, rowH - 1))), with: .color(colour.opacity(0.8)))
                    }
                }
                // the present
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x(layout.present), y: 0))
                    p.addLine(to: CGPoint(x: x(layout.present), y: size.height - 18))
                }, with: .color(.orange), lineWidth: 1)
                // ticks
                for tick in TimelineLayout.ticks(extent, maxTicks: max(2, Int(size.width / 70))) {
                    ctx.draw(Text(tick.label).font(.caption2).foregroundStyle(.secondary),
                             at: CGPoint(x: x(tick.year), y: size.height - 8))
                }
                // the window
                if let w = model.window {
                    let rect = CGRect(x: x(w.from), y: 8, width: max(4, x(w.to) - x(w.from)), height: size.height - 26)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.primary), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { v in
                    let base = pinchBase ?? model.shownWindow ?? extent
                    if pinchBase == nil { pinchBase = base }
                    let year = extent.year(atFraction: v.startLocation.x / width)
                    model.window = base.zoomed(by: v.magnification, around: year, within: extent)
                }
                .onEnded { _ in pinchBase = nil })
            .simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { v in
                    let base = dragBase ?? model.shownWindow ?? extent
                    if dragBase == nil { dragBase = base }
                    let years = v.translation.width / width * extent.span
                    model.window = base.panned(by: years, within: extent)
                }
                .onEnded { _ in dragBase = nil })
            .onTapGesture(count: 2) { model.window = nil }
            .accessibilityElement()
            .accessibilityLabel("Timeline overview from YV \(Int(extent.from)) to \(Int(extent.to)), \(layout.bars.count) items")
        }
    }
}
