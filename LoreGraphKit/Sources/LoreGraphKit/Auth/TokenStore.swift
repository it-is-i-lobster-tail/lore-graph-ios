import Foundation
#if canImport(Security)
import Security
#endif

/// Where credentials are kept between launches.
public protocol TokenStore: Sendable {
    func load() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func delete() throws
}

/// Credentials in memory only (tests, previews, and "don't remember me").
public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Credentials?

    public init(_ value: Credentials? = nil) {
        self.value = value
    }

    public func load() throws -> Credentials? { lock.withLock { value } }
    public func save(_ credentials: Credentials) throws { lock.withLock { value = credentials } }
    public func delete() throws { lock.withLock { value = nil } }
}

#if canImport(Security)
/// The Keychain (F-1.4): a generic password readable only while the phone is unlocked, never
/// synced or backed up to another device.
public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let account: String

    public init(service: String = "net.loregraph.ios.credentials", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> Credentials? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return try JSONCoding.decoder.decode(Credentials.self, from: data)
    }

    public func save(_ credentials: Credentials) throws {
        let data = try JSONCoding.encoder.encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attributes) { _, new in new }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Hashable {
    public let status: OSStatus
}
#endif
