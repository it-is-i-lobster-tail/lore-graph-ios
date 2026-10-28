import LoreGraphKit
import SwiftUI

/// The infobox: image, facts that open their records, and a locator map (F-4.5, F-4.13).
struct InfoboxView: View {
    let page: EntityDetail
    @Environment(AppModel.self) private var app
    @State private var fullImage: EntityDetail.Media?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image = page.infoboxImage, let server = app.reader?.server, let url = image.address(base: server) {
                Button {
                    fullImage = image
                } label: {
                    RemoteImage(url: url)
                        .frame(maxWidth: .infinity, maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(image.caption ?? image.title ?? "Image")
                if let caption = image.caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(Array((page.infobox ?? []).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    ForEach(Array(row.values.enumerated()), id: \.offset) { _, v in
                        InfoboxValue(value: v)
                    }
                }
                Divider()
            }
            if let point = page.locatorPoint {
                NavigationLink(value: Route.map(MapOptions(select: page.entity.slug ?? page.entity.ref))) {
                    LocatorMap(centre: LonLat(point.lon, point.lat))
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .bottomTrailing) {
                            Label("Map", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .padding(6)
                                .background(.thinMaterial, in: Capsule())
                                .padding(8)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show on the map")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .fullScreenCover(item: $fullImage) { media in
            ImageViewer(media: media)
        }
    }
}

struct InfoboxValue: View {
    let value: EntityDetail.InfoboxRow.Value

    /// "court_poet" → "Court poet".
    static func humanise(_ key: String) -> String {
        let s = key.split(whereSeparator: { "_.-".contains($0) }).joined(separator: " ")
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let ref = value.ref {
                NavigationLink(value: Route.page(ref)) { Text(value.text).font(.reading()) }
            } else if let id = value.statementId {
                NavigationLink(value: Route.record(id)) { Text(value.text).font(.reading()).foregroundStyle(.primary) }
            } else {
                Text(value.text).font(.reading())
            }
            // as the web app shows it: "(Marshal)", nothing for the main role
            if let role = value.role, role != "main" { Text("(\(Self.humanise(role)))").font(.caption).foregroundStyle(.secondary) }
            if let when = value.when { Text(when).font(.caption).foregroundStyle(.secondary) }
            VisibilityChip(visibility: value.visibility, compact: true)
        }
    }
}

/// An image from the server, sent with the reader's token and kept in the cache.
struct RemoteImage: View {
    let url: URL
    var contentMode: ContentMode = .fit
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: url) {
            guard let c = app.context else { return }
            let key = "media|" + url.absoluteString
            if let entry = await c.repository.cache.entry(for: key), let img = UIImage(data: entry.data) {
                image = img
                return
            }
            do {
                let data = try await c.repository.client.bytes(at: url)
                if let img = UIImage(data: data) {
                    image = img
                    await c.repository.cache.store(data, for: key, mark: nil)
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}

/// An image full screen with pinch to zoom (F-4.13).
struct ImageViewer: View {
    let media: EntityDetail.Media
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var base = 1.0
    @State private var offset = CGSize.zero
    @State private var dragBase = CGSize.zero

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let server = app.reader?.server, let url = media.address(base: server) {
                    RemoteImage(url: url)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(MagnifyGesture()
                            .onChanged { scale = max(1, min(8, base * $0.magnification)) }
                            .onEnded { _ in base = scale })
                        .simultaneousGesture(DragGesture()
                            .onChanged { offset = CGSize(width: dragBase.width + $0.translation.width,
                                                         height: dragBase.height + $0.translation.height) }
                            .onEnded { _ in dragBase = offset })
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = scale > 1 ? 1 : 2.5
                                base = scale
                                offset = .zero
                                dragBase = .zero
                            }
                        }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if let caption = media.caption ?? media.title {
                    Text(caption + (media.credit.map { " · \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding()
                }
            }
        }
    }
}
