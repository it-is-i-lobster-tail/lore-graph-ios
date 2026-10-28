import AuthenticationServices
import LoreGraphKit
import SwiftUI

/// The server address and sign-in on the server's own page (F-1.1 to F-1.3).
struct SignInView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.webAuthenticationSession) private var webAuth
    @AppStorage("lastServer") private var server = "loregraph.stanley-cloud.net"
    @State private var token = ""
    @State private var showToken = false
    @State private var busy = false
    @State private var error: APIError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "book.pages")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.accentInk)
                        Text("Read your worlds: the wiki, the map, the timeline, family trees and the graph.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Server", text: $server)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("server")
                } header: {
                    Text("Server")
                } footer: {
                    Text("You sign in on your server's own page. The app asks for read access only and can't change anything.")
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Text("Sign in")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || server.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("signIn")
                }
                if let error {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(error.title).font(.headline)
                                Text(error.message).font(.subheadline)
                                if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .accessibilityIdentifier("signInError")
                    }
                }
                Section {
                    DisclosureGroup(isExpanded: $showToken) {
                        SecureField("lgp_…", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("token")
                        Button("Sign in with token") { Task { await signInWithToken() } }
                            .disabled(busy || token.isEmpty)
                            .accessibilityIdentifier("signInWithToken")
                        Text("Make a read-only token in the web app under Settings, Connections.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        // on the label only: on the group it would replace the identifiers inside it
                        Text("Use a personal token instead")
                            .accessibilityIdentifier("tokenDisclosure")
                    }
                }
            }
            .navigationTitle("loregraph")
            .onAppear { if error == nil { error = app.signInMessage } }
        }
    }

    func signIn() async {
        busy = true
        defer { busy = false }
        do {
            let pending = try await app.prepareSignIn(server: server)
            let callback = try await webAuth.authenticate(using: pending.request.url,
                                                          callbackURLScheme: OAuthClient.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            try await app.completeSignIn(pending, callback: callback)
            error = nil
        } catch let e as APIError {
            error = e
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            error = nil
        } catch {
            self.error = .problem(Problem(title: "Sign-in didn't finish", detail: error.localizedDescription))
        }
    }

    func signInWithToken() async {
        busy = true
        defer { busy = false }
        do {
            try await app.signIn(server: server, personalToken: token)
            token = ""
            error = nil
        } catch let e as APIError {
            error = e
        } catch {
            self.error = .problem(Problem(title: "Sign-in didn't finish", detail: error.localizedDescription))
        }
    }
}
