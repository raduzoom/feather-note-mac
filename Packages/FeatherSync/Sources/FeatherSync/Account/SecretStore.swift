import Foundation
import Security

/// Where the session token lives. Never defaults or files.
public protocol SecretStore: Sendable {
    func token(for account: String) throws -> String?
    func setToken(_ token: String?, for account: String) throws
}

/// The session token as a generic password, on this Mac only (never synced through iCloud Keychain).
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "app.feathernote.FeatherNote.session") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    public func token(for account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String?, for account: String) throws {
        guard let token else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
            return
        }
        let data = Data(token.utf8)
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }
}

public struct KeychainFailure: Error, Equatable { public var status: OSStatus }

/// For tests and isolated runs.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    public init() {}
    public func token(for account: String) throws -> String? { lock.withLock { tokens[account] } }
    public func setToken(_ token: String?, for account: String) throws { lock.withLock { tokens[account] = token } }
}
