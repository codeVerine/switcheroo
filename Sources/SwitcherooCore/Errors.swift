import Foundation
import Security

public enum SwitcherooError: LocalizedError {
    case configDirectoryUnavailable
    case noAccountsConfigured
    case accountNotFound
    case noActiveAccount
    case missingCodexAuthFile(path: String)
    case invalidCodexAuthFile(path: String)
    case keychainItemMissing
    case keychainError(status: OSStatus, message: String)
    case codexLoginFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .configDirectoryUnavailable:
            return "Could not locate Application Support directory."
        case .noAccountsConfigured:
            return "No accounts configured."
        case .accountNotFound:
            return "Account not found."
        case .noActiveAccount:
            return "No active account."
        case .missingCodexAuthFile(let path):
            return "Missing Codex auth file at \(path)."
        case .invalidCodexAuthFile(let path):
            return "Invalid Codex auth file at \(path)."
        case .keychainItemMissing:
            return "Keychain item missing."
        case .keychainError(_, let message):
            return message
        case .codexLoginFailed(let exitCode, let stderr):
            return "Codex login failed (exit \(exitCode)): \(stderr)"
        }
    }
}
