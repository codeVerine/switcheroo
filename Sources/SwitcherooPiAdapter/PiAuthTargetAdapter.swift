import Foundation
import SwitcherooCore

/// Mirrors the active Codex credential into Pi's `openai-codex` OAuth credential.
///
/// Schema (verified against Pi 0.84.1, `@earendil-works/pi-coding-agent`):
/// Pi stores one credential per provider in `~/.pi/agent/auth.json` (or
/// `$PI_CODING_AGENT_DIR/auth.json`), a JSON object keyed by provider id. The
/// `openai-codex` credential is:
///
///     {
///       "type": "oauth",
///       "access": "<access token JWT>",
///       "refresh": "<refresh token JWT>",
///       "expires": <epoch milliseconds>,
///       "accountId": "<chatgpt_account_id from the access token>"
///     }
///
/// Pi derives `chatgpt_account_id` from the access token itself, so the
/// conversion requires that claim in the access token and rejects conflicting
/// id-token or `tokens.account_id` values. Conversion is in-memory only;
/// Switcheroo never persists parsed fields, and inactive Codex snapshots
/// remain opaque blobs in Keychain.
///
/// Publication is a locked provider-scoped update using Pi's own lock protocol
/// (an exclusive `auth.json.lock` directory with mtime-based staleness, as
/// `proper-lockfile` uses): acquire, re-read, validate, merge only
/// `openai-codex`, write, release.
public struct PiAuthTargetAdapter: AuthTargetAdapter {
    public let id = "pi"
    public let displayName = "Pi"

    /// Pi's auth file location does not depend on the Codex provider state.
    public func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String {
        resolvedDestinationAuthFilePath
    }

    public func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential? {
        guard let tokens = decodeTokens(from: sourceAuthData) else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth is not a Codex auth.json")
        }

        guard let access = tokens.access_token, !access.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth has no access token")
        }
        guard let refresh = tokens.refresh_token, !refresh.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth has no refresh token")
        }
        guard let summary = CodexAuthParsing.summarize(authJSONData: sourceAuthData) else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth identity could not be derived")
        }
        guard let expiry = summary.accessTokenExpiry else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth access token has no expiry")
        }
        let expiryMilliseconds = expiry.timeIntervalSince1970 * 1000
        guard expiryMilliseconds.isFinite,
              expiryMilliseconds >= Double(Int64.min),
              expiryMilliseconds < Double(Int64.max) else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth access token expiry is out of range")
        }
        // Pi reads chatgpt_account_id from the access token; a credential whose
        // access token lacks the claim is unusable in Pi.
        guard let accountId = summary.accessTokenChatgptAccountId, !accountId.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth access token has no chatgpt_account_id claim")
        }
        if let idTokenAccountId = summary.chatgptAccountId, idTokenAccountId != accountId {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth has conflicting account ids")
        }
        if let codexAccountId = summary.accountId, codexAccountId != accountId {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth has conflicting account ids")
        }

        return AuthTargetCredential(
            destinationKey: "openai-codex",
            jsonValue: .object([
                "type": .string("oauth"),
                "access": .string(access),
                "refresh": .string(refresh),
                "expires": .integer(Int64(expiryMilliseconds)),
                "accountId": .string(accountId),
            ])
        )
    }

    public func validateExistingDestination(existingDestinationData: Data?, destinationPath: String) throws {
        _ = try parseDocument(existingDestinationData, destinationPath: destinationPath)
    }

    public func writeDestination(credential: AuthTargetCredential?, sourceAuthData: Data, destinationPath: String, fileIO: SwitcherooFileIO) throws -> AuthTargetWriteResult {
        guard let credential else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "missing converted credential")
        }

        let lock = try PiAuthFileLock.acquire(path: destinationPath, fileIO: fileIO)
        defer { lock.release() }

        // Re-read and re-validate under the lock so a concurrent Pi update
        // (refresh or provider login) is never overwritten.
        let existing: Data?
        if fileIO.fileExists(path: destinationPath) {
            existing = try fileIO.readFile(path: destinationPath)
        } else {
            existing = nil
        }
        _ = try parseDocument(existing, destinationPath: destinationPath)

        let merged = try AuthTargetDocument.merging(credential, into: existing, targetId: id, destinationPath: destinationPath)
        do {
            try fileIO.writeFileAtomically(merged, path: destinationPath, permissions: 0o600)
        } catch {
            throw AuthTargetPublicationError(
                result: AuthTargetWriteResult(previousData: existing, writtenData: merged),
                reason: error.localizedDescription
            )
        }
        return AuthTargetWriteResult(previousData: existing, writtenData: merged)
    }

    public func restoreDestination(previous: Data?, expectedCurrent: Data, destinationPath: String, quarantinePath: String?, fileIO: SwitcherooFileIO) -> Bool {
        guard let lock = try? PiAuthFileLock.acquire(path: destinationPath, fileIO: fileIO) else {
            return false
        }
        defer { lock.release() }

        guard fileIO.fileExists(path: destinationPath) else {
            return previous == nil
        }
        guard let current = try? fileIO.readFile(path: destinationPath) else {
            return false
        }
        if let previous, current == previous { return true }
        guard current == expectedCurrent else { return false }
        do {
            if let previous {
                try fileIO.writeFileAtomically(previous, path: destinationPath, permissions: 0o600)
            } else {
                try fileIO.removeItem(path: destinationPath)
            }
            return true
        } catch {
            return false
        }
    }

    public init() {}

    // MARK: - Internals

    private struct CodexTokens: Decodable {
        struct Tokens: Decodable {
            var access_token: String?
            var refresh_token: String?
        }

        var tokens: Tokens?
    }

    private func decodeTokens(from data: Data) -> CodexTokens.Tokens? {
        guard let doc = try? JSONDecoder().decode(CodexTokens.self, from: data) else {
            return nil
        }
        return doc.tokens
    }

    private func parseDocument(_ data: Data?, destinationPath: String) throws -> [String: AuthTargetJSON] {
        guard let data, !data.isEmpty else {
            if data == nil { return [:] }
            throw AuthTargetSyncError.malformedDestination(targetId: id, path: destinationPath)
        }
        do {
            return try JSONDecoder().decode([String: AuthTargetJSON].self, from: data)
        } catch {
            throw AuthTargetSyncError.malformedDestination(targetId: id, path: destinationPath)
        }
    }

    private var resolvedDestinationAuthFilePath: String {
        if let override = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("auth.json")
        }
        return "~/.pi/agent/auth.json"
    }
}

