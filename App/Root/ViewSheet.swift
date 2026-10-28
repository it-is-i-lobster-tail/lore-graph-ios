import LoreGraphKit
import SwiftUI

/// World, as of, whose eyes, calendar and show as (F-3.1 to F-3.4).
struct ViewSheet: View {
    enum When: String, CaseIterable, Identifiable {
        case allTime, present, date

        var id: String { rawValue }
        var label: String {
            switch self {
            case .allTime: "All time"
            case .present: "Present"
            case .date: "A date"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ViewState()
    @State private var when: When = .allTime
    @State private var dateText = ""
    @State private var understood: DateConversion?
    @State private var dateError: String?
    @State private var viewpointQuery = ""
    @State private var viewpointHits: [Suggestions.Candidate] = []

    var body: some View {
        NavigationStack {
            Form {
                if app.worlds.count > 1 {
                    Section("World") {
                        Picker("World", selection: Binding(get: { app.world?.key ?? "" }, set: { key in
                            Task { await app.selectWorld(key); draft = app.view; syncWhen() }
                        })) {
                            ForEach(app.worlds) { Text($0.name).tag($0.key) }
                        }
                    }
                }
                asOfSection
                viewpointSection
                if let calendars = app.about?.calendars, calendars.count > 1 {
                    Section("Calendar") {
                        Picker("Dates in", selection: $draft.calendar) {
                            Text("The world's default").tag(String?.none)
                            ForEach(calendars) { c in Text(c.name).tag(String?.some(c.key)) }
                        }
                    }
                }
                if let ceiling = app.reader?.ceiling, ceiling > .public {
                    Section {
                        Picker("Show as", selection: Binding(get: { draft.viewAs ?? ceiling }, set: { draft.viewAs = $0 == ceiling ? nil : $0 })) {
                            ForEach(LoreGraphKit.Visibility.allCases.filter { $0 <= ceiling }, id: \.self) { Text($0.label).tag($0) }
                        }
                    } header: {
                        Text("Show as")
                    } footer: {
                        Text("See pages as a player would. This never shows more than your sign-in allows.")
                    }
                }
            }
            .navigationTitle("The view")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        app.setView(draft)
                        dismiss()
                    }
                    .accessibilityIdentifier("applyView")
                }
            }
            .onAppear {
                draft = app.view
                syncWhen()
            }
            .task(id: viewpointQuery) { await findViewpoints() }
        }
    }

    private func syncWhen() {
        if let y = draft.asOf {
            when = abs(y - (app.about?.presentYear ?? -1)) < 0.001 ? .present : .date
            dateText = draft.asOfLabel ?? YearText.label(y)
        } else {
            when = .allTime
        }
    }

    @ViewBuilder var asOfSection: some View {
        Section {
            Picker("When", selection: $when) {
                ForEach(When.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: when) { _, w in
                switch w {
                case .allTime:
                    draft.asOf = nil
                    draft.asOfLabel = nil
                case .present:
                    draft.asOf = app.about?.presentYear
                    draft.asOfLabel = app.about?.present?.text
                case .date:
                    if draft.asOf == nil { draft.asOf = app.about?.presentYear }
                }
            }
            if when == .date {
                TextField("summer 1020, LC 1595, c. 900", text: $dateText)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await convert() } }
                    .accessibilityIdentifier("dateText")
                if let understood {
                    Button {
                        draft.asOf = understood.parsed.from ?? understood.parsed.to
                        draft.asOfLabel = understood.parsed.label ?? understood.parsed.formatted ?? dateText
                    } label: {
                        Label("Use \(understood.parsed.text)", systemImage: "checkmark.circle")
                    }
                }
                if let dateError { Text(dateError).font(.footnote).foregroundStyle(.red) }
                if let y = draft.asOf {
                    Stepper {
                        Text(draft.asOfLabel ?? YearText.label(y))
                    } onIncrement: {
                        draft.asOf = y + 1
                        draft.asOfLabel = nil
                    } onDecrement: {
                        draft.asOf = y - 1
                        draft.asOfLabel = nil
                    }
                }
            }
        } header: {
            Text("As of")
        } footer: {
            Text("Type a date the way the wiki writes them. The app shows what the server understood before using it.")
        }
    }

    @ViewBuilder var viewpointSection: some View {
        Section {
            if let vp = draft.viewpoint {
                HStack {
                    Label(vp.title, systemImage: "eye")
                    Spacer()
                    Button("Back to the record") { draft.viewpoint = nil }.font(.footnote)
                }
            } else {
                Label("The record: what really happened", systemImage: "book.closed")
            }
            TextField("A person, faction, family or place", text: $viewpointQuery)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            ForEach(viewpointHits) { c in
                Button {
                    draft.viewpoint = .init(ref: c.ref, title: c.title)
                    viewpointQuery = ""
                    viewpointHits = []
                } label: {
                    EntityRow(card: c.card)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Through whose eyes")
        } footer: {
            Text("Names, calendar and beliefs follow that holder.")
        }
    }

    func convert() async {
        guard let c = app.context, !dateText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            understood = try await c.repository.client.get(API.convertDate(dateText), world: c.world).value
            dateError = nil
        } catch let e as APIError {
            understood = nil
            dateError = e.message
        } catch {
            dateError = error.localizedDescription
        }
    }

    func findViewpoints() async {
        let q = viewpointQuery.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, let c = app.context else {
            viewpointHits = []
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let answer = try? await c.repository.client.get(API.suggest(q, types: [.individual, .faction, .location]),
                                                        world: c.world).value
        viewpointHits = answer?.candidates ?? []
    }
}
