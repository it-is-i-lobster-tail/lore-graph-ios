import LoreGraphKit
import SwiftUI

/// The app's sections: tabs on iPhone, the sidebar on iPad (F-11.1).
enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case wiki, map, timeline, family, graph, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wiki: "Wiki"
        case .map: "Map"
        case .timeline: "Timeline"
        case .family: "Family"
        case .graph: "Graph"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .wiki: "book"
        case .map: "map"
        case .timeline: "calendar.day.timeline.left"
        case .family: "figure.2.and.child.holdinghands"
        case .graph: "circle.hexagongrid"
        case .search: "magnifyingglass"
        }
    }

    /// The section a shared link opens in.
    static func of(_ route: Route) -> AppSection {
        switch route {
        case .map: .map
        case .timeline: .timeline
        case .family: .family
        case .graph: .graph
        case .search: .search
        default: .wiki
        }
    }
}

/// One section's navigation stack.
@Observable
@MainActor
final class Navigator {
    var path: [Route] = []

    func open(_ route: Route) {
        if path.last != route { path.append(route) }
    }

    func popToRoot() { path = [] }
}

/// Every tab's navigator, and which tab shows.
@Observable
@MainActor
final class Navigation {
    var section: AppSection = .wiki
    let stacks: [AppSection: Navigator] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { ($0, Navigator()) })
    /// The last family tree opened, for the Family tab (F-8.8).
    var lastFamily: String?
    /// The search text handed over by a link.
    var pendingSearch: String?
    /// iPhone has no Search tab (five tabs fill its bar): search opens on the wiki's stack.
    var searchInWiki = false

    func navigator(_ s: AppSection) -> Navigator { stacks[s]! }

    /// Opens a route in its own section's stack (shared links, F-11.2).
    func show(_ route: Route) {
        if case .search = route, searchInWiki {
            section = .wiki
            navigator(.wiki).open(route)
            return
        }
        let s = AppSection.of(route)
        section = s
        switch route {
        case .search(let text):
            pendingSearch = text
        case .map, .timeline, .graph:
            navigator(s).path = [route]
        default:
            navigator(s).open(route)
        }
    }
}

extension View {
    /// Opens loregraph links (page links in text, shared web addresses) in the app; anything
    /// else goes to the system.
    func loregraphLinks(_ navigator: Navigator, app: AppModel) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard let link = WebLink.parse(url, server: app.reader?.server) else { return .systemAction }
            if link.world != nil || !link.view.isDefault {
                Task {
                    if let route = await app.open(url) { navigator.open(route) }
                }
            } else {
                navigator.open(link.route)
            }
            return .handled
        })
    }

    /// The destinations every stack can reach.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteView(route: $0).contextBanner() }
    }
}

/// The screen for a route.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .home: HomeView()
        case .browse(let type): BrowseView(type: type)
        case .page(let ref), .history(let ref): PageView(ref: ref)
        case .records(let ref): RecordsView(ref: ref)
        case .links(let ref): LinksView(ref: ref)
        case .record(let id): RecordView(id: id)
        case .compare(let ref): AccountsView(ref: ref)
        case .beliefs(let ref): BeliefsView(ref: ref)
        case .beliefQuestion(let key): BeliefHoldersView(key: key)
        case .beliefTrace(let id): BeliefTraceView(id: id)
        case .faction(let ref): FactionView(ref: ref)
        case .family(let ref, let options): FamilyScreen(ref: ref, options: options)
        case .graph(let options): GraphScreen(options: options)
        case .timeline(let options): TimelineScreen(options: options)
        case .map(let options): MapScreen(options: options)
        case .search(let text): SearchScreen(initial: text, pushed: true)
        case .trail(let slug): TrailView(slug: slug)
        case .savedView(let slug): SavedViewView(slug: slug)
        }
    }
}
