import Foundation

/// Durable record of an in-flight account switch transaction. Written to the
/// state directory (mode 0600) before any publication and cleared only after
/// every commit step completes; a leftover journal is reconciled at startup.
/// Pre-image bytes may contain credentials, so journal files are created with
/// user-only permissions and never appear in logs or error text.
struct TransactionJournal: Codable {
    struct Target: Codable, Sendable {
        var path: String
        var previous: Data?
    }

    struct KeychainChange: Codable, Sendable {
        var op: String
        var key: String
        var previous: Data?
    }

    var txid: String
    var createdAt: Date
    var configCommitted: Bool
    var previousConfig: SwitcherooConfig
    var targets: [Target]
    var keychainChanges: [KeychainChange]
}
