import Foundation

/// Failures raised while synchronizing the active Codex credential into
/// auth-target files (Pi, ...). Messages are constructed from fixed strings
/// and file paths only; credential contents never appear in error text.
public enum AuthTargetSyncError: LocalizedError, Sendable {
    case unsupportedSource(targetId: String, reason: String)
    case malformedDestination(targetId: String, path: String)
    case destinationReadFailed(targetId: String, path: String, reason: String)
    case destinationWriteFailed(targetId: String, path: String, reason: String)
    case rollbackIncomplete(message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource(let targetId, let reason):
            return "Could not sync \(targetId): \(reason)."
        case .malformedDestination(let targetId, let path):
            return "Could not sync \(targetId): auth file at \(path) is not a valid JSON object."
        case .destinationReadFailed(let targetId, let path, let reason):
            return "Could not sync \(targetId): could not read \(path) (\(reason))."
        case .destinationWriteFailed(let targetId, let path, let reason):
            return "Could not sync \(targetId): could not write \(path) (\(reason))."
        case .rollbackIncomplete(let message):
            return message
        }
    }
}

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
