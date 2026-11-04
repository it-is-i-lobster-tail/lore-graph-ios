import LoreGraphKit
import SwiftUI
import UIKit

/// A page's comments beside its text (ADR D-84): in reading order, with replies, resolve and
/// edit. Comments are notes for the team, not lore: they never change the page.
struct CommentsSheet: View {
    let page: PageModel
    var focus: String?
    @Environment(\.dismiss) private var dismiss

    var model: CommentsModel { page.comments }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let e = model.actionError {
                        Section { ActionErrorRow(error: e) { model.actionError = nil } }
                    }
                    Loaded(loader: model.loader) { _ in
                        if model.shown.isEmpty {
                            ContentUnavailableView {
                                Label(model.resolvedCount > 0 ? "No open comments" : "No comments yet", systemImage: "text.bubble")
                            } description: {
                                Text("Press and hold a paragraph and choose Comment, or tap New comment, to leave a note on a passage.")
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(model.groups) { group in
                            Section(group.title) {
                                ForEach(group.comments) { c in
                                    CommentCard(model: model, comment: c, focused: c.id == focus).id(c.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await model.refresh() }
                .task {
                    guard let focus else { return }
                    if model.comment(focus)?.isOpen == false { model.showResolved = true }
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation { proxy.scrollTo(focus, anchor: .top) }
                }
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        CommentComposer(page: page, section: nil, select: nil) {}
                    } label: {
                        Label("New comment", systemImage: "plus")
                    }
                    .accessibilityIdentifier("newComment")
                }
                ToolbarItem(placement: .bottomBar) {
                    Toggle(isOn: Binding(get: { model.showResolved }, set: { model.showResolved = $0 })) {
                        Text(model.resolvedCount == 1 ? "Show 1 resolved" : "Show \(model.resolvedCount) resolved")
                    }
                    .toggleStyle(.button)
                    .disabled(model.resolvedCount == 0)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A failed change, with the server's reason and hint.
struct ActionErrorRow: View {
    let error: APIError
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error.isOffline ? "wifi.slash" : "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.message).font(.subheadline)
                if let hint = error.hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
    }
}

/// One comment: the passage it is on, the conversation and what can be done with it.
struct CommentCard: View {
    let model: CommentsModel
    let comment: PageComment
    var focused = false
    @Environment(AppModel.self) private var app
    @State private var reply = ""
    @State private var editing: Editing?
    @State private var deleting: Editing?

    struct Editing: Identifiable, Hashable {
        var reply: String?
        var text: String
        var id: String { reply ?? "comment" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PassageQuote(anchor: comment.anchor, sectionExists: comment.section.exists)
            message(author: comment.author, at: comment.createdAt, edited: comment.editedAt != nil,
                    visibility: comment.visibility, body: comment.bodyMd)
            if !comment.isOpen {
                Label("Resolved" + (comment.resolvedBy.map { " by \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
            ForEach(comment.replies) { r in
                message(author: r.author, at: r.createdAt, edited: r.editedAt != nil, visibility: r.visibility, body: r.bodyMd)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 2) }
                    .contextMenu {
                        if r.canEdit { Button("Edit reply", systemImage: "pencil") { editing = Editing(reply: r.id, text: r.bodyMd) } }
                        if r.canDelete {
                            Button("Delete reply", systemImage: "trash", role: .destructive) { deleting = Editing(reply: r.id, text: "") }
                        }
                    }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply", text: $reply, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("replyField")
                Button {
                    let text = reply
                    Task { if await model.reply(to: comment.id, body: text) { reply = "" } }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentInk)
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
                .accessibilityLabel("Send reply")
            }
            HStack {
                if comment.isOpen {
                    Button {
                        let text = reply
                        Task {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                await model.setResolved(comment.id, true)
                            } else if await model.reply(to: comment.id, body: text, resolve: true) {
                                reply = ""
                            }
                        }
                    } label: {
                        Label(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Resolve" : "Reply and resolve",
                              systemImage: "checkmark")
                    }
                    .accessibilityIdentifier("resolveComment")
                } else {
                    Button { Task { await model.setResolved(comment.id, false) } } label: {
                        Label("Reopen", systemImage: "arrow.uturn.backward")
                    }
                }
                Spacer()
                Menu {
                    if comment.canEdit {
                        Button("Edit comment", systemImage: "pencil") { editing = Editing(reply: nil, text: comment.bodyMd) }
                    }
                    if let url = comment.uiUrl.flatMap(URL.init(string:)) {
                        ShareLink(item: url) { Label("Share web link", systemImage: "square.and.arrow.up") }
                    }
                    if comment.canDelete {
                        Button("Delete comment", systemImage: "trash", role: .destructive) { deleting = Editing(reply: nil, text: "") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More for this comment")
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
            .disabled(model.isWorking)
        }
        .padding(.vertical, 4)
        .listRowBackground(focused ? Color.commentMark.opacity(0.4) : nil)
        .sheet(item: $editing) { e in
            EditCommentSheet(title: e.reply == nil ? "Edit comment" : "Edit reply", text: e.text) { text in
                await model.edit(comment.id, reply: e.reply, body: text)
            }
        }
        .confirmationDialog(deleting?.reply == nil ? "Delete this comment and its replies?" : "Delete this reply?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let target = deleting
                Task { await model.delete(comment.id, reply: target?.reply) }
            }
        } message: {
            Text(deleting?.reply == nil ? "Resolving keeps the conversation; deleting removes it for everyone." : "")
        }
    }

    func message(author: PageComment.Author, at: String?, edited: Bool, visibility: LoreGraphKit.Visibility,
                 body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(author.mine ? "You" : author.shown).font(.subheadline.weight(.semibold))
                if let d = at.flatMap(ReadingModel.parseDate) {
                    Text(d.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
                if edited { Text("edited").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                VisibilityChip(visibility: visibility, compact: true)
            }
            Text(inlineMarkdown(body)).font(.body)
        }
    }
}

/// The words a comment is on, and what became of them.
struct PassageQuote: View {
    let anchor: PageComment.Anchor
    var sectionExists = true

    var body: some View {
        switch anchor.status {
        case .section:
            Label("On the whole section", systemImage: "text.alignleft").font(.caption).foregroundStyle(.secondary)
        case .exact:
            quote(anchor.text ?? anchor.quote ?? "")
        case .changed:
            VStack(alignment: .leading, spacing: 4) {
                quote(anchor.text ?? "")
                Label("The passage was edited. It read: “\(anchor.quote ?? "")”", systemImage: "pencil.line")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .detached:
            VStack(alignment: .leading, spacing: 4) {
                if let q = anchor.quote { quote(q).strikethrough() }
                Label(sectionExists ? "These words are no longer in the text." : "The section was removed.",
                      systemImage: "exclamationmark.bubble")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    func quote(_ text: String) -> some View {
        Text(text)
            .font(.reading(.callout))
            .italic()
            .lineLimit(4)
            .padding(.leading, 10)
            .overlay(alignment: .leading) { Rectangle().fill(Color.yellow).frame(width: 3) }
    }
}

/// Comment text: inline markdown (emphasis, links) shown as data, never acted on.
func inlineMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

/// Changing the text of the reader's own comment or reply.
struct EditCommentSheet: View {
    let title: String
    @State var text: String
    let save: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            saving = true
                            Task {
                                if await save(text) { dismiss() }
                                saving = false
                            }
                        }
                        .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

/// A new comment: choose the section, select the words in its text (or none, for the whole
/// section) and write the comment.
struct CommentComposer: View {
    let page: PageModel
    let initialSection: String?
    let select: String?
    let done: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var section: String?
    @State private var picked: Anchors.Picked?
    @State private var text = ""
    @State private var posting = false
    @FocusState private var writing: Bool

    init(page: PageModel, section: String?, select: String?, done: @escaping () -> Void) {
        self.page = page
        initialSection = section
        self.select = select
        self.done = done
    }

    var sections: [EntityDetail.Section] { page.commentableSections }
    var current: EntityDetail.Section? { sections.first { $0.key == section } }

    var body: some View {
        Form {
            if let e = page.comments.actionError {
                Section { ActionErrorRow(error: e) { page.comments.actionError = nil } }
            }
            Section {
                Picker("Section", selection: $section) {
                    ForEach(sections) { s in
                        Text(s.heading ?? (s.key == "lead" ? "Introduction" : s.key)).tag(Optional(s.key))
                    }
                }
            }
            if let s = current {
                Section {
                    if let html = s.html, !html.isEmpty {
                        let selectable = Anchors.Selectable(html: html)
                        SelectableText(text: selectable, initial: s.key == initialSection ? select : nil) { range in
                            picked = range.flatMap { selectable.pick(utf16: $0) }
                        }
                        .frame(minHeight: 120, maxHeight: 280)
                        .id(s.key)
                    }
                } header: {
                    Text("Select the words to comment on")
                } footer: {
                    if let p = picked {
                        Text("On “\(p.quote)”").lineLimit(3)
                    } else {
                        Text(s.generated == true ? "This section is drawn from records, so the comment is on the whole section."
                                                 : "Nothing selected: the comment is on the whole section.")
                    }
                }
            }
            Section("Comment") {
                TextField("What should change, or what do you want to know?", text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .focused($writing)
                    .accessibilityIdentifier("commentText")
            }
            Section {
                Text("Comments are notes for the team: they don't change the page. They're restricted by default.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("New comment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    done()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Post") {
                    guard let key = section else { return }
                    posting = true
                    Task {
                        let ok = await page.comments.add(section: key, picked: picked, body: text) != nil
                        posting = false
                        if ok {
                            dismiss()
                            done()
                        }
                    }
                }
                .disabled(posting || section == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("postComment")
            }
        }
        .onAppear {
            if section == nil { section = initialSection ?? sections.first?.key }
        }
        .onChange(of: section) { picked = nil }
    }
}

/// A section's text in a read-only text view whose selection picks the passage. The system's
/// own selection handles (and their magnifier) do the picking.
struct SelectableText: UIViewRepresentable {
    let text: Anchors.Selectable
    /// Words to select at first (the paragraph a comment was started from).
    var initial: String?
    let onSelect: (Range<Int>?) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.font = UIFont(descriptor: UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body).withDesign(.serif)
                            ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body), size: 0)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.text = text.display
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "sectionText"
        if let initial, let r = text.display.range(of: initial) {
            let ns = NSRange(r, in: text.display)
            let coordinator = context.coordinator
            Task { @MainActor in
                view.becomeFirstResponder()
                view.selectedRange = ns
                coordinator.textViewDidChangeSelection(view)
            }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.onSelect = onSelect
        if view.text != text.display { view.text = text.display }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSelect: (Range<Int>?) -> Void

        init(onSelect: @escaping (Range<Int>?) -> Void) {
            self.onSelect = onSelect
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            let r = view.selectedRange
            onSelect(r.length > 0 && r.location != NSNotFound ? r.location..<(r.location + r.length) : nil)
        }
    }
}

/// Comments across the world, the latest activity first (the web app's /comments).
struct AllCommentsView: View {
    let status: PageComment.Status?

    var body: some View {
        ContextModel(make: { AllCommentsModel(status: status, context: $0) }, load: { await $0.load() }) { model in
            List {
                Section {
                    Picker("Show", selection: Binding(get: { model.status }, set: { s in Task { await model.set(status: s) } })) {
                        Text("Open").tag(PageComment.Status?.some(.open))
                        Text("Resolved").tag(PageComment.Status?.some(.resolved))
                        Text("All").tag(PageComment.Status?.none)
                    }
                    .pickerStyle(.segmented)
                }
                Loaded(loader: model.loader) { list in
                    if list.comments.isEmpty {
                        ContentUnavailableView("No comments", systemImage: "text.bubble",
                                               description: Text("Comments teammates leave on page text show here."))
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        ForEach(list.comments) { c in
                            if let page = c.page {
                                NavigationLink(value: Route.pageComments(page.ref, focus: c.id)) { CommentRow(comment: c) }
                            } else {
                                CommentRow(comment: c)
                            }
                        }
                    } footer: {
                        if list.nextCursor != nil { Text("Showing the latest \(list.comments.count).") }
                    }
                }
            }
            .refreshable { await model.refresh() }
            .staleBanner(model.loader)
            .navigationTitle("Comments")
        }
    }
}

struct CommentRow: View {
    let comment: PageComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.page?.shownTitle ?? "A deleted page").font(.subheadline.weight(.semibold))
                Text(comment.section.heading ?? (comment.section.key == "lead" ? "Introduction" : comment.section.key))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !comment.isOpen { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Resolved") }
            }
            if comment.anchor.status != .section { PassageQuote(anchor: comment.anchor, sectionExists: comment.section.exists) }
            Text(inlineMarkdown(comment.bodyMd)).lineLimit(3)
            HStack(spacing: 8) {
                Text(comment.author.mine ? "You" : comment.author.shown)
                if !comment.replies.isEmpty { Text(comment.replies.count == 1 ? "1 reply" : "\(comment.replies.count) replies") }
                if let d = (comment.updatedAt ?? comment.createdAt).flatMap(ReadingModel.parseDate) {
                    Text(d.formatted(.relative(presentation: .named)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
