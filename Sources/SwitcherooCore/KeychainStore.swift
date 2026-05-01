import Foundation
import Security

public final class KeychainStore: @unchecked Sendable {
    private let service: String

    public init(service: String = "com.switcheroo.codex") {
        self.service = service
    }

    public func storeAuthBlob(_ data: Data, accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try updateAuthBlob(data, accountId: accountId)
            return
        }

        guard status == errSecSuccess else {
            throw SwitcherooError.keychainError(status: status, message: keychainMessage(prefix: "Keychain write failed", status: status))
        }
    }

    public func loadAuthBlob(accountId: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw SwitcherooError.keychainItemMissing
        }
        guard status == errSecSuccess else {
            throw SwitcherooError.keychainError(status: status, message: keychainMessage(prefix: "Keychain read failed", status: status))
        }
        guard let data = item as? Data else {
            throw SwitcherooError.keychainItemMissing
        }
        return data
    }

    public func deleteAuthBlob(accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SwitcherooError.keychainError(status: status, message: keychainMessage(prefix: "Keychain delete failed", status: status))
        }
    }

    private func updateAuthBlob(_ data: Data, accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountId,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else {
            throw SwitcherooError.keychainError(status: status, message: keychainMessage(prefix: "Keychain update failed", status: status))
        }
    }

    private func keychainMessage(prefix: String, status: OSStatus) -> String {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown"
        return "\(prefix): \(status) (\(msg))"
    }
}
