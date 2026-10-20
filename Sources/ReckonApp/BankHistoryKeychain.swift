import Foundation
import ReckonCore
import Security

enum BankHistoryKeychain {
    static func openHistory() throws -> EncryptedBankHistory {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("nz.reckon.native", isDirectory: true)
        let url = directory.appendingPathComponent("balance-history.enc")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nz.reckon.native.history", kSecAttrAccount as String: "encryption-key"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        let key: Data
        if status == errSecSuccess, let saved = result as? Data {
            key = saved
        } else if status == errSecItemNotFound, !FileManager.default.fileExists(atPath: url.path) {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BankHistoryError.invalidData }
            key = Data(bytes)
            var item = query
            item[kSecValueData as String] = key
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw BankHistoryError.invalidData }
        } else {
            throw BankHistoryError.invalidData
        }
        return try EncryptedBankHistory(url: url, key: key)
    }
}
