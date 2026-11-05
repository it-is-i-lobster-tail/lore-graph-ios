import Foundation

/// A page kept on the phone for reading offline: its text, its comments and its images.
public struct Download: Codable, Hashable, Sendable, Identifiable {
    /// The page's id on the server.
    public var entityId: String
    /// The reference it was opened by (the address the screens read it at).
    public var ref: String
    public var world: String?
    /// The year, viewpoint and preview level it was read through; it is kept as it read then.
    public var view: ViewState
    public var title: String
    public var type: EntityType?
    public var shortDescription: String?
    /// When it was first downloaded.
    public var savedAt: Date
    /// When it was last checked against the server.
    public var checkedAt: Date
    /// The world's newest revision at that check: the page is stale once the world moves past it.
    public var mark: Int64?
    /// Every reference the page is read by (as opened, and its slug).
    public var refs: [String]
    /// The stored answers (the page and its comments, under each reference it is read by).
    public var keys: [String]
    /// The stored images, by address.
    public var media: [String]
    public var bytes: Int
    /// Why the last refresh failed (the server refused it); nil when it went through.
    public var problem: String?
    /// The server no longer shows the page to this reader (deleted, merged or hidden).
    public var gone: Bool

    public var id: String { Self.identity(world: world, entityId: entityId, view: view) }

    static func identity(world: String?, entityId: String, view: ViewState) -> String {
        let v = (try? JSONCoding.encoder.encode(view)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return "\(world ?? "")|\(entityId)|\(v)"
    }

    /// The card the recent lists and links use.
    public var card: EntityCard {
        EntityCard(ref: ref, id: entityId, title: title, type: type, shortDescription: shortDescription)
    }
}

/// The downloaded pages of one reader: answers and images kept until the reader removes them,
/// never evicted and kept apart from the cache (Clear cache leaves them; sign-out deletes them).
/// They live in Application Support, which iOS does not purge, are left out of device backups,
/// and are encrypted while the phone is locked, like the cache.
public actor DownloadStore {
    public let directory: URL
    let files: DiskCache
    let now: @Sendable () -> Date
    private var manifest: [Download]?
    private var whole: [String: ViewState]?

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        files = DiskCache(directory: directory.appendingPathComponent("files", isDirectory: true), limitBytes: Int.max / 2, now: now)
    }

    public var all: [Download] {
        load()
        return manifest ?? []
    }

    public func download(_ id: String) -> Download? { all.first { $0.id == id } }

    /// Whether an answer or image belongs to a downloaded page.
    public func holds(_ key: String) -> Bool {
        all.contains { $0.keys.contains(key) || $0.media.contains(key) }
    }

    public func entry(for key: String) async -> CacheEntry? {
        guard holds(key) else { return nil }
        return await files.entry(for: key)
    }

    /// A stored file, whether or not a page's record names it yet (while a download is saved).
    func file(_ key: String) async -> CacheEntry? { await files.entry(for: key) }

    /// Keeps an answer or image for a downloaded page (the page's record says which).
    public func store(_ data: Data, for key: String, mark: Int64?) async {
        await files.store(data, for: key, mark: mark)
    }

    public func restamp(_ key: String, mark: Int64?) async {
        await files.restamp(key, mark: mark)
    }

    /// Records a page as downloaded (or its new state after a refresh). Files the page no longer
    /// uses, and no other page uses, are deleted.
    public func save(_ d: Download) async {
        load()
        let before = manifest?.first { $0.id == d.id }
        var list = manifest ?? []
        list.removeAll { $0.id == d.id }
        list.append(d)
        manifest = list
        persist()
        if let before { await dropUnused(Set(before.keys + before.media)) }
    }

    public func remove(_ id: String) async {
        load()
        guard let gone = manifest?.first(where: { $0.id == id }) else { return }
        manifest?.removeAll { $0.id == id }
        persist()
        await dropUnused(Set(gone.keys + gone.media))
    }

    /// The worlds kept downloaded whole (by world key, "" for none), with the view they are read
    /// through: every page, and new ones as they appear.
    public var wholeWorlds: [String: ViewState] {
        if whole == nil {
            whole = (try? Data(contentsOf: wholeURL)).flatMap { try? JSONDecoder().decode([String: ViewState].self, from: $0) } ?? [:]
        }
        return whole ?? [:]
    }

    /// Keeps a world downloaded whole through a view, or stops (nil).
    public func setWhole(world: String?, view: ViewState?) {
        var w = wholeWorlds
        w[world ?? ""] = view
        whole = w
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        if let data = try? JSONEncoder().encode(w) { try? data.write(to: wholeURL, options: .atomic) }
    }

    public func removeAll() async {
        manifest = []
        whole = [:]
        await files.clear()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The space the downloads take on the phone (an image shared by pages counts once).
    public var totalBytes: Int {
        get async { await files.totalBytes }
    }

    private func dropUnused(_ keys: Set<String>) async {
        let used = Set(all.flatMap { $0.keys + $0.media })
        for key in keys where !used.contains(key) { await files.remove(key) }
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var wholeURL: URL { directory.appendingPathComponent("whole-worlds.json") }

    private func load() {
        guard manifest == nil else { return }
        manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([Download].self, from: $0) } ?? []
    }

    private func persist() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
        guard let data = try? JSONEncoder().encode(manifest ?? []) else { return }
        #if os(iOS)
        try? data.write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: manifestURL, options: .atomic)
        #endif
    }

    /// Lore can be restricted or designer-only: it stays on this phone, not in its backups.
    static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        #endif
    }
}
