import LoreGraphKit
import SwiftUI

/// Draws the map: base map images, then each layer's styled paths, the selection, the measured
/// route and the labels; pinch, drag with inertia, double-tap to zoom, tap to select and
/// long-press for what's here (F-7.1 to F-7.3).
struct MapCanvas: View {
    let model: MapModel
    var interactive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragStart: Viewport?
    @State private var pinchStart: Viewport?
    @State private var motion: Task<Void, Never>?
    @State private var paths = PathCache()
    @State private var images = TileImages()

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                draw(&ctx, size: size)
            }
            .background(Color(model.palette.land))
            .contentShape(Rectangle())
            .gesture(drag, including: interactive ? .all : .none)
            .simultaneousGesture(pinch, including: interactive ? .all : .none)
            .simultaneousGesture(longPress, including: interactive ? .all : .none)
            .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                if interactive { animateZoom(by: 2, around: Point(loc.x, loc.y)) }
            }
            .onTapGesture(coordinateSpace: .local) { loc in
                if interactive { Task { await model.tap(at: Point(loc.x, loc.y)) } }
            }
            .onAppear { model.resize(Size(geo.size.width, geo.size.height)) }
            .onChange(of: geo.size) { _, s in model.resize(Size(s.width, s.height)) }
            .accessibilityElement()
            .accessibilityLabel("Map")
            .accessibilityValue(MapProjection.format(model.viewport.centreLonLat) + ", zoom \(Int(model.viewport.zoom))")
            .accessibilityAdjustableAction { direction in
                animateZoom(by: direction == .increment ? 2 : 0.5, around: Point(model.viewport.size.width / 2, model.viewport.size.height / 2))
            }
        }
    }

    // MARK: gestures

    var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { v in
                motion?.cancel()
                guard pinchStart == nil else {
                    dragStart = nil
                    return
                }
                let start = dragStart ?? model.viewport
                if dragStart == nil { dragStart = start }
                model.setViewport(start.panned(by: Point(v.translation.width, v.translation.height)))
            }
            .onEnded { v in
                defer { dragStart = nil }
                guard pinchStart == nil, dragStart != nil, !reduceMotion else { return }
                let fling = Point(v.predictedEndTranslation.width - v.translation.width,
                                  v.predictedEndTranslation.height - v.translation.height)
                coast(fling)
            }
    }

    var pinch: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .onChanged { v in
                motion?.cancel()
                let start = pinchStart ?? model.viewport
                if pinchStart == nil { pinchStart = start }
                model.setViewport(start.zoomed(by: v.magnification, around: Point(v.startLocation.x, v.startLocation.y)))
            }
            .onEnded { _ in
                pinchStart = nil
                dragStart = nil
            }
    }

    var longPress: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                if case .second(true, let drag?) = value, drag.translation.width.magnitude < 10, drag.translation.height.magnitude < 10 {
                    Task { await model.whatsHere(at: Point(drag.startLocation.x, drag.startLocation.y)) }
                }
            }
    }

    /// The map glides on after a fling, easing out.
    func coast(_ fling: Point) {
        guard fling.length > 20 else { return }
        motion?.cancel()
        motion = Task { @MainActor in
            let steps = 22
            var done = 0.0
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let t = Double(i) / Double(steps)
                let eased = 1 - pow(1 - t, 3)
                let delta = eased - done
                done = eased
                model.setViewport(model.viewport.panned(by: fling * delta))
            }
        }
    }

    func animateZoom(by factor: Double, around p: Point) {
        motion?.cancel()
        if reduceMotion {
            model.setViewport(model.viewport.zoomed(by: factor, around: p))
            return
        }
        motion = Task { @MainActor in
            let steps = 12
            let start = model.viewport
            for i in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                let t = Double(i) / Double(steps)
                let eased = 1 - pow(1 - t, 2)
                model.setViewport(start.zoomed(by: pow(factor, eased), around: p))
            }
        }
    }

    // MARK: drawing

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let vp = model.viewport
        let pal = model.palette
        for (tile, data) in model.rasterList {
            guard let image = images.image(tile, data) else { continue }
            let f = vp.frame(of: tile)
            ctx.draw(Image(uiImage: image), in: CGRect(x: f.minX, y: f.minY, width: f.size.width, height: f.size.height))
        }
        for piece in model.drawList {
            drawPiece(piece, in: &ctx, viewport: vp, palette: pal)
        }
        drawMeasure(in: &ctx, viewport: vp, palette: pal)
        let labels = model.placedLabels()
        guard !labels.isEmpty else { return }
        ctx.drawLayer { layer in
            layer.addFilter(.shadow(color: Color(pal.halo), radius: 1.6))
            layer.addFilter(.shadow(color: Color(pal.halo), radius: 0.8))
            for label in labels {
                let s = label.candidate.style
                var font = Font.system(size: s.fontSize, weight: s.rank <= 2 ? .semibold : .regular, design: s.serif ? .serif : .default)
                if s.italic { font = font.italic() }
                let text = Text(s.shownText).font(font).foregroundStyle(Color(s.colour))
                if label.candidate.angle != 0 {
                    var c = layer
                    c.translateBy(x: label.centre.x, y: label.centre.y)
                    c.rotate(by: .radians(label.candidate.angle))
                    c.draw(text, at: .zero)
                } else {
                    layer.draw(text, at: CGPoint(x: label.centre.x, y: label.centre.y))
                }
            }
        }
    }

    func drawPiece(_ piece: ScenePiece, in ctx: inout GraphicsContext, viewport vp: Viewport, palette pal: MapPalette) {
        let t = piece.transform(in: vp)
        let scale = max(abs(t.a), 1e-12)
        let affine = CGAffineTransform(a: t.a, b: 0, c: 0, d: t.d, tx: t.tx, ty: t.ty)
        for (i, g) in piece.groups.enumerated() {
            let (rings, lines) = paths.paths(piece.id.isEmpty ? nil : "\(piece.id)#\(i)", group: g)
            let st = g.style
            if !g.rings.isEmpty || !g.lines.isEmpty || st.uncertaintyMetres != nil {
                var c = ctx
                c.concatenate(affine)
                if let r = st.uncertaintyMetres, r > 0 {
                    var halo = Path()
                    for p in g.halos { halo.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)) }
                    c.fill(halo, with: .color(Color(pal.ink.opacity(0.08))))
                }
                if let fill = st.fill, !g.rings.isEmpty {
                    c.fill(rings, with: .color(Color(fill)), style: FillStyle(eoFill: true))
                }
                if let stroke = st.stroke {
                    let style = StrokeStyle(lineWidth: st.strokeWidth / scale, lineCap: .round, lineJoin: .round,
                                            dash: (st.dash ?? []).map { CGFloat($0 / scale) })
                    if !g.rings.isEmpty { c.stroke(rings, with: .color(Color(stroke)), style: style) }
                    if !g.lines.isEmpty { c.stroke(lines, with: .color(Color(stroke)), style: style) }
                }
            }
            if let marker = st.marker, !g.points.isEmpty {
                var m = Path()
                let r = st.markerRadius
                for p in g.points {
                    let s = CGPoint(x: t.a * p.x + t.tx, y: t.d * p.y + t.ty)
                    guard s.x > -r * 2, s.y > -r * 2, s.x < vp.size.width + r * 2, s.y < vp.size.height + r * 2 else { continue }
                    switch marker {
                    case .circle:
                        m.addEllipse(in: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r))
                    case .diamond:
                        m.move(to: CGPoint(x: s.x, y: s.y - r))
                        m.addLine(to: CGPoint(x: s.x + r, y: s.y))
                        m.addLine(to: CGPoint(x: s.x, y: s.y + r))
                        m.addLine(to: CGPoint(x: s.x - r, y: s.y))
                        m.closeSubpath()
                    case .triangle:
                        m.move(to: CGPoint(x: s.x, y: s.y - r))
                        m.addLine(to: CGPoint(x: s.x + r * 0.9, y: s.y + r * 0.7))
                        m.addLine(to: CGPoint(x: s.x - r * 0.9, y: s.y + r * 0.7))
                        m.closeSubpath()
                    }
                }
                if let f = st.markerFill { ctx.fill(m, with: .color(Color(f))) }
                if let s = st.markerStroke { ctx.stroke(m, with: .color(Color(s)), lineWidth: st.markerStrokeWidth) }
            }
        }
    }

    func drawMeasure(in ctx: inout GraphicsContext, viewport vp: Viewport, palette pal: MapPalette) {
        let pts = model.measurePoints.map { vp.toScreen($0) }
        guard !pts.isEmpty else { return }
        var line = Path()
        line.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
        for p in pts.dropFirst() { line.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.stroke(line, with: .color(Color(pal.halo)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        ctx.stroke(line, with: .color(Color(pal.accent)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [8, 5]))
        for p in pts {
            let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: r), with: .color(Color(pal.accent)))
            ctx.stroke(Path(ellipseIn: r), with: .color(Color(pal.halo)), lineWidth: 2)
        }
    }
}

