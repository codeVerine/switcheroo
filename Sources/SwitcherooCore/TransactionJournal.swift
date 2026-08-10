import Foundation

/// Durable record of an in-flight account switch transaction. Written to the
/// state directory (mode 0600) before any publication and cleared only after
/// every commit step completes; a leftover journal is reconciled at startup.
/// Pre-image bytes may contain credentials, so journal files are created with
/// user-only permissions and never appear in logs or error text.
struct TransactionJournal: Codable {
    struct Target: Codable, Sendable {
        var id: String
        var path: String
        var previous: Data?
        var expected: Data?
        var publicationStarted: Bool
        var publicationMarkerPresent: Bool

        init(id: String = "unknown", path: String, previous: Data?, expected: Data? = nil, publicationStarted: Bool? = nil) {
            self.id = id
            self.path = path
            self.previous = previous
            self.expected = expected
            self.publicationStarted = publicationStarted ?? (expected != nil)
            self.publicationMarkerPresent = true
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case path
            case previous
            case expected
            case publicationStarted
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown"
            path = try container.decode(String.self, forKey: .path)
            previous = try container.decodeIfPresent(Data.self, forKey: .previous)
            expected = try container.decodeIfPresent(Data.self, forKey: .expected)
            let marker = try container.decodeIfPresent(Bool.self, forKey: .publicationStarted)
            publicationStarted = marker ?? false
            publicationMarkerPresent = marker != nil
        }
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
