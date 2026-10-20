import Foundation

/// Groups accounts by bank without combining balances across currencies.
public struct BankAccountGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let accounts: [BankAccount]

    public var logoAccount: BankAccount? {
        accounts.first { $0.bankLogoURL != nil } ?? accounts.first
    }

    /// Current account balances grouped by currency; no exchange-rate conversion.
    public var currencyBalances: [BankCurrencyBalance] {
        Dictionary(grouping: accounts, by: \.currency).map { currency, accounts in
            BankCurrencyBalance(currency: currency, balance: accounts.reduce(Decimal.zero) { $0 + $1.balance.value })
        }.sorted {
            if $0.currency == "NZD" { return $1.currency != "NZD" }
            if $1.currency == "NZD" { return false }
            return $0.currency < $1.currency
        }
    }

    public static func groupAccounts(_ accounts: [BankAccount]) -> [BankAccountGroup] {
        let grouped = Dictionary(grouping: accounts) { account -> String in
            let name = account.bankName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "" : name
        }
        return grouped.map { name, accounts in
            BankAccountGroup(id: name, name: name.isEmpty ? "Other accounts" : name, accounts: accounts)
        }.sorted {
            if $0.id.isEmpty { return false }
            if $1.id.isEmpty { return true }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// A bank's combined current balance in one currency, including negative balances.
public struct BankCurrencyBalance: Identifiable, Sendable {
    public let currency: String
    public let balance: Decimal
    public var id: String { currency }
}
