import CryptoKit
import Foundation

public enum BankHistoryError: LocalizedError {
    case unreadable, invalidData, couldNotSave
    public var errorDescription: String? {
        switch self {
        case .unreadable: "Could not read local balance history. Check access to Reckon’s Application Support folder."
        case .invalidData: "Could not unlock local balance history. Existing history has been left in place."
        case .couldNotSave: "Could not save local balance history. Check available disk space and folder access."
        }
    }
}

/// History is AES-GCM encrypted; the caller obtains its key from Keychain.
public struct EncryptedBankHistory: Sendable {
    private let url: URL
    private let key: SymmetricKey

    public init(url: URL, key: Data) throws {
        guard key.count == 32 else { throw BankHistoryError.invalidData }
        self.url = url; self.key = SymmetricKey(data: key)
    }

    public func load() throws -> BankJournal {
        guard FileManager.default.fileExists(atPath: url.path) else { return BankJournal() }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw BankHistoryError.unreadable }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let decoded = try AES.GCM.open(box, using: key)
            let journal = try JSONDecoder().decode(BankJournal.self, from: decoded)
            guard journal.isValid else { throw BankHistoryError.invalidData }
            return journal
        } catch { throw BankHistoryError.invalidData }
    }

    public func save(_ journal: BankJournal) throws {
        guard journal.isValid else { throw BankHistoryError.invalidData }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(journal)
            let box = try AES.GCM.seal(data, using: key)
            guard let encrypted = box.combined else { throw BankHistoryError.couldNotSave }
            try encrypted.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw BankHistoryError.couldNotSave }
    }
}
