import LoreGraphKit
import SwiftUI

/// Server HTML drawn natively in the reading serif (F-4.4): paragraphs, headings, lists,
/// quotes, code, tables. Links to pages open in the app; long-press a paragraph for its links'
/// previews (F-4.6).
struct ProseView: View {
    let blocks: [Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }
}

struct BlockView: View {
    let block: Block

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            paragraph(inlines)
        case .heading(let level, let inlines):
            Text(attributed(Prose.runs(inlines)))
                .font(level <= 2 ? .reading(.title3).weight(.semibold) : .reading(.headline))
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(start + i)." : "•").font(.reading()).foregroundStyle(.secondary)
                        ProseView(blocks: item)
                    }
                }
            }
        case .quote(let inner):
            ProseView(blocks: inner)
                .italic()
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 3) }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).font(.system(.footnote, design: .monospaced)).padding(10)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        case .table(let header, let rows, let alignments):
            TableBlock(header: header, rows: rows, alignments: alignments)
        }
    }

    @ViewBuilder func paragraph(_ inlines: [Inline]) -> some View {
        let runs = Prose.runs(inlines)
        let pages = Array(Set(runs.compactMap { run -> String? in
            guard let url = run.link, url.scheme == OAuthClient.callbackScheme, url.host == "wiki" else { return nil }
            return url.lastPathComponent
        })).sorted()
        let text = Text(attributed(runs)).font(.reading()).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        if pages.isEmpty {
            text
        } else {
            text.contextMenu {
                ForEach(pages, id: \.self) { slug in
                    PageLinkMenu(ref: slug, title: runs.first { $0.link?.lastPathComponent == slug }?.text ?? slug)
                }
            } preview: {
                LinkPreviewCard(ref: pages[0])
            }
        }
    }
}

/// Open page, Show on map, Open in graph and Copy web link for one linked page (F-4.6).
struct PageLinkMenu: View {
    let ref: String
    let title: String
    @Environment(Navigator.self) private var navigator
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu(title) {
            Button("Open page", systemImage: "doc.text") { navigator.open(.page(ref)) }
            Button("Show on map", systemImage: "map") { navigator.open(.map(MapOptions(select: ref))) }
            Button("Open in graph", systemImage: "circle.hexagongrid") { navigator.open(.graph(GraphOptions(focus: [ref]))) }
            if let c = app.context {
                Button("Copy web link", systemImage: "link") { UIPasteboard.general.url = c.shareURL(.page(ref)) }
            }
        }
    }
}

/// A short preview of a page: title, chips, description and the start of its text.
struct LinkPreviewCard: View {
    let ref: String
    @Environment(AppModel.self) private var app
    @State private var loader: Loader<EntityDetail>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = loader?.value {
                HStack(spacing: 6) {
                    Image(systemName: d.entity.type.symbol).foregroundStyle(Color.accentInk)
                    Text(kindLabel(d.entity.kind) ?? d.entity.type.label).font(.caption).foregroundStyle(.secondary)
                    VisibilityChip(visibility: d.entity.visibility, compact: true)
                }
                Text(d.entity.displayTitle ?? d.entity.title).font(.reading(.title2).weight(.semibold))
                if let s = d.entity.shortDescription { Text(s).font(.subheadline).foregroundStyle(.secondary) }
                if let lead = d.shownSections.first(where: { ($0.html ?? "").isEmpty == false }) {
                    Text(HTMLContent.parse(lead.html ?? "").first?.plainText ?? "")
                        .font(.reading(.callout))
                        .lineLimit(6)
                }
            } else if let e = loader?.error {
                Text(e.title).font(.headline)
                Text(e.message).font(.subheadline)
            } else {
                ProgressView()
            }
        }
        .padding(18)
        .frame(width: 320, alignment: .leading)
        .task {
            guard loader == nil, let c = app.context else { return }
            let l = c.loader(API.preview(ref))
            loader = l
            await l.load()
        }
    }
}

struct TableBlock: View {
    let header: [[Inline]]
    let rows: [[[Inline]]]
    let alignments: [ColumnAlignment]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                if !header.isEmpty {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { i, cell in
                            Text(attributed(Prose.runs(cell))).font(.subheadline.weight(.semibold))
                                .gridColumnAlignment(alignment(i))
                        }
                    }
                    Divider()
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(attributed(Prose.runs(cell))).font(.reading(.subheadline))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    func alignment(_ i: Int) -> HorizontalAlignment {
        switch i < alignments.count ? alignments[i] : .leading {
        case .leading: .leading
        case .centre: .center
        case .trailing: .trailing
        }
    }
}

/// Prose runs as an attributed string SwiftUI's Text draws: italic, bold, code, links.
func attributed(_ runs: [ProseRun]) -> AttributedString {
    var out = AttributedString()
    for r in runs {
        var a = AttributedString(r.text)
        var intent: InlinePresentationIntent = []
        if r.style.contains(.emphasis) { intent.insert(.emphasized) }
        if r.style.contains(.strong) { intent.insert(.stronglyEmphasized) }
        if r.style.contains(.code) { intent.insert(.code) }
        if r.style.contains(.strike) { intent.insert(.strikethrough) }
        if !intent.isEmpty { a.inlinePresentationIntent = intent }
        if let link = r.link {
            a.link = link
            a.foregroundColor = .accentInk
        }
        out += a
    }
    return out
}