/// Paths built once per piece and style group, in the piece's own space.
final class PathCache {
    private var store: [String: (Path, Path)] = [:]

    func paths(_ key: String?, group g: StyledGroup) -> (Path, Path) {
        if let key, let hit = store[key] { return hit }
        var rings = Path()
        for ring in g.rings where ring.count > 1 {
            rings.move(to: CGPoint(x: ring[0].x, y: ring[0].y))
            for p in ring.dropFirst() { rings.addLine(to: CGPoint(x: p.x, y: p.y)) }
            rings.closeSubpath()
        }
        var lines = Path()
        for line in g.lines where line.count > 1 {
            lines.move(to: CGPoint(x: line[0].x, y: line[0].y))
            for p in line.dropFirst() { lines.addLine(to: CGPoint(x: p.x, y: p.y)) }
        }
        if let key {
            if store.count > 4000 { store.removeAll(keepingCapacity: true) }
            store[key] = (rings, lines)
        }
        return (rings, lines)
    }
}

/// Base map images decoded once.
final class TileImages {
    private var store: [String: UIImage] = [:]

    func image(_ tile: TileID, _ data: Data) -> UIImage? {
        let key = "\(tile)|\(data.count)"
        if let hit = store[key] { return hit }
        guard let image = UIImage(data: data) else { return nil }
        if store.count > 300 { store.removeAll(keepingCapacity: true) }
        store[key] = image
        return image
    }
}
