import Foundation

// Auth-target adapters let Switcheroo mirror the selected Codex account into
// every destination auth file through one shared switch orchestration. Codex
// itself is an adapter (whole-file replacement of the active auth.json); Pi is
// another (section upsert of openai-codex). Orchestration in SwitcherooEngine
// stays target-agnostic: adapters own identity, destination resolution,
// source validation/conversion, and destination-specific preservation or
// replacement semantics; the engine owns sequencing, atomic writes, and rollback.

public protocol AuthTargetAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Resolve the destination auth file path for a switch against the given
    /// provider state. Targets whose location is provider-independent (Pi)
    /// ignore the argument; whole-file targets (Codex) honor provider-level
    /// path overrides.
    func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String

    /// Produce the complete destination document bytes for the source Codex
    /// auth snapshot, applying this target's preservation/replacement semantics
    /// against the existing destination data (`nil` when the destination file
    /// is absent). Whole-file targets replace the document; section targets
    /// replace only their key and preserve every unrelated top-level entry.
    ///
    /// Throws AuthTargetSyncError.unsupportedSource when the source snapshot
    /// cannot be validated or converted, and
    /// AuthTargetSyncError.malformedDestination when the existing destination
    /// document cannot be parsed.
    func destinationDocument(fromSourceAuthData sourceAuthData: Data, existingDestinationData: Data?) throws -> Data
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

/// Shared section-upsert merge for adapters that replace one top-level key of
/// the destination document and preserve every unrelated entry (Pi).
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
