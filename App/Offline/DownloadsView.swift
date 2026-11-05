import LoreGraphKit
import SwiftUI

/// The pages kept for reading offline, and the comment changes waiting to be sent.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmRemoveAll = false
    @State private var confirmWhole = false

    var body: some View {
        Group {
            if let offline = app.offline {
                content(offline)
            } else {
                ContentUnavailableView("Not signed in", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    func content(_ offline: OfflineModel) -> some View {
        let world = app.world?.key
        let pages = offline.downloads.filter { $0.world == world }
        let elsewhere = offline.downloads.count - pages.count
        let waiting = offline.pending(world: world)
        return List {
            WholeWorldSection(offline: offline, world: world, confirm: $confirmWhole)
            if !waiting.isEmpty {
                Section {
                    ForEach(waiting) { c in WaitingRow(change: c, offline: offline) }
                } header: {
                    Text("Waiting to send")
                } footer: {
                    Text(offline.lastSyncOffline
                         ? "You're offline. These go to the server, in the order you made them, when the app is back online."
                         : "These go to the server in the order you made them. Any the server refused wait here for you.")
                }
            }
            Section {
                if pages.isEmpty {
                    ContentUnavailableView {
                        Label("No downloaded pages", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Tap \(Image(systemName: "arrow.down.circle")) on a page to keep it, with its comments and pictures, for reading offline.")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(pages) { d in
                    NavigationLink(value: Route.page(d.ref)) {
                        DownloadRow(download: d, working: offline.working.contains(d.id))
                    }
                    .swipeActions {
                        Button("Remove", systemImage: "trash", role: .destructive) { Task { await offline.remove(d) } }
                    }
                }
            } header: {
                Text(pages.isEmpty ? "Downloaded pages" : "Downloaded pages · \(byteText(offline.downloadBytes))")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloaded pages stay on this device with their comments and pictures. When the app opens or its connection comes back, it checks them and fetches again any the wiki has changed.")
                    if let last = offline.lastSync {
                        Text("Last checked \(last.formatted(.relative(presentation: .named))).")
                    }
                    if elsewhere > 0 {
                        Text(elsewhere == 1 ? "1 more page is downloaded in another world." : "\(elsewhere) more pages are downloaded in other worlds.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await offline.flush()
            await offline.refreshDownloads(force: true)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Check now", systemImage: "arrow.clockwise") {
                        Task {
                            await offline.flush()
                            await offline.refreshDownloads(force: true)
                        }
                    }
                    Button("Remove all downloads", systemImage: "trash", role: .destructive) { confirmRemoveAll = true }
                        .disabled(offline.downloads.isEmpty)
                } label: {
                    if offline.isSyncing || !offline.working.isEmpty { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
                .accessibilityLabel("Downloads options")
            }
        }
        .confirmationDialog(wholeTitle, isPresented: $confirmWhole, titleVisibility: .visible) {
            Button("Download every page") {
                let view = app.view
                Task { await offline.keepWholeWorld(world, view: view, on: true) }
            }
        } message: {
            Text("Every page of \(app.world?.name ?? "this world") is downloaded with its comments and pictures, then kept up to date, with new pages added as they appear. This can take a while and use a lot of storage, so Wi-Fi is best.")
        }
        .confirmationDialog("Remove all downloads?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all downloads", role: .destructive) { Task { await offline.removeAll() } }
        } message: {
            Text("Downloaded pages in every world are deleted from this device, and no world is kept downloaded whole. Comments waiting to be sent are kept.")
        }
        .task { await offline.sync() }
    }

    var wholeTitle: String {
        if let n = app.about?.counts?.totalPages, n > 0 { return "Download all \(n) pages?" }
        return "Download every page?"
    }
}

/// The switch that keeps a whole world downloaded, with the download's progress.
struct WholeWorldSection: View {
    let offline: OfflineModel
    let world: String?
    @Binding var confirm: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { offline.keepsWholeWorld(world) }, set: { on in
                if on {
                    confirm = true
                } else {
                    let view = app.view
                    Task { await offline.keepWholeWorld(world, view: view, on: false) }
                }
            })) {
                Text("Keep every page downloaded")
            }
            .accessibilityIdentifier("downloadWholeWorld")
            if let b = offline.bulk, b.world == world {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(b.done), total: Double(max(b.total, 1)))
                    HStack {
                        Text(b.total == 0 ? "Finding the pages…" : "Downloading \(b.done) of \(b.total)")
                            .monospacedDigit()
                        Spacer()
                        Button("Stop for now") { offline.stopBulk() }.buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
                .accessibilityIdentifier("wholeWorldProgress")
            }
        } header: {
            Text(app.world?.name ?? "This world")
        } footer: {
            Text(offline.keepsWholeWorld(world)
                 ? "Every page is downloaded and kept up to date, and new pages are added whenever the app checks. A page you remove comes back at the next check; turn this off to keep only the pages you choose. Stopping a download goes on at the next check."
                 : "Download every page of this world for reading offline, with comments and pictures, and keep it that way as pages are added.")
        }
    }
}

/// A downloaded page: its title and how current the saved copy is.
struct DownloadRow: View {
    let download: Download
    var working = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: download.type?.symbol ?? "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(download.title)
                if let s = download.shortDescription {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(download.gone || download.problem != nil ? Color.orange : Color.secondary)
            }
            Spacer(minLength: 0)
            if working { ProgressView() }
        }
        .accessibilityElement(children: .combine)
    }

    var status: String {
        if download.gone { return "No longer on the server. This is the copy saved \(download.savedAt.formatted(date: .abbreviated, time: .omitted))." }
        if let p = download.problem { return "Couldn't update: \(p)" }
        var parts = ["Checked \(download.checkedAt.formatted(.relative(presentation: .named)))", byteText(download.bytes)]
        if !download.view.isDefault { parts.append("saved through a set year or viewpoint") }
        return parts.joined(separator: " · ")
    }
}

