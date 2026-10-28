import LoreGraphKit
import SwiftUI

@main
struct LoreGraphApp: App {
    @State private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _app = State(initialValue: AppModel(environment: .live()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.didEnterBackground() }
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
