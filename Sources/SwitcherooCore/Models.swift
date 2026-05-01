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

public struct SwitcherooConfig: Codable, Sendable {
    public var schemaVersion: Int
    public var activeAccountId: String?
    public var accounts: [SwitcherooAccount]
    public var codexAuthPath: String?

    public init(schemaVersion: Int = 1, activeAccountId: String? = nil, accounts: [SwitcherooAccount] = [], codexAuthPath: String? = nil) {
        self.schemaVersion = schemaVersion
        self.activeAccountId = activeAccountId
        self.accounts = accounts
        self.codexAuthPath = codexAuthPath
    }
}

public struct PendingLogin: Hashable, Sendable {
    public let accountId: String
    public let accountName: String
    public let codexHomePath: String
    public let expectedAuthJSONPath: String

    public init(accountId: String, accountName: String, codexHomePath: String, expectedAuthJSONPath: String) {
        self.accountId = accountId
        self.accountName = accountName
        self.codexHomePath = codexHomePath
        self.expectedAuthJSONPath = expectedAuthJSONPath
    }
}
