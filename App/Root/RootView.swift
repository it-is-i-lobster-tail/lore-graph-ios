import LocalAuthentication
import LoreGraphKit
import SwiftUI

/// Sign-in, the lock, or the app; and the blurred snapshot in the app switcher (F-1.6).
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch app.phase {
            case .starting:
                ProgressView().controlSize(.large)
            case .signedOut:
                SignInView()
            case .signedIn:
                MainView()
                    .blur(radius: app.isLocked ? 30 : 0)
                    .allowsHitTesting(!app.isLocked)
                if app.isLocked { LockView() }
            }
            if scenePhase != .active && app.hidesInSwitcher {
                Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary) }
                    .accessibilityHidden(true)
            }
        }
        .animation(.default, value: app.phase)
    }
}

/// Face ID or the passcode before the app shows anything (F-1.6).
struct LockView: View {
    @Environment(AppModel.self) private var app
    @State private var failed: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(Color.accentInk)
            Text("loregraph is locked").font(.title2.weight(.semibold))
            if let failed { Text(failed).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Button("Unlock") { Task { await unlock() } }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("unlock")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await unlock() }
    }

    func unlock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // no passcode on this device: nothing to check against
            app.unlock()
            return
        }
        do {
            if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your lore") {
                app.unlock()
            }
        } catch {
            failed = "Not unlocked. Try again when you're ready."
        }
    }
}
