import LoreGraphKit
import Network
import SwiftUI

@main
struct LoreGraphApp: App {
    @State private var app: AppModel
    @State private var connection = ConnectionMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _app = State(initialValue: AppModel(environment: .live()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task {
                    let app = app
                    connection.start { online in Task { await app.connectivityChanged(online: online) } }
                    await app.start()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.didEnterBackground() }
            // back at the front: send waiting comments and refresh stale downloads
            if phase == .active { Task { await app.didBecomeActive() } }
        }
    }
}

extension AppEnvironment {
    /// The phone's Keychain, UserDefaults and Caches folder. UI tests start from nothing.
    static func live() -> AppEnvironment {
        let args = ProcessInfo.processInfo.arguments
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("loregraph", isDirectory: true)
        if args.contains("-uiTesting") {
            try? FileManager.default.removeItem(at: caches)
            try? KeychainTokenStore().delete()
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        }
        return AppEnvironment(transport: URLSessionTransport.ephemeral(), tokenStore: KeychainTokenStore(),
                              defaults: UserDefaultsStore(), cacheRoot: caches)
    }
}

/// Tells the app when the phone's connection comes and goes, so comments written offline are
/// sent and downloads refreshed as soon as it is back.
@MainActor
final class ConnectionMonitor {
    private let monitor = NWPathMonitor()
    private var online: Bool?
    private var onChange: (@MainActor (Bool) -> Void)?

    func start(_ onChange: @escaping @MainActor (Bool) -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.changed(up) }
        }
        monitor.start(queue: DispatchQueue(label: "loregraph.connection"))
    }

    private func changed(_ up: Bool) {
        guard up != online else { return }
        online = up
        onChange?(up)
    }
}
