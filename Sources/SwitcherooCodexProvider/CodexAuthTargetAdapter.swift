import Foundation
import SwitcherooCore

/// Primary auth target: atomically replaces the complete active Codex auth file
/// with the selected account snapshot, byte for byte. The snapshot stays an
/// opaque blob; the only validation is that it is non-empty.
public struct CodexAuthTargetAdapter: AuthTargetAdapter {
    public let id = "codex"
    public let displayName = "Codex"

    private let defaultAuthFilePath: String

    public init(defaultAuthFilePath: String) {
        self.defaultAuthFilePath = defaultAuthFilePath
    }

    public func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String {
        providerState.activeAuthFilePathOverride ?? defaultAuthFilePath
    }

    public func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential? {
        guard !sourceAuthData.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth snapshot is empty")
        }
        return nil
    }

    public func validateExistingDestination(existingDestinationData: Data?) throws {
        // Whole-file target: any existing bytes are replaced wholesale.
    }

    public func writeDestination(credential: AuthTargetCredential?, sourceAuthData: Data, destinationPath: String, fileIO: SwitcherooFileIO) throws -> Data {
        // Skip the write when the destination already holds exactly the source
        // bytes (e.g. importing the account that is already active).
        if fileIO.fileExists(path: destinationPath),
           let existing = try? fileIO.readFile(path: destinationPath),
           existing == sourceAuthData {
            return sourceAuthData
        }
        try fileIO.writeFileAtomically(sourceAuthData, path: destinationPath, permissions: 0o600)
        return sourceAuthData
    }
}
