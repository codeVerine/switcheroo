import Foundation
import SwitcherooCore

public struct CodexProvider: AgentProvider {
    public let id: String = "codex"
    public let displayName: String = "Codex"

    public var defaultActiveAuthFilePath: String {
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("auth.json")
        }
        return "~/.codex/auth.json"
    }

    private let loginRunner: @Sendable (String) throws -> Void

    public init(loginRunner: @escaping @Sendable (String) throws -> Void) {
        self.loginRunner = loginRunner
    }

    public func prepareLogin(accountId: String, accountName: String, paths: SwitcherooPaths) throws -> PendingLogin {
        let homePath = try paths.loginHomeDirectory(providerId: id, accountId: accountId)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: homePath), withIntermediateDirectories: true)

        let authPath = (homePath as NSString).appendingPathComponent("auth.json")
        return PendingLogin(
            providerId: id,
            accountId: accountId,
            accountName: accountName,
            providerHomePath: homePath,
            expectedAuthFilePath: authPath
        )
    }

    public func launchLoginInteractive(pending: PendingLogin) throws {
        try loginRunner(pending.providerHomePath)
    }
}

