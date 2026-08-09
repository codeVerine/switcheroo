import Foundation

// Auth-target adapters let Switcheroo mirror the active Codex credential into
// other harness auth files (Pi is the first built-in target). Orchestration in
// SwitcherooEngine stays target-agnostic: adapters own identity, conversion,
// destination resolution, and document merging; the engine owns sequencing and
// atomic writes.

public protocol AuthTargetAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Path to the target's auth file, which receives the converted credential.
    var destinationAuthFilePath: String { get }

    /// Convert the active Codex auth snapshot into a credential for this target.
    /// Throws AuthTargetSyncError.unsupportedSource when the snapshot cannot be
    /// converted (malformed, incomplete, or unsupported source credentials).
    func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential

    /// Produce the full destination document bytes with only `credential.destinationKey`
    /// replaced, preserving every unrelated top-level entry. `existingDestinationData`
    /// is nil when the destination auth file does not exist yet. Throws
    /// AuthTargetSyncError.malformedDestination when the existing document cannot be read.
    func destinationDocument(byMerging credential: AuthTargetCredential, existingDestinationData: Data?) throws -> Data
}

/// A converted credential destined for one top-level key of the target auth document.
public struct AuthTargetCredential: Sendable, Equatable {
    public let destinationKey: String
    public let jsonValue: AuthTargetJSON

    public init(destinationKey: String, jsonValue: AuthTargetJSON) {
        self.destinationKey = destinationKey
        self.jsonValue = jsonValue
    }
}

/// Type-erased JSON value used to build target credentials and merge documents.
public enum AuthTargetJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AuthTargetJSON])
    case object([String: AuthTargetJSON])
}

extension AuthTargetJSON: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([AuthTargetJSON].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: AuthTargetJSON].self) {
            self = .object(object)
        } else {
            throw DecodingError.typeMismatch(
                AuthTargetJSON.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}

public extension AuthTargetAdapter {
    /// Default merge: replace only `credential.destinationKey` in the existing
    /// top-level JSON object, keeping every other entry. An absent destination
    /// document yields a single-key object.
    func destinationDocument(byMerging credential: AuthTargetCredential, existingDestinationData: Data?) throws -> Data {
        try AuthTargetDocument.merging(credential, into: existingDestinationData, targetId: id, destinationPath: destinationAuthFilePath)
    }
}

/// Shared destination-document merge used by the default adapter implementation.
/// Adapters (or test doubles) may reuse it instead of reimplementing preservation
/// of unrelated top-level entries.
public enum AuthTargetDocument {
    public static func merging(
        _ credential: AuthTargetCredential,
        into existingDestinationData: Data?,
        targetId: String,
        destinationPath: String
    ) throws -> Data {
        var document: [String: AuthTargetJSON]
        if let existingDestinationData {
            guard !existingDestinationData.isEmpty else {
                throw AuthTargetSyncError.malformedDestination(targetId: targetId, path: destinationPath)
            }
            do {
                document = try JSONDecoder().decode([String: AuthTargetJSON].self, from: existingDestinationData)
            } catch {
                throw AuthTargetSyncError.malformedDestination(targetId: targetId, path: destinationPath)
            }
        } else {
            document = [:]
        }

        document[credential.destinationKey] = credential.jsonValue

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }
}
