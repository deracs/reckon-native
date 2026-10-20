import Foundation

/// Akahu tokens are persisted only by the app's Keychain owner.
public struct AkahuCredentials: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let appToken: String
    public let userToken: String
    public var description: String { "AkahuCredentials(<redacted>)" }
    public var debugDescription: String { description }

    public init(appToken: String, userToken: String) throws {
        func parseToken(_ input: String) -> String? {
            let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 4096,
                  token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { return nil }
            return token
        }
        guard let app = parseToken(appToken), let user = parseToken(userToken) else {
            throw AkahuCredentialError.invalidTokens
        }
        self.appToken = app
        self.userToken = user
    }
}

public enum AkahuCredentialError: LocalizedError {
    case invalidTokens

    public var errorDescription: String? {
        "Enter both Akahu tokens without spaces or line breaks."
    }
}
