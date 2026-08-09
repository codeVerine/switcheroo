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

    public func destinationDocument(fromSourceAuthData sourceAuthData: Data, existingDestinationData: Data?) throws -> Data {
        guard !sourceAuthData.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth snapshot is empty")
        }
        return sourceAuthData
    }
}
