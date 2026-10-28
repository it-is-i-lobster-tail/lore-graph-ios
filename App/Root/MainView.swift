import LoreGraphKit
import SwiftUI

/// The tabs (iPhone) or sidebar (iPad), each with its own stack (F-11.1).
struct MainView: View {
    @Environment(AppModel.self) private var app
    @State private var nav = Navigation()

    var body: some View {
        TabView(selection: $nav.section) {
            ForEach(AppSection.allCases.filter { $0 != .search }) { s in
                Tab(s.title, systemImage: s.symbol, value: s) {
                    SectionStack(section: s)
                }
            }
            Tab(value: AppSection.search, role: .search) {
                SectionStack(section: .search)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(nav)
        .onOpenURL { url in
            Task { if let route = await app.open(url) { nav.show(route) } }
        }
        .onChange(of: app.context?.world) { old, new in
            // another world opens at its wiki home (F-2.2)
            guard old != nil, old != new else { return }
            for s in AppSection.allCases { nav.navigator(s).popToRoot() }
            nav.lastFamily = nil
            nav.section = .wiki
        }
        .sheet(isPresented: .constant(app.needsWorldChoice)) {
            WorldPicker(firstLaunch: true)
                .interactiveDismissDisabled()
        }
    }
}

/// One section: its root screen and everything pushed on it.
struct SectionStack: View {
    let section: AppSection
    @Environment(Navigation.self) private var nav
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var navigator = nav.navigator(section)
        NavigationStack(path: $navigator.path) {
            root
                .worldToolbar()
                .routeDestinations()
        }
        .environment(navigator)
        .loregraphLinks(navigator, app: app)
    }

    @ViewBuilder var root: some View {
        switch section {
        case .wiki: HomeView()
        case .map: MapScreen(options: MapOptions(), isTab: true)
        case .timeline: TimelineScreen(options: TimelineOptions())
        case .family: FamilyTab()
        case .graph: GraphTab()
        case .search: SearchScreen(initial: nav.pendingSearch ?? "")
        }
    }
}

/// The world menu at the top of every tab (F-2.2) and the account button.
struct WorldToolbar: ViewModifier {
    @Environment(AppModel.self) private var app
    @State private var showView = false
    @State private var showSettings = false
    @State private var showWorlds = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if app.worlds.count > 1 {
                            Section("World") {
                                ForEach(app.worlds) { w in
                                    Button {
                                        Task { await app.selectWorld(w.key) }
                                    } label: {
                                        if w.key == app.world?.key { Label(w.name, systemImage: "checkmark") } else { Text(w.name) }
                                    }
                                }
                            }
                        }
                        Button("Year, viewpoint and calendar…", systemImage: "slider.horizontal.3") { showView = true }
                        if !app.view.isDefault {
                            Button("Reset the view", systemImage: "arrow.uturn.backward") { app.resetView() }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(app.world?.name ?? "loregraph").font(.headline)
                            Text(viewLine).font(.caption2).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("worldMenu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "person.crop.circle") { showSettings = true }
                        .accessibilityIdentifier("settings")
                }
            }
            .sheet(isPresented: $showView) { ViewSheet() }
            .sheet(isPresented: $showSettings) { SettingsView() }
    }

    /// "Spring YV 1131", "As of YV 1020 · Dirk".
    var viewLine: String {
        let v = app.view
        var parts: [String] = []
        if let y = v.asOf { parts.append(v.asOfLabel ?? YearText.label(y)) } else { parts.append(app.about?.present?.text ?? "The present") }
        if let vp = v.viewpoint { parts.append(vp.title) }
        if let a = v.viewAs, a != .designer { parts.append("as \(a.label)") }
        return parts.joined(separator: " · ")
    }
}

/// The banner when the year, viewpoint or level isn't the default (F-3.5).
struct ContextBanner: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let sentence = app.view.banner(calendarName: app.about?.calendars?.first { $0.key == app.view.calendar }?.name) {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.accentInk)
                    Text(sentence).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Reset") { app.resetView() }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.accentInk.opacity(0.08))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("contextBanner")
            }
        }
    }
}

extension View {
    func worldToolbar() -> some View { modifier(WorldToolbar()).modifier(ContextBanner()) }

    func contextBanner() -> some View { modifier(ContextBanner()) }
}
