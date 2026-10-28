import LoreGraphKit
import SwiftUI

/// A wiki page (F-4.4 to F-4.9).
struct PageView: View {
    let ref: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { PageModel(ref: ref, context: $0) }, load: { m in
            await m.load()
            if let card = m.card { app.visited(card) }
        }) { model in
            PageContent(model: model)
        }
    }
}

struct PageContent: View {
    let model: PageModel
    @Environment(Navigator.self) private var navigator

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Loaded(loader: model.page) { page in
                    VStack(alignment: .leading, spacing: 18) {
                        PageHeader(page: page)
                        ActionBar(actions: model.actions, ref: model.ref)
                        if let box = page.infobox, !box.isEmpty || page.infoboxImage != nil || page.locatorPoint != nil {
                            InfoboxView(page: page)
                        }
                        if page.shownSections.count > 3 {
                            Menu {
                                ForEach(page.shownSections) { s in
                                    Button(s.heading ?? s.key) { withAnimation { proxy.scrollTo(s.id, anchor: .top) } }
                                }
                            } label: {
                                Label("Contents", systemImage: "list.bullet").font(.subheadline.weight(.medium))
                            }
                        }
                        ForEach(page.shownSections) { s in
                            SectionView(section: s, blocks: model.blocks(s)).id(s.id)
                        }
                        if let cats = page.categories, !cats.isEmpty {
                            CategoryChips(categories: cats)
                        }
                    }
                    .padding()
                }
            }
            .refreshable { await model.refresh() }
        }
        .staleBanner(model.page)
        .navigationTitle(model.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.shareURL) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share web link")
            }
        }
    }
}

struct PageHeader: View {
    let page: EntityDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let crumbs = page.entity.breadcrumbs, !crumbs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(crumbs, id: \.ref) { c in
                            NavigationLink(value: Route.page(c.ref)) { Text(c.title) }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                }
            }
            Text(page.entity.displayTitle ?? page.entity.title)
                .font(.reading(.largeTitle).weight(.semibold))
                .accessibilityIdentifier("pageTitle")
            if let vp = page.viewpoint, page.entity.displayTitle != nil, page.entity.displayTitle != page.entity.title {
                Text("\(page.entity.title) on the record; this is what \(vp.title) calls it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Chip(text: page.entity.kindLabel ?? kindLabel(page.entity.kind) ?? page.entity.type.label, tint: .accentInk)
                CanonChip(canon: page.entity.canon)
                VisibilityChip(visibility: page.entity.visibility)
            }
            if let s = page.entity.shortDescription {
                Text(s).font(.reading(.title3)).foregroundStyle(.secondary)
            }
            if let life = page.entity.lifespan, !life.text.isEmpty {
                Label(life.text, systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
            }
            if !page.alsoKnownAs.isEmpty {
                Text("Also known as " + page.alsoKnownAs.map(\.name).joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let asOf = page.asOf, !asOf.text.isEmpty {
                Label("As of \(asOf.text)", systemImage: "clock").font(.caption).foregroundStyle(Color.accentInk)
            }
        }
    }
}

/// The view switcher (F-4.9).
struct ActionBar: View {
    let actions: [PageAction]
    let ref: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions) { a in
                    NavigationLink(value: a.route(ref)) {
                        Label(a.label, systemImage: a.symbol)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.accentInk.opacity(0.1), in: Capsule())
                    }
                    .accessibilityIdentifier("action-\(a.rawValue)")
                }
            }
        }
    }
}

/// One section: heading, marks, generated rows and text (F-4.7, F-4.8).
struct SectionView: View {
    let section: EntityDetail.Section
    let blocks: [Block]
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let h = section.heading, !h.isEmpty, section.key != "lead" {
                HStack(spacing: 8) {
                    Text(h).font(.reading(.title2).weight(.semibold)).accessibilityAddTraits(.isHeader)
                    VisibilityChip(visibility: section.visibility, compact: true)
                    if section.authorCanon == true { Chip(text: "Author canon") }
                }
            } else if section.visibility != .public {
                VisibilityChip(visibility: section.visibility)
            }
            if let items = section.items, !items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        ItemRow(item: item)
                    }
                }
            }
            if !blocks.isEmpty { ProseView(blocks: blocks) }
            if let link = section.link, let url = URL(string: link, relativeTo: app.reader?.server),
               let web = WebLink.parse(url.absoluteURL, server: app.reader?.server) {
                Button {
                    navigator.open(web.route)
                } label: {
                    Label("See all", systemImage: "arrow.right").font(.subheadline.weight(.medium))
                }
            }
        }
        .visibilityEdge(section.visibility)
    }
}

struct ItemRow: View {
    let item: EntityDetail.Section.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let label = item.label { Text(label).font(.subheadline).foregroundStyle(.secondary) }
            if let other = item.other {
                NavigationLink(value: Route.page(other.ref)) {
                    Text(other.shownTitle).font(.reading())
                }
            }
            if let v = item.valid, !v.text.isEmpty { Text(v.text).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            VisibilityChip(visibility: item.visibility, compact: true)
            if let id = item.statementId {
                NavigationLink(value: Route.record(id)) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Open the record")
            }
        }
        .visibilityEdge(item.visibility)
    }
}

/// A page's categories as chips that wrap onto new lines; each opens the pages in it.
struct CategoryChips: View {
    let categories: [EntityDetail.Category]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(categories, id: \.self) { c in
                if let slug = c.slug {
                    NavigationLink(value: Route.category(slug, title: c.title)) { Chip(text: c.title, tint: .accentColor) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("category-\(slug)")
                } else {
                    Chip(text: c.title)
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: Double = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x = 0.0, y = 0.0, row = 0.0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row = 0.0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
