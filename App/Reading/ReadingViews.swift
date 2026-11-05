import LoreGraphKit
import SwiftUI

/// The reader's reading list (ADR D-83): the whole wiki in reading order, in parts, with what is
/// read, what changed since, and the page to read next.
struct ReadingListView: View {
    let list: String?

    var body: some View {
        ContextModel(make: { ReadingModel(list: list, context: $0) }, load: { await $0.load() }) { model in
            ReadingListContent(model: model)
        }
    }
}

struct ReadingListContent: View {
    let model: ReadingModel
    @State private var naming: Naming?
    @State private var confirmDelete = false
    @State private var appeared = false

    enum Naming: Identifiable { case build, rename; var id: Self { self } }

    var body: some View {
        List {
            if let e = model.actionError {
                Section { ActionErrorRow(error: e) { model.actionError = nil } }
            }
            Loaded(loader: model.loader) { _ in
                if model.isEmpty {
                    ContentUnavailableView {
                        Label("No reading list yet", systemImage: "list.number")
                    } description: {
                        Text("A reading list puts every page of this world in an order you can read from the start: places from the largest region down, peoples and powers, history from the earliest event, people, stories and tales, and pages without prose last. It keeps your place, notes pages edited since you read them, and counts new pages.")
                    } actions: {
                        Button("Build a reading list") { Task { await model.build() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("buildReadingList")
                    }
                    .listRowBackground(Color.clear)
                } else if let info = model.info {
                    summary(info)
                    Section {
                        Picker("Show", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                            ForEach(ReadingModel.Filter.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    if model.shownParts.isEmpty {
                        Text(model.filter == .changed ? "No page has changed since you read it." : "Every page is read.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.shownParts) { part in
                        Section {
                            ForEach(model.items(in: part)) { item in
                                NavigationLink(value: Route.reading(list: info.id, page: item.page.ref)) { ReadingRow(item: item) }
                                    .swipeActions(edge: .leading) {
                                        if item.isDone {
                                            Button("Unread", systemImage: "circle") { Task { await model.mark([item.page.ref], read: false) } }
                                        } else {
                                            Button("Read", systemImage: "checkmark") { Task { await model.mark([item.page.ref]) } }
                                                .tint(.green)
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(part.title)
                                Spacer()
                                Text("\(part.read) of \(part.pages)").monospacedDigit()
                            }
                        } footer: {
                            if let note = part.note { Text(note) }
                        }
                    }
                    if model.canLoadMore {
                        Button("More pages") { Task { await model.loadMore() } }
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
        .staleBanner(model.loader)
        .navigationTitle(model.info?.title ?? "Reading list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let lists = model.list?.lists, lists.count > 1 {
                        Picker("Reading lists", selection: Binding(get: { model.info?.id }, set: { id in Task { await model.open(id) } })) {
                            ForEach(lists) { l in
                                Text("\(l.title) (\(l.read ?? 0) of \(l.pages ?? 0))").tag(Optional(l.id))
                            }
                        }
                    }
                    Button("New reading list…", systemImage: "plus") { naming = .build }
                    if model.info != nil {
                        Button("Rename…", systemImage: "pencil") { naming = .rename }
                        if let url = model.info?.uiUrl.flatMap(URL.init(string:)) {
                            ShareLink(item: url) { Label("Share web link", systemImage: "square.and.arrow.up") }
                        }
                        Button("Delete list…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Reading list options")
                .disabled(model.isWorking)
            }
        }
        .sheet(item: $naming) { n in
            NameSheet(title: n == .build ? "New reading list" : "Rename list",
                      prompt: n == .build ? "Leave empty for “Lore audit” and today's date." : nil,
                      initial: n == .rename ? (model.info?.title ?? "") : "", allowEmpty: n == .build) { text in
                if n == .build { await model.build(title: text) } else { await model.rename(text) }
                return model.actionError == nil
            }
        }
        .confirmationDialog("Delete “\(model.info?.title ?? "this list")” and its read marks?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.delete() } }
        } message: {
            Text("The pages themselves are not touched.")
        }
        .onAppear {
            // come back from reading pages: show their marks
            if appeared { Task { await model.load() } }
            appeared = true
        }
    }

    @ViewBuilder func summary(_ info: ReadingList.Info) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let p = model.progress {
                    ProgressView(value: Double(p.read), total: Double(max(p.pages, 1)))
                        .tint(.green)
                        .accessibilityLabel("\(p.read) of \(p.pages) pages read")
                    Text("\(p.read) of \(p.pages) pages read (\(p.percent)%) · \(ReadingModel.timeLeft(p.minutesLeft)) left")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if let d = model.builtAt {
                    Text("Built \(d.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            if let next = model.upNext {
                NavigationLink(value: Route.reading(list: info.id, page: next.page.ref)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue: \(next.page.shownTitle)").font(.body.weight(.semibold))
                            Text("\(next.n). \(model.parts.first { $0.key == next.part }?.title ?? next.part) · about \(next.minutes ?? 1) min")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "book.fill").foregroundStyle(Color.accentInk)
                    }
                }
                .accessibilityIdentifier("continueReading")
            } else if model.progress != nil {
                Label("Every page is read.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            if let changed = model.progress?.changed, changed > 0 {
                Button {
                    model.filter = .changed
                } label: {
                    Label(changed == 1 ? "1 page changed since you read it" : "\(changed) pages changed since you read them",
                          systemImage: "exclamationmark.arrow.circlepath")
                }
                .foregroundStyle(.orange)
            }
            if let n = model.list?.newPages, n > 0 {
                HStack {
                    Label(n == 1 ? "1 new page isn't in the list" : "\(n) new pages aren't in the list", systemImage: "plus.square.on.square")
                    Spacer()
                    Button("Add to the end") { Task { await model.addNewPages() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking)
                }
            }
        }
    }
}

/// One page of the list: its number, title, words and whether it is read.
struct ReadingRow: View {
    let item: ReadingList.Item

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.changed {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                } else if item.isRead {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.page.shownTitle)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                    VisibilityChip(visibility: item.page.visibility, compact: true)
                    CanonChip(canon: item.page.canon)
                }
                Text(item.changed ? "Changed since you read it" : (item.words > 0 ? "\(item.words) words" : "No prose yet"))
                    .font(.caption)
                    .foregroundStyle(item.changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            Spacer(minLength: 0)
            Text("\(item.n)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.changed ? "changed since read" : (item.isRead ? "read" : "unread"))
    }
}

/// Asks for a name (a new list's title, or a list's new one).
struct NameSheet: View {
    let title: String
    var prompt: String?
    @State var initial: String
    var allowEmpty = false
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $initial)
                } footer: {
                    if let prompt { Text(prompt) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(allowEmpty ? "Build" : "Save") {
                        saving = true
                        Task {
                            if await save(initial) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(saving || (!allowEmpty && initial.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// A page read from the reading list: the page with its comments, what changed since it was
/// read, and Previous, Next and "Mark read and continue" below.
@Observable
@MainActor
final class ReadingPageModel {
    let reading: ReadingModel
    private(set) var page: PageModel
    private(set) var changes: Loader<EntityDetail>?
    private(set) var ref: String
    let context: ReadContext

    init(list: String?, ref: String, context: ReadContext) {
        reading = ReadingModel(list: list, context: context)
        page = PageModel(ref: ref, context: context)
        self.ref = ref
        self.context = context
    }

    var item: ReadingList.Item? { reading.item(ref) }

    func load() async {
        async let list: Void = reading.load()
        await page.load()
        await list
        await loadChanges()
    }

    func loadChanges() async {
        changes = item.flatMap(reading.changes)
        await changes?.load()
    }

    /// Moves to another page of the list in place.
    func go(to next: String) async {
        guard next != ref else { return }
        ref = next
        page = PageModel(ref: next, context: context)
        changes = nil
        await page.load()
        await loadChanges()
    }
}

struct ReadingPageView: View {
    let list: String?
    let ref: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContextModel(make: { ReadingPageModel(list: list, ref: ref, context: $0) }, load: { m in
            await m.load()
            if let card = m.page.card { app.visited(card) }
        }) { model in
            ReadingPageContent(model: model)
        }
    }
}

struct ReadingPageContent: View {
    let model: ReadingPageModel
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var reading: ReadingModel { model.reading }

    var body: some View {
        PageContent(model: model.page) {
            if let e = reading.actionError {
                ActionErrorRow(error: e) { reading.actionError = nil }
            }
            if let item = model.item, item.changed {
                ChangedSinceRead(item: item, changes: model.changes)
            }
        }
        .id(model.ref)
        .safeAreaInset(edge: .bottom) { bar }
    }

    var bar: some View {
        let item = model.item
        let previous = reading.neighbour(of: model.ref, by: -1)
        let following = reading.neighbour(of: model.ref, by: 1)
        return HStack(spacing: 12) {
            Button {
                if let p = previous { Task { await model.go(to: p.page.ref) } }
            } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }
            .disabled(previous == nil)
            .accessibilityLabel("Previous page")
            VStack(alignment: .leading, spacing: 1) {
                if let item, let p = reading.progress {
                    Text("\(item.n) of \(p.pages)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    Text(reading.parts.first { $0.key == item.part }?.title ?? item.part)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if reading.loader.value != nil {
                    Text("Not in this list").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if let item, item.isRead {
                    Button("Mark unread", systemImage: "circle") { Task { await reading.mark([item.page.ref], read: false) } }
                }
                if let n = following {
                    Button("Skip to the next page", systemImage: "forward") { Task { await model.go(to: n.page.ref) } }
                }
                if let id = reading.info?.id {
                    Button("The whole list", systemImage: "list.number") { navigator.open(.reading(list: id, page: nil)) }
                }
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 32, height: 32)
            }
            .accessibilityLabel("More reading options")
            Button {
                Task { await markAndContinue() }
            } label: {
                if let item, item.isDone {
                    Label("Next", systemImage: "chevron.right")
                } else {
                    Label(item?.changed == true ? "Read again, continue" : "Mark read, continue", systemImage: "checkmark")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(item == nil || reading.isWorking || (item?.isDone == true && reading.upNext == nil && following == nil))
            .accessibilityIdentifier("markReadAndContinue")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// The main action: mark the page read and go on to the next unread page; a page already
    /// read (and unchanged) just goes on.
    func markAndContinue() async {
        guard let item = model.item else { return }
        if item.isDone {
            if let next = reading.upNext ?? reading.neighbour(of: item.page.ref, by: 1) { await model.go(to: next.page.ref) }
            return
        }
        guard let r = await reading.mark([item.page.ref]) else { return }
        if let next = r.upNext {
            await model.go(to: next.page.ref)
        } else if let n = reading.neighbour(of: item.page.ref, by: 1) {
            await model.go(to: n.page.ref)
        }
    }
}

/// "Edited since you read it": each changed section's words added and removed.
struct ChangedSinceRead: View {
    let item: ReadingList.Item
    let changes: Loader<EntityDetail>?
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $open) {
                if let page = changes?.value {
                    let changed = (page.sections ?? []).filter { $0.changedSince == true }
                    if changed.isEmpty {
                        Text("The text reads as it did; the change was to the page's records or details.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(changed) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.heading ?? (s.key == "lead" ? "Introduction" : s.key)).font(.subheadline.weight(.semibold))
                            Text(diffText(s.diff ?? [])).font(.reading(.callout))
                        }
                        .padding(.top, 4)
                    }
                } else if let e = changes?.error {
                    Text(e.message).font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            } label: {
                Label {
                    Text(readOn.map { "Edited since you read it on \($0)" } ?? "Edited since you read it")
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                }
            }
            .accessibilityIdentifier("changedSinceRead")
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    var readOn: String? {
        item.readAt.flatMap(ReadingModel.parseDate).map { $0.formatted(date: .abbreviated, time: .omitted) }
    }

    /// Words kept as they are, added in green and underlined, removed in red and struck through
    /// (marked by more than colour).
    func diffText(_ changes: [WordChange]) -> AttributedString {
        var out = AttributedString()
        for c in changes {
            var a = AttributedString(c.text)
            switch c.op {
            case .equal:
                a.foregroundColor = .secondary
            case .insert:
                a.foregroundColor = .green
                a.underlineStyle = .single
                a.backgroundColor = Color.green.opacity(0.12)
            case .delete:
                a.foregroundColor = .red
                a.strikethroughStyle = .single
            }
            out += a
        }
        return out
    }
}

/// The wiki home's reading list and comments (ADR D-83, D-84).
struct ReadingSummarySection: View {
    @Environment(AppModel.self) private var app
    @State private var loader: Loader<ReadingList>?
    @State private var key: String?

    var body: some View {
        Section("Your reading") {
            if let list = loader?.value, let info = list.readingList {
                NavigationLink(value: Route.reading(list: info.id, page: nil)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(info.title, systemImage: "list.number")
                        if let p = list.progress {
                            ProgressView(value: Double(p.read), total: Double(max(p.pages, 1))).tint(.green)
                            Text("\(p.read) of \(p.pages) read · \(ReadingModel.timeLeft(p.minutesLeft)) left"
                                 + (p.changed > 0 ? " · \(p.changed) changed" : ""))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .accessibilityIdentifier("readingList")
                if let next = list.upNext {
                    NavigationLink(value: Route.reading(list: info.id, page: next.page.ref)) {
                        Label("Continue: \(next.page.shownTitle)", systemImage: "book")
                    }
                }
            } else {
                NavigationLink(value: Route.reading(list: nil, page: nil)) {
                    Label("Read the whole wiki in order", systemImage: "list.number")
                }
                .accessibilityIdentifier("readingList")
            }
            NavigationLink(value: Route.comments(.open)) {
                Label("Comments", systemImage: "text.bubble")
            }
            .accessibilityIdentifier("allComments")
        }
        .task(id: app.context?.key) {
            guard let c = app.context else { return }
            if key != c.key {
                loader = c.loader(API.readingList(limit: 0))
                key = c.key
            }
            await loader?.load()
        }
        .onAppear {
            Task { await loader?.load() }
        }
    }
}
