import Foundation
import ReckonCore
import Security

enum AkahuKeychain {
    private static let service = "nz.reckon.native.connection"
    private static let account = "akahu-personal-app"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func loadCredentials() throws -> AkahuCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        let saved = try JSONDecoder().decode(AkahuCredentials.self, from: data)
        return try AkahuCredentials(appToken: saved.appToken, userToken: saved.userToken)
    }

    static func saveCredentials(_ credentials: AkahuCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainFailure(status: added) }
        } else if status != errSecSuccess {
            throw KeychainFailure(status: status)
        }
    }

    static func deleteCredentials() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

private struct KeychainFailure: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Could not access the Reckon connection in Keychain (\(status))."
    }
}
