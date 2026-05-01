import Foundation

public enum SwitcherooError: LocalizedError, Sendable {
    case configUnavailable
    case providerNotFound(providerId: String)
    case accountNotFound
    case noActiveAccount

    case missingAuthFile(path: String)
    case invalidAuthFile(path: String)

    case secureStoreItemMissing
    case secureStoreFailure(message: String)

    case providerLoginFailed(providerId: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .configUnavailable:
            return "Could not locate Switcheroo config."
        case .providerNotFound(let providerId):
            return "Provider not found: \(providerId)."
        case .accountNotFound:
            return "Account not found."
        case .noActiveAccount:
            return "No active account."
        case .missingAuthFile(let path):
            return "Missing auth file at \(path)."
        case .invalidAuthFile(let path):
            return "Invalid auth file at \(path)."
        case .secureStoreItemMissing:
            return "Secure store item missing."
        case .secureStoreFailure(let message):
            return message
        case .providerLoginFailed(let providerId, let message):
            return "\(providerId) login failed: \(message)"
        }
    }
}
