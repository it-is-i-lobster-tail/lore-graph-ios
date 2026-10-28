import Foundation

/// Small values kept between launches (UserDefaults in the app). Never tokens: those live in the
/// Keychain.
public protocol KeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? { lock.withLock { values[key] } }

    public func set(_ data: Data?, forKey key: String) { lock.withLock { values[key] = data } }
}

public struct UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    let defaults: UserDefaults

    public init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }

    public func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

extension KeyValueStore {
    func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func setValue<T: Encodable>(_ value: T?, forKey key: String) {
        set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
    }
}

/// The app's own settings (F-11.5).
public struct AppSettings: Codable, Hashable, Sendable {
    /// Ask for Face ID or the passcode when the app opens or comes back (F-1.5).
    public var requireUnlock: Bool = false
    /// The map's base map; nil picks the atlas when there is one.
    public var baseMap: BaseMap?

    public init(requireUnlock: Bool = false, baseMap: BaseMap? = nil) {
        self.requireUnlock = requireUnlock
        self.baseMap = baseMap
    }
}

/// Who the cache belongs to: the cache is kept per server, reader and ceiling.
public struct ReaderIdentity: Codable, Hashable, Sendable {
    public var server: URL
    public var id: String
    public var name: String?
    public var ceiling: Visibility

    public init(server: URL, id: String, name: String?, ceiling: Visibility) {
        self.server = server
        self.id = id
        self.name = name
        self.ceiling = ceiling
    }

    /// The cache folder's name.
    public var folder: String { String(Digest.sha256Hex("\(server.absoluteString)|\(id)|\(ceiling.rawValue)").prefix(24)) }
}

/// Where the reader was, per world: the view, recent pages and searches, the map's camera.
public struct ReadingState: Codable, Hashable, Sendable {
    public struct Camera: Codable, Hashable, Sendable {
        public var centre: LonLat
        public var zoom: Double
        public var layers: [String]?

        public init(centre: LonLat, zoom: Double, layers: [String]? = nil) {
            self.centre = centre
            self.zoom = zoom
            self.layers = layers
        }
    }

    public var world: String?
    /// Whether the reader picked a world (the picker shows at first launch when there are
    /// several, F-2.1).
    public var worldChosen: Bool?
    public var worlds: [World] = []
    public var views: [String: ViewState] = [:]
    public var recentPages: [String: [EntityCard]] = [:]
    public var recentSearches: [String] = []
    public var cameras: [String: Camera] = [:]

    public init() {}

    public static let recentLimit = 20
}
