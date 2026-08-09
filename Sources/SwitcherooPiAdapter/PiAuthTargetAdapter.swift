import Foundation
import SwitcherooCore

/// Mirrors the active Codex credential into Pi's `openai-codex` OAuth credential.
///
/// Schema (verified against Pi v0.83.0, `@earendil-works/pi-coding-agent`):
/// Pi stores one credential per provider in `~/.pi/agent/auth.json` (or
/// `$PI_CODING_AGENT_DIR/auth.json`), a JSON object keyed by provider id. The
/// `openai-codex` credential is:
///
///     {
///       "type": "oauth",
///       "access": "<access token JWT>",
///       "refresh": "<refresh token JWT>",
///       "expires": <epoch milliseconds>,
///       "accountId": "<chatgpt_account_id from id_token>"
///     }
///
/// Conversion is in-memory only; Switcheroo never persists parsed fields, and
/// inactive Codex snapshots remain opaque blobs in Keychain.
public struct PiAuthTargetAdapter: AuthTargetAdapter {
    public let id = "pi"
    public let displayName = "Pi"

    /// Pi's auth file location does not depend on the Codex provider state.
    public func destinationAuthFilePath(forProviderState providerState: SwitcherooProvider) -> String {
        resolvedDestinationAuthFilePath
    }

    public func destinationDocument(fromSourceAuthData sourceAuthData: Data, existingDestinationData: Data?) throws -> Data {
        let credential = try convertedCredential(fromSourceAuthData: sourceAuthData)
        return try AuthTargetDocument.merging(
            credential,
            into: existingDestinationData,
            targetId: id,
            destinationPath: resolvedDestinationAuthFilePath
        )
    }

    public init() {}

    public func convertedCredential(fromSourceAuthData sourceAuthData: Data) throws -> AuthTargetCredential {
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
        guard let accountId = summary.chatgptAccountId ?? summary.accountId, !accountId.isEmpty else {
            throw AuthTargetSyncError.unsupportedSource(targetId: id, reason: "source auth has no account id")
        }

        return AuthTargetCredential(
            destinationKey: "openai-codex",
            jsonValue: .object([
                "type": .string("oauth"),
                "access": .string(access),
                "refresh": .string(refresh),
                "expires": .number(expiry.timeIntervalSince1970 * 1000),
                "accountId": .string(accountId),
            ])
        )
    }

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

    private var resolvedDestinationAuthFilePath: String {
        if let override = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !override.isEmpty {
            return (override as NSString).appendingPathComponent("auth.json")
        }
        return "~/.pi/agent/auth.json"
    }
}
