import Foundation

/// Filters the fetched activity page without changing currency, order, or its latest-100 scope.
public struct BankActivityFilter: Sendable {
    public var search: String
    public var bankID: String?
    public var accountID: String?

    public init(search: String = "", bankID: String? = nil, accountID: String? = nil) {
        self.search = search
        self.bankID = bankID
        self.accountID = accountID
    }

    /// A bank filter matches the same trimmed bank identity used by account grouping.
    public func apply(to transactions: [BankTransaction], accounts: [BankAccount]) -> [BankTransaction] {
        let accountsByID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return transactions.filter { transaction in
            if let accountID, transaction.accountId != accountID { return false }
            let account = accountsByID[transaction.accountId]
            if let bankID {
                guard let account, (account.bankName ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == bankID else { return false }
            }
            return query.isEmpty || [transaction.displayName, transaction.description, transaction.category ?? "",
                                     transaction.currency, account?.name ?? "", account?.bankName ?? ""]
                .joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }
}
