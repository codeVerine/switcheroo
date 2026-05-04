import Foundation
import Security
import SwitcherooCore

struct MacKeychainClient: @unchecked Sendable {
    var addItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    var updateItem: (CFDictionary, CFDictionary) -> OSStatus
    var deleteItem: (CFDictionary) -> OSStatus
    var errorMessage: (OSStatus) -> String?

    static let live = MacKeychainClient(
        addItem: { SecItemAdd($0, $1) },
        copyMatching: { SecItemCopyMatching($0, $1) },
        updateItem: { SecItemUpdate($0, $1) },
        deleteItem: { SecItemDelete($0) },
        errorMessage: { status in SecCopyErrorMessageString(status, nil) as String? }
    )
}

public final class MacKeychainSecureStore: @unchecked Sendable, SwitcherooSecureStoring {
    private let service: String
    private let client: MacKeychainClient

    public init(service: String = "com.switcheroo.codex") {
        self.service = service
        self.client = .live
    }

    init(service: String, client: MacKeychainClient) {
        self.service = service
        self.client = client
    }

    public func store(_ data: Data, key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        let status = client.addItem(query as CFDictionary, nil)
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
        let status = client.copyMatching(query as CFDictionary, &item)
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
        let status = client.deleteItem(query as CFDictionary)
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
        let status = client.updateItem(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else {
            throw SwitcherooError.secureStoreFailure(message: keychainMessage(prefix: "Keychain update failed", status: status))
        }
    }

    private func keychainMessage(prefix: String, status: OSStatus) -> String {
        let msg = client.errorMessage(status) ?? "Unknown"
        return "\(prefix): \(status) (\(msg))"
    }
}
