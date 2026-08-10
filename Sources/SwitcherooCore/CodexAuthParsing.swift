import Foundation

// Switcheroo intentionally treats auth.json as an opaque blob for storage/swap.
// For UI-only affordances (expiry display, default naming) and auth-target
// conversion we do best-effort parsing. Auth-target adapters use the summary to
// derive identity and expiry without ever persisting parsed fields.

public enum CodexAuthParsing {
    public struct Summary: Sendable {
        public var accessTokenExpiry: Date?
        public var email: String?
        public var accountId: String?
        public var userId: String?
        /// `chatgpt_account_id` from the id_token's `https://api.openai.com/auth` claim.
        public var chatgptAccountId: String?
        /// `chatgpt_account_id` from the access token's `https://api.openai.com/auth`
        /// claim. This is the claim Pi itself validates when issuing requests.
        public var accessTokenChatgptAccountId: String?

        public init(
            accessTokenExpiry: Date? = nil,
            email: String? = nil,
            accountId: String? = nil,
            userId: String? = nil,
            chatgptAccountId: String? = nil,
            accessTokenChatgptAccountId: String? = nil
        ) {
            self.accessTokenExpiry = accessTokenExpiry
            self.email = email
            self.accountId = accountId
            self.userId = userId
            self.chatgptAccountId = chatgptAccountId
            self.accessTokenChatgptAccountId = accessTokenChatgptAccountId
        }
    }

    public static func summarize(authJSONData: Data) -> Summary? {
        guard let doc = try? JSONDecoder().decode(CodexAuthFile.self, from: authJSONData) else {
            return nil
        }

        let accessTokenExp = doc.tokens?.access_token.flatMap { jwtExpiryDate(token: $0) }
        let email = doc.tokens?.id_token.flatMap {
            jwtStringClaim(token: $0, claim: "email")
                ?? jwtNestedStringClaim(token: $0, claim: "https://api.openai.com/profile", key: "email")
                ?? jwtStringClaim(token: $0, claim: "https://api.openai.com/profile.email")
        }
        let accountId = doc.tokens?.account_id
        let userId = doc.tokens?.id_token.flatMap {
            jwtNestedStringClaim(token: $0, claim: "https://api.openai.com/auth", key: "chatgpt_user_id")
                ?? jwtNestedStringClaim(token: $0, claim: "https://api.openai.com/auth", key: "user_id")
                ?? jwtStringClaim(token: $0, claim: "sub")
        }
        let chatgptAccountId = doc.tokens?.id_token.flatMap {
            jwtNestedStringClaim(token: $0, claim: "https://api.openai.com/auth", key: "chatgpt_account_id")
        }
        let accessTokenChatgptAccountId = doc.tokens?.access_token.flatMap {
            jwtNestedStringClaim(token: $0, claim: "https://api.openai.com/auth", key: "chatgpt_account_id")
        }

        return Summary(
            accessTokenExpiry: accessTokenExp,
            email: email,
            accountId: accountId,
            userId: userId,
            chatgptAccountId: chatgptAccountId,
            accessTokenChatgptAccountId: accessTokenChatgptAccountId
        )
    }

    private struct CodexAuthFile: Decodable {
        struct Tokens: Decodable {
            var access_token: String?
            var refresh_token: String?
            var id_token: String?
            var account_id: String?
        }

        var tokens: Tokens?
    }

    private static func jwtExpiryDate(token: String) -> Date? {
        guard let exp = jwtNumericClaim(token: token, claim: "exp") else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func jwtNumericClaim(token: String, claim: String) -> TimeInterval? {
        guard let payload = jwtPayload(token: token) else { return nil }
        if let intVal = payload[claim] as? Int { return TimeInterval(intVal) }
        if let doubleVal = payload[claim] as? Double { return doubleVal }
        if let stringVal = payload[claim] as? String, let doubleVal = Double(stringVal) { return doubleVal }
        return nil
    }

    private static func jwtStringClaim(token: String, claim: String) -> String? {
        guard let payload = jwtPayload(token: token) else { return nil }
        return payload[claim] as? String
    }

    private static func jwtNestedStringClaim(token: String, claim: String, key: String) -> String? {
        guard let payload = jwtPayload(token: token) else { return nil }
        guard let dict = payload[claim] as? [String: Any] else { return nil }
        return dict[key] as? String
    }

    private static func jwtPayload(token: String) -> [String: Any]? {
        // JWT: header.payload.signature (base64url)
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        guard let payloadData = base64URLDecode(String(parts[1])) else { return nil }
        guard
            let obj = try? JSONSerialization.jsonObject(with: payloadData),
            let dict = obj as? [String: Any]
        else {
            return nil
        }
        return dict
    }

    private static func base64URLDecode(_ str: String) -> Data? {
        var s = str.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad to multiple of 4 for base64 decoder.
        let mod = s.count % 4
        if mod != 0 {
            s.append(String(repeating: "=", count: 4 - mod))
        }

        return Data(base64Encoded: s)
    }
}
