import Foundation
import Security

/// Keeps optional private-repository access separate from bank credentials.
enum ReckonUpdateKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "nz.reckon.native.updates",
         kSecAttrAccount as String: "github-release-read"]
    }

    static func loadToken() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw UpdateKeychainFailure() }
        return token
    }

    static func saveToken(_ raw: String) throws {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("github_pat_"), token.utf8.count <= 4096,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw UpdateKeychainFailure() }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UpdateKeychainFailure() }
        } else if status != errSecSuccess { throw UpdateKeychainFailure() }
    }

    static func deleteToken() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw UpdateKeychainFailure() }
    }
}

private struct UpdateKeychainFailure: Error {}
