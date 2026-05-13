import Foundation

public struct SwitcherooAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var identityKey: String?
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString, name: String, identityKey: String? = nil, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.identityKey = identityKey
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public enum SwitcherooAccountWriteDisposition: Hashable, Sendable {
    case created
    case updatedExisting
    case skippedUnmatchedIdentity
}

public struct SwitcherooAccountWriteResult: Hashable, Sendable {
    public let disposition: SwitcherooAccountWriteDisposition
    public let account: SwitcherooAccount?

    public init(disposition: SwitcherooAccountWriteDisposition, account: SwitcherooAccount?) {
        self.disposition = disposition
        self.account = account
    }
}

public enum SwitcherooActiveSnapshotSyncDisposition: Hashable, Sendable {
    case updatedExisting
    case skippedNoIdentity
    case skippedUnmatchedIdentity
}

public struct SwitcherooActiveSnapshotSyncResult: Hashable, Sendable {
    public let disposition: SwitcherooActiveSnapshotSyncDisposition
    public let account: SwitcherooAccount?
    public let accessTokenExpiry: Date?

    public init(
        disposition: SwitcherooActiveSnapshotSyncDisposition,
        account: SwitcherooAccount?,
        accessTokenExpiry: Date?
    ) {
        self.disposition = disposition
        self.account = account
        self.accessTokenExpiry = accessTokenExpiry
    }

    public var requiresRelogin: Bool {
        disposition != .updatedExisting
    }
}

public enum SwitcherooAutoSyncDecision: Hashable, Sendable {
    case poll(interval: TimeInterval)
    case recheck(after: TimeInterval)
    case disabled(requiresRelogin: Bool)

    public var requiresRelogin: Bool {
        switch self {
        case .poll, .recheck:
            return false
        case .disabled(let requiresRelogin):
            return requiresRelogin
        }
    }
}

public enum SwitcherooAutoSyncPolicy {
    public static let refreshWindow: TimeInterval = 2 * 24 * 60 * 60 + 5 * 60
    public static let pollingInterval: TimeInterval = 15

    public static func decision(accessTokenExpiry: Date?, now: Date) -> SwitcherooAutoSyncDecision {
        guard let accessTokenExpiry else {
            return .disabled(requiresRelogin: true)
        }

        let secondsUntilWindow = accessTokenExpiry.timeIntervalSince(now) - refreshWindow
        if secondsUntilWindow <= 0 {
            return .poll(interval: pollingInterval)
        }

        return .recheck(after: secondsUntilWindow)
    }
}

public struct SwitcherooActiveAuthInfo: Sendable {
    public let identityKey: String?
    public let accessTokenExpiry: Date?

    public init(identityKey: String?, accessTokenExpiry: Date?) {
        self.identityKey = identityKey
        self.accessTokenExpiry = accessTokenExpiry
    }
}

public struct SwitcherooAccountMetadata: Hashable, Sendable {
    public var email: String?
    public var accessTokenExpiry: Date?

    public init(email: String? = nil, accessTokenExpiry: Date? = nil) {
        self.email = email
        self.accessTokenExpiry = accessTokenExpiry
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
