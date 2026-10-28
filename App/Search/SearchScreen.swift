import LoreGraphKit
import SwiftUI

/// Search: suggestions as you type, then results with facets and highlighted passages
/// (F-10.1, F-10.2).
struct SearchScreen: View {
    var initial = ""
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { SearchModel(context: $0, text: initial) }, load: { m in
            if !m.text.isEmpty { await m.submit() }
        }) { model in
            SearchContent(model: model)
        }
    }
}

struct SearchContent: View {
    @Bindable var model: SearchModel
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            if let results = model.results {
                Loaded(loader: results) { r in
                    if let facets = r.facets?.type, facets.count > 1 {
                        Section {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(facets.sorted { $0.key < $1.key }, id: \.key) { key, count in
                                        let type = EntityType(rawValue: key) ?? .misc
                                        Button {
                                            if model.types.contains(type) { model.types.remove(type) } else { model.types.insert(type) }
                                            Task { await model.submit() }
                                        } label: {
                                            Text("\(type.plural) \(count)")
                                                .font(.subheadline)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(model.types.contains(type) ? Color.accentInk.opacity(0.2) : Color.secondary.opacity(0.1),
                                                            in: Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    if r.results.isEmpty {
                        ContentUnavailableView.search(text: model.submitted ?? "")
                    }
                    ForEach(r.results) { result in
                        NavigationLink(value: Route.page(result.entity.ref)) {
                            ResultRow(result: result)
                        }
                    }
                    if let warnings = r.warnings, !warnings.isEmpty {
                        Text(warnings.joined(separator: " ")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else if !model.suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(model.suggestions) { c in
                        NavigationLink(value: Route.page(c.ref)) {
                            EntityRow(card: c.card, detail: c.matched.map { "Matched “\($0)”" } ?? c.shortDescription)
                        }
                    }
                }
            } else if !app.recentSearches.isEmpty {
                Section("Recent searches") {
                    ForEach(app.recentSearches, id: \.self) { q in
                        Button(q) {
                            model.text = q
                            Task { await model.submit() }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Search the wiki", systemImage: "magnifyingglass",
                                       description: Text("Names, old spellings, and what pages say."))
            }
        }
        .searchable(text: $model.text, prompt: "Pages, names and passages")
        .onSubmit(of: .search) {
            app.searched(model.text)
            Task { await model.submit() }
        }
        .onChange(of: model.text) { _, t in
            if t.isEmpty { model.clear() }
        }
        .task(id: model.text) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, model.submitted != model.text else { return }
            await model.suggest()
        }
        .refreshable { await model.refresh() }
        .navigationTitle("Search")
    }
}

struct ResultRow: View {
    let result: SearchResults.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EntityRow(card: result.entity, detail: result.matchedName.map { "Also called \($0.name)" } ?? result.entity.shortDescription)
            ForEach(Array((result.passages ?? []).prefix(2).enumerated()), id: \.offset) { _, p in
                VStack(alignment: .leading, spacing: 2) {
                    if let h = p.headingPath { Text(h).font(.caption2).foregroundStyle(.secondary) }
                    snippet(p.snippetParts, fallback: p.snippet)
                        .font(.reading(.footnote))
                        .lineLimit(3)
                }
                .padding(.leading, 34)
            }
            if (result.passages ?? []).isEmpty, result.snippetParts != nil || result.snippet != nil {
                snippet(result.snippetParts, fallback: result.snippet)
                    .font(.reading(.footnote))
                    .lineLimit(3)
                    .padding(.leading, 34)
            }
        }
    }

    /// A snippet with the matched words in bold (never colour alone).
    func snippet(_ parts: [SnippetPart]?, fallback: String?) -> Text {
        guard let parts, !parts.isEmpty else { return Text(fallback ?? "") }
        var a = AttributedString()
        for part in parts {
            var s = AttributedString(part.text)
            if part.hit {
                s.inlinePresentationIntent = .stronglyEmphasized
                s.backgroundColor = Color.yellow.opacity(0.3)
            }
            a += s
        }
        return Text(a)
    }
}