/// A change to a comment that has not reached the server: what it is, and, when the server
/// refused it, why, with what can be done about it.
struct WaitingRow: View {
    let change: QueuedChange
    let offline: OfflineModel
    @Environment(Navigator.self) private var navigator
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(change.summary, systemImage: change.problem == nil ? "clock" : "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(change.problem == nil ? Color.secondary : Color.orange)
                Spacer()
                Text(change.queuedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                navigator.open(.pageComments(change.page, focus: change.kind == .add ? change.localID : change.comment))
            } label: {
                Text([change.pageTitle ?? change.page, change.sectionHeading].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            if let body = change.body, !body.isEmpty {
                Text(inlineMarkdown(body)).font(.subheadline).lineLimit(3)
            }
            if let problem = change.problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                HStack(spacing: 16) {
                    Button("Try again") { Task { await offline.retry(change.id) } }
                    if change.kind == .add, change.quote != nil {
                        Button("Send on the whole section") { Task { await offline.retry(change.id, wholeSection: true) } }
                    }
                    Spacer()
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button("Discard", systemImage: "trash", role: .destructive) { confirmDiscard = true }
        }
        .confirmationDialog("Discard this change?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { Task { await offline.discard(change.id) } }
        } message: {
            Text(change.kind == .add ? "The comment, and any reply you wrote to it, is deleted from this device." : "It is deleted from this device without being sent.")
        }
    }
}

/// A page's download button: download, the progress, or downloaded (a tap offers to remove it).
struct DownloadButton: View {
    let model: PageModel
    @State private var confirmRemove = false
    @State private var failure: APIError?

    var body: some View {
        if model.canDownload {
            Button {
                if model.download != nil {
                    confirmRemove = true
                } else {
                    Task { failure = await model.toggleDownload() }
                }
            } label: {
                if model.isDownloading {
                    ProgressView()
                } else {
                    Image(systemName: model.download != nil ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
            }
            .disabled(model.isDownloading || model.page.value == nil)
            .accessibilityLabel(model.download != nil ? "Downloaded" : "Download for offline reading")
            .accessibilityHint(model.download != nil ? "Removes the download" : "")
            .accessibilityIdentifier("downloadPage")
            .confirmationDialog("Remove this download?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove download", role: .destructive) { Task { await model.toggleDownload() } }
            } message: {
                Text("The page stays readable while it's in the cache, but it may not be there when you're offline.")
            }
            .alert("Couldn't download the page", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure?.message ?? "")
            }
        }
    }
}

/// Under a downloaded page's title: that it is downloaded, and how current the copy is.
struct DownloadNote: View {
    let download: Download

    var body: some View {
        if download.gone {
            Label("This page is no longer on the server. You're reading the copy saved \(download.savedAt.formatted(date: .abbreviated, time: .omitted)).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Downloaded · checked \(download.checkedAt.formatted(.relative(presentation: .named)))", systemImage: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("downloadNote")
        }
    }
}

/// A comment or reply written on this device and not sent yet: waiting, or refused with the
/// server's reason and what can be done.
struct QueuedNote: View {
    let mark: PageComment.QueueMark
    let offline: OfflineModel?

    var body: some View {
        if let problem = mark.problem {
            VStack(alignment: .leading, spacing: 4) {
                Label("Not sent: \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                if let offline {
                    HStack(spacing: 14) {
                        Button("Try again") { Task { await offline.retry(mark.id) } }
                        if mark.onPassage {
                            Button("Send on the whole section") { Task { await offline.retry(mark.id, wholeSection: true) } }
                        }
                        Button("Discard", role: .destructive) { Task { await offline.discard(mark.id) } }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                }
            }
        } else {
            Label("Waiting to send", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("waitingToSend")
        }
    }
}
