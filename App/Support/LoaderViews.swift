import LoreGraphKit
import SwiftUI

/// A loader's value, or its error, or a spinner while the first answer comes.
struct Loaded<Value: Sendable, Content: View>: View {
    let loader: Loader<Value>
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value = loader.value {
            content(value)
        } else if let error = loader.error {
            ErrorState(error: error) { await loader.refresh() }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
        }
    }
}

/// A failure in words, with the server's hint and a way to try again (F-11.6).
struct ErrorState: View {
    let error: APIError
    var retry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: symbol)
        } description: {
            VStack(spacing: 6) {
                Text(error.message)
                if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            }
        } actions: {
            if let retry, !isSignedOut {
                Button("Try again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        }
    }

    var isSignedOut: Bool {
        if case .signedOut = error { return true }
        return false
    }

    var symbol: String {
        switch error {
        case .offline: "wifi.slash"
        case .notFound: "questionmark.folder"
        case .signedOut: "person.crop.circle.badge.xmark"
        default: "exclamationmark.triangle"
        }
    }
}

/// Says when the page shown is the saved copy and couldn't be checked (F-11.4).
struct StaleBanner: View {
    let error: APIError?
    let updatedAt: Date?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: error?.isOffline == true ? "wifi.slash" : "exclamationmark.triangle")
            VStack(alignment: .leading, spacing: 1) {
                Text(error?.isOffline == true ? "Offline" : (error?.title ?? "Couldn't check for changes"))
                    .font(.footnote.weight(.semibold))
                if let updatedAt {
                    Text("Showing the copy saved \(updatedAt.formatted(.relative(presentation: .named))). Pull down to try again.")
                        .font(.caption)
                } else {
                    Text("Showing the saved copy. Pull down to try again.").font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The offline banner over a screen whose loader has a value but its last check failed.
    func staleBanner<V: Sendable>(_ loader: Loader<V>?) -> some View {
        safeAreaInset(edge: .top) {
            if let loader, loader.value != nil, let error = loader.error {
                StaleBanner(error: error, updatedAt: loader.updatedAt)
            }
        }
    }
}

/// Builds a screen's model for the current world and view, and builds it again when either
/// changes (F-3.6).
struct ContextModel<Model: AnyObject, Content: View>: View {
    @Environment(AppModel.self) private var app
    let make: (ReadContext) -> Model
    let load: @MainActor (Model) async -> Void
    @ViewBuilder let content: (Model) -> Content
    @State private var model: Model?
    @State private var key: String?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: app.context?.key) {
            guard let c = app.context, c.key != key else { return }
            let m = make(c)
            model = m
            key = c.key
            await load(m)
        }
    }
}
