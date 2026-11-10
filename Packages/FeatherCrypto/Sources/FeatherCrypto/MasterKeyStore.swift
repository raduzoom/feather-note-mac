import Foundation
import Security

/// Where the unwrapped master key lives while signed in. Cleared on sign-out.
public protocol MasterKeyStore: Sendable {
    func save(_ masterKey: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
}

public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
}

/// The master key as a generic password, on this Mac only (never synced through iCloud Keychain).
///
/// TODO(phase-10): add `kSecUseDataProtectionKeychain` once the app is signed with a Developer ID; it needs a
/// keychain-access-groups entitlement that ad-hoc signing can't grant.
public struct KeychainMasterKeyStore: MasterKeyStore {
    public let service: String

    public init(service: String = "app.feathermark.FeatherMark.master-key") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func save(_ masterKey: Data, account: String) throws {
        try InvalidArgument.check(masterKey, "masterKey", 32)
        var add = query(account)
        add[kSecValueData as String] = masterKey
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: masterKey] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func load(account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// For tests of code that signs in and out (FeatherSync).
public final class InMemoryMasterKeyStore: MasterKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    public init() {}

    public func save(_ masterKey: Data, account: String) throws {
        try InvalidArgument.check(masterKey, "masterKey", 32)
        lock.withLock { keys[account] = masterKey }
    }

    public func load(account: String) throws -> Data? { lock.withLock { keys[account] } }

    public func delete(account: String) throws { _ = lock.withLock { keys.removeValue(forKey: account) } }
}
