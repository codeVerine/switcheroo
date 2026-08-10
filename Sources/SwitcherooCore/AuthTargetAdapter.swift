import Foundation

// Auth-target adapters let Switcheroo mirror the selected Codex account into
// every destination auth file through one shared switch transaction. Codex
// itself is an adapter (whole-file replacement of the active auth.json); Pi is
// another (locked section upsert of openai-codex). Orchestration in
// SwitcherooEngine stays target-agnostic: adapters own identity, destination
// resolution, source validation/conversion, and destination-specific
// preservation or replacement semantics; the engine owns transaction
// serialization, the crash journal, and atomic rollback.

public protocol AuthTargetAdapter: Sendable {
    var id: String { get }
    var displayName: String { get }

    /// Resolve the destination auth file path for a switch against the given
    /// provider state. Targets whose location is provider-independent (Pi)
    /// ignore the argument; whole-file targets (Codex) honor provider-level
    /// path overrides.
    func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String

    /// Fail-fast validation/conversion of the source Codex snapshot. Returns the
    /// credential to publish, or nil when this target has nothing to publish
    /// (whole-file targets). Throws AuthTargetSyncError.unsupportedSource when
    /// the snapshot is malformed, incomplete, or unsupported.
    func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential?

    /// Validate the existing destination document without modifying it. Throws
    /// AuthTargetSyncError.malformedDestination when the document cannot be
    /// parsed. Runs during preparation so deterministic destination errors fail
    /// the transaction before any publication. `existingDestinationData` is nil
    /// when the destination file does not exist. `destinationPath` is the
    /// engine's canonicalized path, so errors reference the file actually read.
    func validateExistingDestination(existingDestinationData: Data?, destinationPath: String) throws

    /// Publish the credential to the destination under the engine's transaction.
    /// Whole-file targets replace the destination (skipping the write when it
    /// already holds exactly the source bytes); section targets re-read under
    /// their own lock and merge only their section, preserving every unrelated
    /// top-level entry. Returns the lock-time pre-image and the bytes actually
    /// written.
    func writeDestination(credential: AuthTargetCredential?, sourceAuthData: Data, destinationPath: String, fileIO: SwitcherooFileIO) throws -> AuthTargetWriteResult

    func restoreDestination(previous: Data?, expectedCurrent: Data, destinationPath: String, fileIO: SwitcherooFileIO) -> Bool
}

public struct AuthTargetWriteResult: Sendable {
    public let previousData: Data?
    public let writtenData: Data

    public init(previousData: Data?, writtenData: Data) {
        self.previousData = previousData
        self.writtenData = writtenData
    }
}

public struct AuthTargetPublicationError: Error, Sendable {
    public let result: AuthTargetWriteResult
    public let reason: String

    public init(result: AuthTargetWriteResult, reason: String) {
        self.result = result
        self.reason = reason
    }
}

public extension AuthTargetAdapter {
    func restoreDestination(previous: Data?, expectedCurrent: Data, destinationPath: String, fileIO: SwitcherooFileIO) -> Bool {
        do {
            return try fileIO.withExclusiveLock(path: "\(destinationPath).lock") {
                guard fileIO.fileExists(path: destinationPath) else {
                    return previous == nil
                }
                let current = try fileIO.readFile(path: destinationPath)
                if let previous, current == previous { return true }
                guard current == expectedCurrent else { return false }
                if let previous {
                    try fileIO.writeFileAtomically(previous, path: destinationPath, permissions: 0o600)
                } else {
                    try fileIO.removeItem(path: destinationPath)
                }
                return true
            }
        } catch {
            return false
        }
    }
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
/// Integers are preserved exactly (Int64/UInt64 before Double), so unrelated
/// numeric values in preserved documents never lose precision.
public enum AuthTargetJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
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
        } else if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else if let unsigned = try? container.decode(UInt64.self) {
            self = .unsigned(unsigned)
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
        case .integer(let value):
            try container.encode(value)
        case .unsigned(let value):
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
