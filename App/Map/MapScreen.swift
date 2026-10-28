import LoreGraphKit
import SwiftUI

/// The map (F-7): the canvas with layers, the time slider, selection, what's here and measuring.
struct MapScreen: View {
    let options: MapOptions
    var isTab = false
    @Environment(AppModel.self) private var app
    @State private var model: MapModel?

    var body: some View {
        Group {
            if let model {
                MapContent(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: app.context?.key) {
            guard let c = app.context else { return }
            if let model {
                await model.setContext(c)
            } else {
                let m = MapModel(options: options, camera: isTab ? app.camera : nil, context: c)
                model = m
                await m.load()
            }
        }
        .onDisappear {
            if isTab, let model { app.setCamera(model.camera) }
        }
    }
}

struct MapContent: View {
    let model: MapModel
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showLayers = false
    @State private var findPlace = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            MapCanvas(model: model)
                .ignoresSafeArea(edges: .bottom)
            ScaleBar(viewport: model.viewport)
                .padding(.leading, 12)
                .padding(.bottom, 8)
            if let error = model.layers.error, model.layers.value == nil {
                ErrorState(error: error) { await model.refresh() }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
            }
        }
        .safeAreaInset(edge: .top) {
            if model.failedTiles > 0, let e = model.lastError {
                Label(e.isOffline ? "Offline: showing the map tiles saved on this device." : e.message,
                      systemImage: e.isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.footnote)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if model.measuring {
                    MeasureCard(model: model)
                } else if sizeClass != .regular, model.selection != nil {
                    SelectionCard(model: model)
                }
                TimeSlider()
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
        .inspector(isPresented: Binding(get: { sizeClass == .regular && model.selection != nil && !model.measuring },
                                        set: { if !$0 { model.clearSelection() } })) {
            ScrollView { SelectionCard(model: model, inInspector: true).padding() }
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Find a place", systemImage: "magnifyingglass") { findPlace = true }
                Button("Layers", systemImage: "square.3.layers.3d") { showLayers = true }
                    .accessibilityIdentifier("mapLayers")
                Menu {
                    Toggle("Measure", systemImage: "ruler", isOn: Binding(get: { model.measuring }, set: { model.setMeasuring($0) }))
                    Button("Refresh the map", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    ShareLink("Share web link", item: model.shareURL)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More map actions")
            }
        }
        .sheet(isPresented: $showLayers) {
            LayerSheet(model: model).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $findPlace) {
            NavigationStack {
                PeoplePicker(title: "Find a place", prompt: "A place", types: [.location]) { card in
                    findPlace = false
                    Task { await model.flyTo(card.ref) }
                }
            }
        }
        .onAppear { model.setPalette(scheme == .dark ? .dark : .light) }
        .onChange(of: scheme) { _, s in model.setPalette(s == .dark ? .dark : .light) }
    }
}

/// A round length for the latitude at the centre (F-7.11).
struct ScaleBar: View {
    let viewport: Viewport

    var body: some View {
        let bar = MapProjection.scaleBar(zoom: viewport.zoom, latitude: viewport.centreLonLat.lat)
        VStack(alignment: .leading, spacing: 2) {
            Text(bar.label).font(.caption2.weight(.medium))
            Rectangle().frame(width: bar.points, height: 3)
                .overlay(alignment: .leading) { Rectangle().frame(width: 1.5, height: 8) }
                .overlay(alignment: .trailing) { Rectangle().frame(width: 1.5, height: 8) }
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Scale: \(bar.label)")
    }
}

/// Layers by group, and the base map (F-7.4, F-7.5).
struct LayerSheet: View {
    let model: MapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.availableBaseMaps.count > 1 {
                    Section("Base map") {
                        Picker("Base map", selection: Binding(get: { model.baseMap }, set: { model.setBaseMap($0) })) {
                            ForEach(model.availableBaseMaps, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                ForEach(model.layerGroups, id: \.group) { group in
                    Section(group.group) {
                        ForEach(group.layers) { layer in
                            Toggle(isOn: Binding(get: { model.visible.contains(layer.key) }, set: { _ in model.toggle(layer.key) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(layer.title)
                                        VisibilityChip(visibility: layer.visibility, compact: true)
                                    }
                                    if let d = layer.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            .accessibilityIdentifier("layer-\(layer.key)")
                        }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The year the map shows, from the early years to the present, with era bands and play (F-7.6).
struct TimeSlider: View {
    @Environment(AppModel.self) private var app
    @State private var eras: Loader<Timeline>?
    @State private var dragging: Double?
    @State private var playing: Task<Void, Never>?

    var body: some View {
        let present = app.context?.present ?? 1131.25
        let range = YearText.sliderRange(eras: eras?.value?.eras ?? [], present: present)
        let year = dragging ?? app.view.asOf ?? present
        VStack(spacing: 2) {
            HStack(spacing: 10) {
                Button {
                    togglePlay(range: range)
                } label: {
                    Image(systemName: playing == nil ? "play.fill" : "pause.fill")
                }
                .accessibilityLabel(playing == nil ? "Play through the years" : "Pause")
                VStack(spacing: 0) {
                    EraBands(eras: eras?.value?.eras ?? [], range: range).frame(height: 4)
                    Slider(value: Binding(get: { min(max(year, range.lowerBound), range.upperBound) }, set: { dragging = $0 }),
                           in: range, step: 0.25) { editing in
                        if !editing, let y = dragging {
                            setYear(y, present: present)
                            dragging = nil
                        }
                    }
                    .accessibilityValue(YearText.label(year))
                }
                Text(dragging.map(YearText.label) ?? (app.view.asOf == nil ? "Present" : (app.view.asOfLabel ?? YearText.label(year))))
                    .font(.caption.monospacedDigit())
                    .frame(width: 104, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .task(id: app.context?.world) {
            guard let c = app.context else { return }
            let l = c.loader(API.eras())
            eras = l
            await l.load()
        }
        .onDisappear {
            playing?.cancel()
            playing = nil
        }
    }

    func setYear(_ y: Double, present: Double) {
        var v = app.view
        if y >= present - 0.001 {
            v.asOf = nil
            v.asOfLabel = nil
        } else {
            v.asOf = y
            v.asOfLabel = nil
        }
        app.setView(v)
    }

    func togglePlay(range: ClosedRange<Double>) {
        if let p = playing {
            p.cancel()
            playing = nil
            return
        }
        playing = Task { @MainActor in
            var y = floor(app.view.asOf ?? range.lowerBound)
            if y >= range.upperBound - 1 { y = range.lowerBound }
            while !Task.isCancelled, y < range.upperBound {
                y += 1
                setYear(min(y, range.upperBound), present: range.upperBound)
                try? await Task.sleep(for: .milliseconds(700))
            }
            playing = nil
        }
    }
}

struct EraBands: View {
    let eras: [Timeline.Era]
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(eras.enumerated()), id: \.offset) { i, era in
                if let r = era.span.drawnRange {
                    let span = range.upperBound - range.lowerBound
                    let lo = (max(r.lowerBound, range.lowerBound) - range.lowerBound) / span
                    let hi = (min(r.upperBound, range.upperBound) - range.lowerBound) / span
                    if hi > lo {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentInk.opacity(i % 2 == 0 ? 0.25 : 0.45))
                            .frame(width: (hi - lo) * geo.size.width, height: 4)
                            .offset(x: lo * geo.size.width)
                            .accessibilityLabel(era.name)
                    }
                }
            }
        }
    }
}

/// The tapped place's card, or what's at a long-pressed point (F-7.8, F-7.9).
struct SelectionCard: View {
    let model: MapModel
    var inInspector = false
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                content
                Spacer(minLength: 0)
                if !inInspector {
                    Button("Close", systemImage: "xmark") { model.clearSelection() }.labelStyle(.iconOnly)
                }
            }
        }
        .padding(14)
        .background(inInspector ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder var content: some View {
        switch model.selection {
        case .feature(let info, let where_):
            VStack(alignment: .leading, spacing: 6) {
                if let p = model.preview {
                    if let d = p.value {
                        EntityRow(card: d.entity.card)
                        if let s = d.entity.shortDescription { Text(s).font(.reading(.subheadline)).lineLimit(3) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(PageAction.actions(for: d).filter { $0 != .map }.prefix(5)) { a in
                                    Button {
                                        navigator.open(a.route(d.entity.slug ?? d.entity.ref))
                                    } label: {
                                        Label(a.label, systemImage: a.symbol).font(.caption.weight(.medium))
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        Button("Open page", systemImage: "doc.text") { navigator.open(.page(d.entity.slug ?? d.entity.ref)) }
                            .buttonStyle(.borderedProminent)
                    } else if let e = p.error {
                        Text(e.message).font(.subheadline)
                    } else {
                        ProgressView()
                    }
                } else {
                    Text(info.generatorName ?? info.label ?? kindLabel(info.cls) ?? "Map feature").font(.headline)
                    if let cls = info.cls { Text(kindLabel(cls) ?? cls).font(.caption).foregroundStyle(.secondary) }
                }
                if let w = where_ { Text(MapProjection.format(w)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        case .point(let p):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("What's here?").font(.headline)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = MapProjection.format(p, digits: 4)
                    } label: {
                        Label(MapProjection.format(p), systemImage: "doc.on.doc").font(.caption.monospacedDigit())
                    }
                    .accessibilityLabel("Copy coordinates")
                }
                if let l = model.placesAt {
                    if let at = l.value {
                        if let e = at.elevationM { Text("Elevation \(Int(e)) m").font(.caption).foregroundStyle(.secondary) }
                        ForEach(at.inside, id: \.entity.ref) { i in
                            Button { navigator.open(.page(i.entity.ref)) } label: {
                                Label("In \(i.entity.shownTitle)", systemImage: "square.dashed")
                            }
                        }
                        ForEach(at.nearest, id: \.entity.ref) { n in
                            Button { navigator.open(.page(n.entity.ref)) } label: {
                                HStack {
                                    Image(systemName: (n.entity.type ?? .location).symbol)
                                    Text(n.entity.shownTitle)
                                    Spacer()
                                    Text([n.distanceKm.map { String(format: "%.1f km", $0) }, n.direction].compactMap { $0 }.joined(separator: " "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(Array((at.features ?? []).enumerated()), id: \.offset) { _, f in
                            Text([f.name, kindLabel(f.class), f.distanceKm.map { String(format: "%.1f km", $0) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if at.inside.isEmpty && at.nearest.isEmpty { Text("Nothing recorded near here.").foregroundStyle(.secondary) }
                    } else if let e = l.error {
                        Text(e.message).font(.subheadline)
                    } else {
                        ProgressView()
                    }
                }
            }
            .buttonStyle(.plain)
        case nil:
            EmptyView()
        }
    }
}

/// The measured route: great-circle length and travel times (F-7.10).
struct MeasureCard: View {
    let model: MapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Measure", systemImage: "ruler").font(.headline)
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward") { Task { await model.undoMeasurePoint() } }
                    .labelStyle(.iconOnly)
                    .disabled(model.measurePoints.isEmpty)
                Button("Done", systemImage: "xmark") { model.setMeasuring(false) }.labelStyle(.iconOnly)
            }
            if model.measurePoints.count < 2 {
                Text("Tap the map to add points along the way.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                let km = model.distance?.totalKm ?? model.measuredKm
                Text(String(format: "%.1f km", km)).font(.title2.weight(.semibold).monospacedDigit())
                    .accessibilityLabel(String(format: "%.1f kilometres", km))
                if let travel = model.distance?.travel {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                        ForEach(Distance.modes, id: \.key) { mode in
                            if let t = travel[mode.key] {
                                Text("\(mode.label): \(t.days < 1 ? String(format: "%.0f hours", t.hours ?? t.days * 24) : String(format: "%.1f days", t.days))")
                                    .font(.caption)
                            }
                        }
                    }
                }
                if let w = model.distance?.warnings, !w.isEmpty {
                    Text(w.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A small map for a page's infobox, not interactive (F-4.5).
struct LocatorMap: View {
    let centre: LonLat
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @State private var model: MapModel?

    var body: some View {
        Group {
            if let model {
                MapCanvas(model: model, interactive: false)
                    .overlay {
                        Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.red, .white)
                            .accessibilityHidden(true)
                    }
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: app.context?.key) {
            guard let c = app.context else { return }
            let m = MapModel(options: MapOptions(centre: centre, zoom: 6), context: c, size: Size(320, 160))
            m.setPalette(scheme == .dark ? .dark : .light)
            model = m
            await m.load()
        }
    }
}
