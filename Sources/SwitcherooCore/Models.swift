import Foundation

public struct SwitcherooAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString, name: String, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct SwitcherooProvider: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var activeAccountId: String?
    public var accounts: [SwitcherooAccount]
    public var activeAuthFilePathOverride: String?

    public init(id: String, activeAccountId: String? = nil, accounts: [SwitcherooAccount] = [], activeAuthFilePathOverride: String? = nil) {
        self.id = id
        self.activeAccountId = activeAccountId
        self.accounts = accounts
        self.activeAuthFilePathOverride = activeAuthFilePathOverride
    }
}

public struct SwitcherooConfig: Codable, Sendable {
    public var schemaVersion: Int
    public var defaultProviderId: String?
    public var providers: [SwitcherooProvider]

    public init(schemaVersion: Int = 1, defaultProviderId: String? = nil, providers: [SwitcherooProvider] = []) {
        self.schemaVersion = schemaVersion
        self.defaultProviderId = defaultProviderId
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case defaultProviderId
        case providers

        // Legacy v1 Codex-only config
        case activeAccountId
        case accounts
        case codexAuthPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        self.defaultProviderId = try? c.decode(String.self, forKey: .defaultProviderId)
        self.providers = (try? c.decode([SwitcherooProvider].self, forKey: .providers)) ?? []

        if !providers.isEmpty {
            return
        }

        // Best-effort import of the old Codex-only schema.
        let legacyAccounts = (try? c.decode([SwitcherooAccount].self, forKey: .accounts)) ?? []
        let legacyActiveId = try? c.decode(String.self, forKey: .activeAccountId)
        let legacyAuthPath = try? c.decode(String.self, forKey: .codexAuthPath)

        if !legacyAccounts.isEmpty || legacyActiveId != nil || legacyAuthPath != nil {
            self.defaultProviderId = self.defaultProviderId ?? "codex"
            self.providers = [
                SwitcherooProvider(
                    id: "codex",
                    activeAccountId: legacyActiveId,
                    accounts: legacyAccounts,
                    activeAuthFilePathOverride: legacyAuthPath
                ),
            ]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encodeIfPresent(defaultProviderId, forKey: .defaultProviderId)
        try c.encode(providers, forKey: .providers)
    }
}

public struct PendingLogin: Hashable, Sendable {
    public let providerId: String
    public let accountId: String
    public let accountName: String
    public let providerHomePath: String
    public let expectedAuthFilePath: String

    public init(providerId: String, accountId: String, accountName: String, providerHomePath: String, expectedAuthFilePath: String) {
        self.providerId = providerId
        self.accountId = accountId
        self.accountName = accountName
        self.providerHomePath = providerHomePath
        self.expectedAuthFilePath = expectedAuthFilePath
    }
}
