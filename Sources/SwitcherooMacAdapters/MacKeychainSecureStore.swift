import Foundation
import Security
import SwitcherooCore

public final class MacKeychainSecureStore: @unchecked Sendable, SwitcherooSecureStoring {
    private let service: String

    public init(service: String = "com.switcheroo.codex") {
        self.service = service
    }

    public func store(_ data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try update(data, key: key)
            return
        }

        guard status == errSecSuccess else {
            throw SwitcherooError.secureStoreFailure(message: keychainMessage(prefix: "Keychain write failed", status: status))
        }
    }

    public func load(key: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw SwitcherooError.secureStoreItemMissing
        }
        guard status == errSecSuccess else {
            throw SwitcherooError.secureStoreFailure(message: keychainMessage(prefix: "Keychain read failed", status: status))
        }
        guard let data = item as? Data else {
            throw SwitcherooError.secureStoreItemMissing
        }
        return data
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SwitcherooError.secureStoreFailure(message: keychainMessage(prefix: "Keychain delete failed", status: status))
        }
    }

    private func update(_ data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else {
            throw SwitcherooError.secureStoreFailure(message: keychainMessage(prefix: "Keychain update failed", status: status))
        }
    }

    private func keychainMessage(prefix: String, status: OSStatus) -> String {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
        return "\(prefix): \(status) (\(msg))"
    }
}

