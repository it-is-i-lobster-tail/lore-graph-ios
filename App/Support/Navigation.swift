import LoreGraphKit
import SwiftUI

/// The app's sections: tabs on iPhone, the sidebar on iPad (F-11.1).
enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case wiki, map, family, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wiki: "Wiki"
        case .map: "Map"
        case .family: "Family"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .wiki: "book"
        case .map: "map"
        case .family: "figure.2.and.child.holdinghands"
        case .search: "magnifyingglass"
        }
    }

    /// The section a shared link opens in.
    static func of(_ route: Route) -> AppSection {
        switch route {
        case .map: .map
        case .family: .family
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

    func navigator(_ s: AppSection) -> Navigator { stacks[s]! }

    /// Opens a route in its own section's stack (shared links, F-11.2).
    func show(_ route: Route) {
        let s = AppSection.of(route)
        section = s
        switch route {
        case .search(let text):
            pendingSearch = text
        case .map:
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
        navigationDestination(for: Route.self) { route in
            RouteView(route: route).contextBanner(atPresent: route.isMap)
        }
    }
}

/// The screen for a route.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .home: HomeView()
        case .browse(let type): BrowseView(type: type)
        case .category(let slug, let title): BrowseView(type: nil, category: slug, categoryTitle: title)
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
        case .map(let options): MapScreen(options: options)
        case .search(let text): SearchScreen(initial: text, pushed: true)
        case .trail(let slug): TrailView(slug: slug)
        case .savedView(let slug): SavedViewView(slug: slug)
        case .reading(let list, nil): ReadingListView(list: list)
        case .reading(let list, let page?): ReadingPageView(list: list, ref: page)
        case .pageComments(let ref, let focus): PageView(ref: ref, focus: focus, showComments: true)
        case .comments(let status): AllCommentsView(status: status)
        case .downloads: DownloadsView()
        }
    }
}

extension Route {
    /// Whether this is the map, which always shows the in-world present.
    var isMap: Bool {
        if case .map = self { return true }
        return false
    }
}
