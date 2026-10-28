import LoreGraphKit
import SwiftUI

/// The wiki home: continue reading, browse by type, trails and saved views (F-4.1 to F-4.3).
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { $0.loader(API.views()) }, load: { await $0.load() }) { views in
            List {
                if let about = app.about {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.world?.name ?? "").font(.reading(.largeTitle).weight(.semibold))
                            if let d = app.world?.description { Text(d).foregroundStyle(.secondary) }
                            HStack(spacing: 12) {
                                if let p = about.present?.text { Label(p, systemImage: "sun.max") }
                                if let n = about.counts?.totalPages, n > 0 { Label("\(n) pages", systemImage: "doc.on.doc") }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                if let error = app.worldError, app.about == nil {
                    Section { ErrorState(error: error) { await app.refresh() } }
                }
                if !app.recentPages.isEmpty {
                    Section("Continue reading") {
                        ForEach(app.recentPages.prefix(8), id: \.ref) { card in
                            NavigationLink(value: Route.page(card.ref)) { EntityRow(card: card) }
                        }
                    }
                }
                Section("Browse") {
                    NavigationLink(value: Route.browse(type: nil)) { Label("All pages", systemImage: "books.vertical") }
                    ForEach(EntityType.allCases, id: \.self) { t in
                        NavigationLink(value: Route.browse(type: t)) {
                            HStack {
                                Label(t.plural, systemImage: t.symbol)
                                Spacer()
                                if let n = app.about?.counts?.pages?[t.rawValue] { Text("\(n)").foregroundStyle(.secondary) }
                            }
                        }
                        .accessibilityIdentifier("browse-\(t.rawValue)")
                    }
                }
                if let v = views.value {
                    if let trails = v.trails, !trails.isEmpty {
                        Section("Trails") {
                            ForEach(trails) { t in
                                NavigationLink(value: Route.trail(t.slug)) {
                                    VStack(alignment: .leading) {
                                        Text(t.title)
                                        Text("\(t.steps.count) pages").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !v.views.isEmpty {
                        Section("Saved views") {
                            ForEach(v.views) { sv in
                                NavigationLink(value: Route.savedView(sv.slug)) {
                                    VStack(alignment: .leading) {
                                        HStack {
                                            Text(sv.title)
                                            VisibilityChip(visibility: sv.visibility, compact: true)
                                        }
                                        if let d = sv.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .refreshable {
                await app.refresh()
                await views.refresh()
            }
            .staleBanner(views)
            .navigationTitle("Wiki")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Pages by type, fifty at a time (F-4.2).
struct BrowseView: View {
    let type: EntityType?

    var body: some View {
        ContextModel(make: { BrowseModel(type: type, context: $0) }, load: { await $0.load() }) { model in
            List {
                Section {
                    Picker("Sort", selection: Binding(get: { model.sort }, set: { s in Task { await model.set(type: model.type, sort: s) } })) {
                        ForEach(BrowseModel.Sort.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Loaded(loader: model.first) { first in
                    Section(first.total.map { "\($0) pages" } ?? "") {
                        ForEach(model.items) { item in
                            NavigationLink(value: Route.page(item.ref)) {
                                EntityRow(card: item.card, detail: item.shortDescription ?? kindLabel(item.kind))
                            }
                        }
                        if model.canLoadMore {
                            Button {
                                Task { await model.loadMore() }
                            } label: {
                                HStack {
                                    Text("More")
                                    if model.isLoadingMore { Spacer(); ProgressView() }
                                }
                            }
                            .onAppear { Task { await model.loadMore() } }
                        }
                        if let e = model.moreError { Text(e.message).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .staleBanner(model.first)
            .navigationTitle(type?.plural ?? "All pages")
        }
    }
}

/// Every record of a page, record and claims apart (F-4.10).
struct RecordsView: View {
    let ref: String
    @State private var family: String?

    var body: some View {
        ContextModel(make: { $0.loader(API.statements(entity: ref)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { list in
                    let families = Array(Set(list.items.compactMap(\.label))).sorted()
                    if families.count > 1 {
                        Picker("Link type", selection: $family) {
                            Text("All").tag(String?.none)
                            ForEach(families, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                    let shown = list.items.filter { family == nil || $0.label == family }
                    Section("The record") {
                        ForEach(shown.filter { !$0.isClaim }) { s in StatementRow(statement: s) }
                    }
                    let claims = shown.filter(\.isClaim)
                    if !claims.isEmpty {
                        Section {
                            ForEach(claims) { s in StatementRow(statement: s) }
                        } header: {
                            Text("Claims")
                        } footer: {
                            Text("What stories and tales say. Claims can contradict the record.")
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("Records")
        }
    }
}

struct StatementRow: View {
    let statement: Statement

    var body: some View {
        NavigationLink(value: Route.record(statement.id)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(statement.shownSentence).font(.reading())
                HStack(spacing: 8) {
                    if let v = statement.valid, !v.text.isEmpty { Label(v.text, systemImage: "calendar") }
                    if let p = statement.place { Label(p.shownTitle, systemImage: "mappin") }
                    if let a = statement.accordingTo {
                        Label("according to \(a.shownTitle)", systemImage: "text.quote").foregroundStyle(Color.claim)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    VisibilityChip(visibility: statement.visibility, compact: true)
                    CanonChip(canon: statement.canon)
                    if let c = statement.certainty, c != "certain" { Chip(text: c) }
                }
            }
        }
        .visibilityEdge(statement.visibility)
    }
}

/// One record: its parts, the record behind a claim, other claims, and who knows it (F-4.10).
struct RecordView: View {
    let id: String
    @State private var whoKnows: Loader<WhoKnows>?
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { $0.loader(API.statement(id)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { d in
                    let s = d.statement
                    Section {
                        Text(s.shownSentence).font(.reading(.title3))
                        HStack(spacing: 6) {
                            VisibilityChip(visibility: s.visibility)
                            CanonChip(canon: s.canon)
                        }
                    }
                    Section("Details") {
                        if let subject = s.subject { pageRow("Subject", subject) }
                        LabeledContent("Link", value: s.label ?? s.predicate)
                        if let object = s.object { pageRow("Object", object) }
                        if let value = s.value { LabeledContent("Value", value: value.text) }
                        if let role = s.role { LabeledContent("Role", value: role) }
                        if let side = s.side { pageRow("Side", side) }
                        if let v = s.valid, !v.text.isEmpty { LabeledContent("When", value: v.text) }
                        if let p = s.place { pageRow("Where", p) }
                        if let c = s.certainty { LabeledContent("Certainty", value: c) }
                        if let a = s.accordingTo {
                            pageRow("According to", a)
                            LabeledContent("Says it", value: AccountsCompared.relationWord(s.claimRelation))
                        }
                        if let q = s.sourceQuote { Text("“\(q)”").font(.reading()).italic() }
                        if let n = s.note { Text(n).font(.footnote).foregroundStyle(.secondary) }
                    }
                    if let record = d.record {
                        Section("The record says") { StatementRow(statement: record) }
                    }
                    if let claims = d.claims, !claims.isEmpty {
                        Section("Accounts say") { ForEach(claims) { StatementRow(statement: $0) } }
                    }
                    if let omitted = d.omittedBy, !omitted.isEmpty {
                        Section("Left out by") {
                            ForEach(omitted, id: \.account.ref) { o in
                                VStack(alignment: .leading) {
                                    Text(o.account.title)
                                    if let n = o.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    Section("Who knows it") {
                        if let w = whoKnows?.value {
                            if w.holders.isEmpty { Text("Nobody is recorded as knowing this.").foregroundStyle(.secondary) }
                            ForEach(Array(w.holders.enumerated()), id: \.offset) { _, h in
                                NavigationLink(value: Route.beliefs(h.holder.ref)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(h.holder.shownTitle)
                                        Text([h.stance, h.how, h.since?.text].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                }
            }
            .refreshable {
                await loader.refresh()
                await whoKnows?.refresh()
            }
            .staleBanner(loader)
            .navigationTitle("Record")
            .task {
                guard whoKnows == nil, let c = app.context else { return }
                let w = c.loader(API.whoKnows(id))
                whoKnows = w
                await w.load()
            }
        }
    }

    func pageRow(_ label: String, _ card: EntityCard) -> some View {
        NavigationLink(value: Route.page(card.ref)) { LabeledContent(label, value: card.shownTitle) }
    }
}

/// What links here (F-4.11).
struct LinksView: View {
    let ref: String

    var body: some View {
        ContextModel(make: { $0.loader(API.backlinks(ref)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { b in
                    if b.prose.isEmpty && b.statements.isEmpty {
                        Text("Nothing links here yet.").foregroundStyle(.secondary)
                    }
                    if !b.prose.isEmpty {
                        Section("Mentioned in") {
                            ForEach(Array(b.prose.enumerated()), id: \.offset) { _, p in
                                NavigationLink(value: Route.page(p.page.ref)) {
                                    EntityRow(card: p.page, detail: p.heading.map { "In \($0)" })
                                }
                            }
                        }
                    }
                    if !b.statements.isEmpty {
                        Section("Linked by records") {
                            ForEach(Array(b.statements.enumerated()), id: \.offset) { _, s in
                                NavigationLink(value: Route.page(s.page.ref)) {
                                    EntityRow(card: s.page, detail: s.label + (s.claim == true ? " (a claim)" : ""))
                                }
                            }
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("What links here")
        }
    }
}

/// Accounts compared, row by row against the record (F-5.1).
struct AccountsView: View {
    let ref: String

    var body: some View {
        ContextModel(make: { $0.loader(API.compare(ref)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { cmp in
                    Section {
                        ForEach(cmp.accounts, id: \.account.ref) { col in
                            NavigationLink(value: Route.page(col.account.ref)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(col.account.shownTitle).font(.headline)
                                    if let t = col.telling {
                                        Text([t.tellerLabel ?? t.teller?.shownTitle, t.medium, t.toldInTellerCalendar ?? t.told?.text, t.bias]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if let r = t.reliability { Text("Reliability \(r) of 5").font(.caption2).foregroundStyle(Color.designer) }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Accounts")
                    }
                    ForEach(cmp.record) { record in
                        Section {
                            ForEach(cmp.accounts, id: \.account.ref) { col in
                                let cell = cmp.cell(account: col.account.ref, record: record.id)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(col.account.shownTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    if cell?.leftOut == true {
                                        Label("Leaves it out" + (cell?.omissionNote.map { ": \($0)" } ?? ""), systemImage: "minus.circle")
                                            .foregroundStyle(.secondary)
                                    } else if let claims = cell?.claims, !claims.isEmpty {
                                        ForEach(claims) { c in
                                            VStack(alignment: .leading, spacing: 2) {
                                                Chip(text: AccountsCompared.relationWord(c.claimRelation),
                                                     tint: c.claimRelation == "agrees" ? .green : .claim)
                                                Text(c.shownSentence).font(.reading(.callout))
                                            }
                                        }
                                    } else {
                                        Text("Agrees, or says nothing").font(.callout).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } header: {
                            Text(record.shownSentence).textCase(nil).font(.reading(.subheadline).weight(.semibold))
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("Accounts differ")
        }
    }
}

/// What someone believes, by question (F-5.2).
struct BeliefsView: View {
    let ref: String

    var body: some View {
        ContextModel(make: { $0.loader(API.beliefs(of: ref)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { b in
                    if let c = b.counts {
                        Section {
                            HStack(spacing: 14) {
                                if let n = c.own { Label("\(n) own", systemImage: "person") }
                                if let n = c.inherited, n > 0 { Label("\(n) inherited", systemImage: "person.3") }
                                if let n = c.overridden, n > 0 { Label("\(n) overridden", systemImage: "arrow.uturn.left") }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if b.beliefs.isEmpty { Text("No beliefs recorded.").foregroundStyle(.secondary) }
                    ForEach(b.byQuestion, id: \.key) { group in
                        Section {
                            ForEach(group.beliefs) { belief in BeliefRow(belief: belief) }
                        } header: {
                            NavigationLink(value: Route.beliefQuestion(group.key)) {
                                Text(group.beliefs.first?.proposition ?? group.key).textCase(nil)
                            }
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("Beliefs")
        }
    }
}

struct BeliefRow: View {
    let belief: Belief

    var body: some View {
        NavigationLink(value: Route.beliefTrace(belief.id)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Chip(text: belief.stance, tint: .accentInk)
                    if let o = belief.openness { Chip(text: o) }
                    if belief.inherited == true { Chip(text: "via \(belief.via ?? "a group")") }
                    if belief.isOverridden { Chip(text: "overridden", tint: .orange) }
                    VisibilityChip(visibility: belief.visibility, compact: true)
                }
                Text(belief.sentence ?? belief.proposition).font(.reading())
                    .strikethrough(belief.isOverridden)
                HStack(spacing: 8) {
                    if let h = belief.held, !h.text.isEmpty { Text("since \(h.text)") }
                    if let a = belief.acquisition { Text(a) }
                    if let from = belief.acquiredFrom { Text("from \(from.shownTitle)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let truth = belief.truth {
                    Label("Truth: \(truth)" + (belief.truthNote.map { ". \($0)" } ?? ""), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(Color.designer)
                }
            }
        }
        .visibilityEdge(belief.visibility)
    }
}

/// Who believes what about one question (F-5.4).
struct BeliefHoldersView: View {
    let key: String

    var body: some View {
        ContextModel(make: { $0.loader(API.holders(question: key)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { h in
                    if let byStance = h.byStance, !byStance.isEmpty {
                        Section {
                            Text(byStance.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section(h.beliefs.first?.proposition ?? key) {
                        ForEach(Array(h.holders.enumerated()), id: \.offset) { _, holder in
                            NavigationLink(value: Route.beliefs(holder.holder.ref)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(holder.holder.shownTitle)
                                        if let s = holder.stance { Chip(text: s, tint: .accentInk) }
                                        if holder.own == false { Chip(text: "inherited") }
                                        VisibilityChip(visibility: holder.visibility, compact: true)
                                    }
                                    if let held = holder.held, !held.text.isEmpty {
                                        Text("since \(held.text)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("Who believes it")
        }
    }
}

/// Where a belief came from, as sentences (F-5.3).
struct BeliefTraceView: View {
    let id: String

    var body: some View {
        ContextModel(make: { $0.loader(API.lineage(id)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { l in
                    Section { BeliefRow(belief: l.belief) }
                    Section("How it came about") {
                        ForEach(Array(l.chain.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(step.text ?? step.step).font(.reading())
                                    if let a = step.account {
                                        NavigationLink(value: Route.page(a.ref)) { Text(a.shownTitle).font(.caption) }
                                    }
                                    if let r = step.reliability { Text("Reliability \(r) of 5").font(.caption2).foregroundStyle(Color.designer) }
                                }
                            }
                        }
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .staleBanner(loader)
            .navigationTitle("Where it came from")
        }
    }
}

/// A faction's parts as a tree, and its members (F-4.12).
struct FactionView: View {
    let ref: String
    @Environment(AppModel.self) private var app
    @State private var members: Loader<Memberships>?

    var body: some View {
        ContextModel(make: { $0.loader(API.factionTree(ref)) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { tree in
                    Section {
                        NavigationLink(value: Route.page(tree.faction.ref)) {
                            VStack(alignment: .leading) {
                                Text(tree.faction.title).font(.headline)
                                HStack {
                                    if let n = tree.faction.members { Text("\(n) members") }
                                    if let seat = tree.faction.seat { Text("Seat: \(seat.shownTitle)") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let parents = tree.parents, !parents.isEmpty {
                            ForEach(parents, id: \.ref) { p in
                                NavigationLink(value: Route.faction(p.ref)) { Label("Part of \(p.shownTitle)", systemImage: "arrow.up") }
                            }
                        }
                    }
                    if !tree.parts.isEmpty {
                        Section("Parts") {
                            OutlineGroup(tree.parts, id: \.ref, children: \.childParts) { part in
                                NavigationLink(value: Route.faction(part.ref)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(part.title)
                                            VisibilityChip(visibility: part.visibility, compact: true)
                                        }
                                        Text([kindLabel(part.kind), part.how, part.members.map { "\($0) members" }].compactMap { $0 }
                                            .joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if let m = members?.value, !m.items.isEmpty {
                    Section("Members") {
                        ForEach(m.items, id: \.statementId) { item in
                            NavigationLink(value: Route.page(item.member.ref)) {
                                EntityRow(card: item.member, detail: [item.role, item.valid?.text].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                    }
                }
            }
            .refreshable {
                await loader.refresh()
                await members?.refresh()
            }
            .staleBanner(loader)
            .navigationTitle("Faction")
            .task {
                guard members == nil, let c = app.context else { return }
                let m = c.loader(API.memberships(group: ref))
                members = m
                await m.load()
            }
        }
    }
}

extension FactionTree.Part {
    /// Children for the outline, nil when a part has none (so no disclosure arrow shows).
    var childParts: [FactionTree.Part]? {
        guard let parts, !parts.isEmpty else { return nil }
        return parts
    }
}

/// A trail: its steps with previous and next (F-4.3).
struct TrailView: View {
    let slug: String

    var body: some View {
        ContextModel(make: { $0.loader(API.views()) }, load: { await $0.load() }) { loader in
            List {
                Loaded(loader: loader) { v in
                    if let trail = v.trails?.first(where: { $0.slug == slug }) {
                        if let d = trail.descriptionMd { Section { Text(d).font(.reading()) } }
                        Section("Steps") {
                            ForEach(Array(trail.steps.enumerated()), id: \.offset) { i, step in
                                NavigationLink(value: Route.page(step.ref)) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        VStack(alignment: .leading) {
                                            Text(step.title)
                                            if let n = step.noteMd { Text(n).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        ErrorState(error: .notFound(Problem(detail: "There's no trail called \(slug), or you can't see it.")))
                    }
                }
            }
            .refreshable { await loader.refresh() }
            .navigationTitle(loader.value?.trails?.first { $0.slug == slug }?.title ?? "Trail")
        }
    }
}

/// A saved view opens the screen it saved (F-4.1).
struct SavedViewView: View {
    let slug: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { $0.loader(API.views()) }, load: { await $0.load() }) { loader in
            Loaded(loader: loader) { v in
                if let sv = v.views.first(where: { $0.slug == slug }), let path = sv.url,
                   let url = URL(string: path, relativeTo: app.reader?.server),
                   let link = WebLink.parse(url.absoluteURL, server: app.reader?.server) {
                    RouteView(route: link.route)
                } else {
                    ErrorState(error: .notFound(Problem(detail: "There's no saved view called \(slug), or you can't see it.")))
                }
            }
        }
    }
}