/// Pi's auth-file lock: an exclusive `<path>.lock` directory with mtime-based
/// staleness, matching the `proper-lockfile` protocol Pi uses.
struct PiAuthFileLock {
    nonisolated(unsafe) static var staleThreshold: TimeInterval = 30
    nonisolated(unsafe) static var acquireDeadline: TimeInterval = 30
    nonisolated(unsafe) static var pollInterval: TimeInterval = 0.05
    nonisolated(unsafe) static var heartbeatInterval: TimeInterval = 5

    let lockPath: String
    private let fileIO: SwitcherooFileIO
    private let heartbeat: Heartbeat

    private final class Heartbeat: @unchecked Sendable {
        private let timer: DispatchSourceTimer

        private final class FileIOBox: @unchecked Sendable {
            let value: SwitcherooFileIO

            init(_ value: SwitcherooFileIO) {
                self.value = value
            }
        }

        init(lockPath: String, fileIO: SwitcherooFileIO, interval: TimeInterval) {
            let fileIOBox = FileIOBox(fileIO)
            timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "switcheroo.pi-auth-lock-heartbeat"))
            timer.setEventHandler { [fileIOBox, lockPath] in
                try? fileIOBox.value.setModificationDate(path: lockPath, date: Date())
            }
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.resume()
        }

        func stop() {
            timer.cancel()
        }
    }

    private init(lockPath: String, fileIO: SwitcherooFileIO) {
        self.lockPath = lockPath
        self.fileIO = fileIO
        let interval = max(0.01, min(Self.heartbeatInterval, Self.staleThreshold / 3))
        self.heartbeat = Heartbeat(lockPath: lockPath, fileIO: fileIO, interval: interval)
    }

    static func acquire(path: String, fileIO: SwitcherooFileIO) throws -> PiAuthFileLock {
        let parent = (path as NSString).deletingLastPathComponent
        try fileIO.createDirectory(path: parent, withIntermediateDirectories: true)

        let lockPath = "\(path).lock"
        let deadline = Date().addingTimeInterval(acquireDeadline)
        while Date() < deadline {
            do {
                try fileIO.createDirectoryExclusive(path: lockPath)
                try? fileIO.setModificationDate(path: lockPath, date: Date())
                return PiAuthFileLock(lockPath: lockPath, fileIO: fileIO)
            } catch {
                guard isAlreadyExistsError(error) else {
                    throw AuthTargetSyncError.destinationWriteFailed(
                        targetId: "pi",
                        path: path,
                        reason: "could not create the Pi auth file lock (\(error.localizedDescription))"
                    )
                }
                if let mtime = fileIO.modificationDate(path: lockPath),
                   Date().timeIntervalSince(mtime) > staleThreshold {
                    try? fileIO.removeItem(path: lockPath)
                    continue
                }
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        throw AuthTargetSyncError.destinationWriteFailed(
            targetId: "pi",
            path: path,
            reason: "could not acquire the Pi auth file lock within \(Int(acquireDeadline)) seconds"
        )
    }

    func release() {
        heartbeat.stop()
        try? fileIO.removeItem(path: lockPath)
    }

    private static func isAlreadyExistsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == NSFileWriteFileExistsError || nsError.domain == NSPOSIXErrorDomain && nsError.code == EEXIST
    }
}
