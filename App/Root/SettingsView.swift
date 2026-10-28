import LoreGraphKit
import SwiftUI

/// Account, lock, cache and sign-out (F-1.5, F-1.6, F-11.4).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var confirmSignOut = false
    @State private var clearing = false
    @State private var cleared = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: app.me?.displayName ?? app.reader?.name ?? "")
                    if let email = app.me?.email { LabeledContent("Email", value: email) }
                    if let role = app.me?.role { LabeledContent("Role", value: role.capitalized) }
                    LabeledContent("Can see", value: app.reader?.ceiling.label ?? "")
                    if let scopes = app.me?.scopes { LabeledContent("Access", value: scopes.joined(separator: ", ")) }
                    LabeledContent("Server", value: app.reader?.server.host ?? "")
                }
                Section {
                    Toggle("Require Face ID", isOn: $app.settings.requireUnlock)
                        .accessibilityIdentifier("requireUnlock")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(app.hidesInSwitcher
                         ? "You can see more than public pages, so the app switcher shows a blurred picture of the app."
                         : "Ask for Face ID or your passcode whenever the app opens.")
                }
                Section {
                    LabeledContent("Saved pages and tiles", value: byteText(app.cacheBytes))
                        .accessibilityIdentifier("cacheSize")
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        HStack {
                            Text("Clear cache")
                            Spacer()
                            if clearing { ProgressView() } else if cleared { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityIdentifier("clearCache")
                    Button("Clear recent pages and searches") { app.clearHistory() }
                } header: {
                    Text("Cache")
                } footer: {
                    Text("Pages and map tiles you've opened stay readable offline. Clearing them frees the space; they come back as you read.")
                }
                Section("About") {
                    LabeledContent("App", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    if let v = app.me?.version ?? app.about?.version { LabeledContent("Server", value: v) }
                }
                Section {
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .accessibilityIdentifier("signOut")
                } footer: {
                    Text("Signing out ends the sign-in on the server and deletes every saved page and tile from this device.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await app.updateCacheSize() }
            .confirmationDialog("Clear the cache?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear cache", role: .destructive) {
                    Task {
                        clearing = true
                        await app.clearCache()
                        clearing = false
                        cleared = true
                    }
                }
            } message: {
                Text("Saved pages and map tiles are deleted. You stay signed in.")
            }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        dismiss()
                        await app.signOut()
                    }
                }
            }
        }
    }
}

/// The worlds you can open, with their page counts and present (F-2.1).
struct WorldPicker: View {
    var firstLaunch = false
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(app.worlds) { w in
                Button {
                    Task {
                        await app.selectWorld(w.key)
                        dismiss()
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(w.name).font(.headline)
                                VisibilityChip(visibility: w.visibility, compact: true)
                            }
                            if let d = w.description { Text(d).font(.subheadline).foregroundStyle(.secondary) }
                            HStack(spacing: 10) {
                                if let n = w.pages { Text("\(n) pages") }
                                if let p = w.present { Text(p) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if w.key == app.world?.key { Image(systemName: "checkmark").foregroundStyle(Color.accentInk) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("world-\(w.key)")
            }
            .navigationTitle(firstLaunch ? "Choose a world" : "Worlds")
        }
    }
}
