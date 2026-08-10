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

    public func validateExistingDestination(existingDestinationData: Data?, destinationPath: String) throws {
        // Whole-file target: any existing bytes are replaced wholesale.
    }

    public func writeDestination(credential: AuthTargetCredential?, sourceAuthData: Data, destinationPath: String, fileIO: SwitcherooFileIO) throws -> AuthTargetWriteResult {
        let previous = fileIO.fileExists(path: destinationPath) ? try fileIO.readFile(path: destinationPath) : nil
        if previous != sourceAuthData {
            try fileIO.writeFileAtomically(sourceAuthData, path: destinationPath, permissions: 0o600)
        }
        return AuthTargetWriteResult(previousData: previous, writtenData: sourceAuthData)
    }
}
