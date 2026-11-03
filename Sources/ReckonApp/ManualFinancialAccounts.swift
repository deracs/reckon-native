import CryptoKit
import Foundation
import ReckonCore
import Security

struct ManualFinancialAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: String
    var currency: String
    var balance: Decimal
    var updatedAt = Date.now
}

struct SavingsGoal: Codable, Identifiable, Equatable {
    var id = UUID()
    var accountID: String
    var name: String
    var target: Decimal
    var deadline: Date?
    var paydayIntervalDays: Int
}

struct LocalFinancialSettings: Codable {
    var accounts: [ManualFinancialAccount] = []
    var goals: [SavingsGoal] = []
    var forecastAdjustments: BankForecastAdjustments = BankForecastAdjustments()
}

/// Manual financial accounts use a separate encrypted file and survive bank disconnection.
struct ManualFinancialAccountsStorage {
    private let url: URL
    private let key: SymmetricKey

    init(url: URL, key: Data) throws {
        guard key.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        self.url = url
        self.key = SymmetricKey(data: key)
    }

    init() throws {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("nz.reckon.native", isDirectory: true)
        url = directory.appendingPathComponent("manual-accounts.enc")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "nz.reckon.native.manual-accounts", kSecAttrAccount as String: "encryption-key"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        let data: Data
        if status == errSecSuccess, let saved = result as? Data, saved.count == 32 {
            data = saved
        } else if status == errSecItemNotFound && !FileManager.default.fileExists(atPath: url.path) {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
            data = Data(bytes)
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        } else { throw CocoaError(.fileReadNoPermission) }
        key = SymmetricKey(data: data)
    }

    func load() throws -> LocalFinancialSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalFinancialSettings() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LocalFinancialSettings.self, from: AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key))
    }

    func save(_ settings: LocalFinancialSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sealed = try AES.GCM.seal(JSONEncoder().encode(settings), using: key)
        guard let data = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
