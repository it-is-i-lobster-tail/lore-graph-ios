import Foundation

/// One stored answer: its bytes, when it was fetched, and the freshness mark it was current at.
public struct CacheEntry: Sendable, Hashable {
    public var data: Data
    public var storedAt: Date
    /// The world's newest revision id (lore) or the map version (map) at fetch time.
    public var mark: Int64?
}

/// Answers kept on disk so pages open at once and stay readable offline (F-11.4). One directory
/// per server, reader and ceiling, so one reader never sees another's cache; least recently
/// used entries are dropped past the size limit. iOS encrypts the files while the phone is
/// locked (the app's default data protection).
public actor DiskCache {
    struct Meta: Codable {
        var key: String
        var storedAt: Date
        var mark: Int64?
        var size: Int
    }

    public let directory: URL
    public let limitBytes: Int
    let now: @Sendable () -> Date
    private var index: [String: (meta: Meta, used: Date)]?
    private let fm = FileManager.default

    public init(directory: URL, limitBytes: Int, now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.limitBytes = limitBytes
        self.now = now
    }

    public func entry(for key: String) -> CacheEntry? {
        loadIndex()
        guard let found = index?[key] else { return nil }
        guard let data = try? Data(contentsOf: bodyURL(key)) else {
            remove(key)
            return nil
        }
        index?[key]?.used = now()
        return CacheEntry(data: data, storedAt: found.meta.storedAt, mark: found.meta.mark)
    }

    public func store(_ data: Data, for key: String, mark: Int64?) {
        loadIndex()
        let meta = Meta(key: key, storedAt: now(), mark: mark, size: data.count)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try write(data, to: bodyURL(key))
            try write(try JSONEncoder().encode(meta), to: metaURL(key))
            index?[key] = (meta, now())
            evict()
        } catch {
            // a cache that cannot write is only a slower app
        }
    }

    /// Marks an entry current at a newer mark without rewriting its bytes.
    public func restamp(_ key: String, mark: Int64?) {
        loadIndex()
        guard var found = index?[key] else { return }
        found.meta.mark = mark
        found.meta.storedAt = now()
        found.used = now()
        index?[key] = found
        try? write(try JSONEncoder().encode(found.meta), to: metaURL(key))
    }

    public func remove(_ key: String) {
        try? fm.removeItem(at: bodyURL(key))
        try? fm.removeItem(at: metaURL(key))
        index?[key] = nil
    }

    /// Settings' Clear cache, and sign-out.
    public func clear() {
        try? fm.removeItem(at: directory)
        index = [:]
    }

    public var totalBytes: Int {
        loadIndex()
        return index?.values.reduce(0) { $0 + $1.meta.size } ?? 0
    }

    public var count: Int {
        loadIndex()
        return index?.count ?? 0
    }

    private func loadIndex() {
        guard index == nil else { return }
        var out: [String: (meta: Meta, used: Date)] = [:]
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "meta" {
            guard let data = try? Data(contentsOf: file), let meta = try? decoder.decode(Meta.self, from: data) else {
                try? fm.removeItem(at: file)
                continue
            }
            out[meta.key] = (meta, meta.storedAt)
        }
        index = out
    }

    private func evict() {
        guard var idx = index else { return }
        var total = idx.values.reduce(0) { $0 + $1.meta.size }
        guard total > limitBytes else { return }
        for (key, value) in idx.sorted(by: { $0.value.used < $1.value.used }) {
            if total <= limitBytes * 9 / 10 { break }
            try? fm.removeItem(at: bodyURL(key))
            try? fm.removeItem(at: metaURL(key))
            idx[key] = nil
            total -= value.meta.size
        }
        index = idx
    }

    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func name(_ key: String) -> String { Digest.sha256Hex(key) }
    private func bodyURL(_ key: String) -> URL { directory.appendingPathComponent(name(key) + ".body") }
    private func metaURL(_ key: String) -> URL { directory.appendingPathComponent(name(key) + ".meta") }
}
