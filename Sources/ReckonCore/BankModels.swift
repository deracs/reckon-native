import Foundation

/// Decodes the REST API's decimal strings without passing money through Double.
public struct BankMoney: Decodable, Sendable {
    public let value: Decimal

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard text.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bank money decimal string")
        }
        self.value = value
    }
}

public struct BankAccount: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let currency: String
    public let balance: BankMoney
    public let bankName: String?
    public let bankLogo: String?
    public let status: String?

    public var bankLogoURL: URL? {
        guard let bankLogo, let url = URL(string: bankLogo),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public var contributesToLiquidBalance: Bool {
        currency == "NZD" && (type == "checking" || type == "savings")
    }
}

public struct MonthlyCashflow: Decodable, Sendable {
    public let month: String
    public let income: BankMoney
    public let spending: BankMoney
    public let net: BankMoney
    public let transactionCount: Int
}

public struct CategorySpending: Decodable, Sendable {
    public let category: String
    public let spent: BankMoney
    public let transactionCount: Int
}

public struct StandingOrder: Decodable, Sendable {
    public let merchant: String
    public let category: String?
    public let cadence: String
    public let occurrences: Int
    public let averageAmount: BankMoney
    public let lastDate: String
}

public struct AccountFreshness: Decodable, Sendable {
    public let accountId: String
    public let accountName: String
    public let balanceRefreshedAt: String?
    public let transactionsRefreshedAt: String?

    public static func parseTimestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// A failed summary does not hide successfully fetched account balances.
public enum BankSection<Value: Sendable>: Sendable {
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public struct BankDashboard: Sendable {
    public let accounts: [BankAccount]
    public let cashflow: BankSection<[MonthlyCashflow]>
    public let spending: BankSection<[CategorySpending]>
    public let previousSpending: BankSection<[CategorySpending]>
    public let standingOrders: BankSection<[StandingOrder]>
    public let freshness: BankSection<[AccountFreshness]>
    public let window: BankDateWindow
    public let fetchedAt: Date
    public let transactions: BankSection<[BankTransaction]>
    public let forecast: BankSection<BankForecast>

    public init(accounts: [BankAccount], cashflow: BankSection<[MonthlyCashflow]>, spending: BankSection<[CategorySpending]>,
                previousSpending: BankSection<[CategorySpending]>, standingOrders: BankSection<[StandingOrder]>,
                freshness: BankSection<[AccountFreshness]>, window: BankDateWindow, fetchedAt: Date,
                transactions: BankSection<[BankTransaction]> = .failed("Recent activity unavailable."),
                forecast: BankSection<BankForecast> = .failed("Dead reckoning unavailable.")) {
        self.accounts = accounts
        self.cashflow = cashflow
        self.spending = spending
        self.previousSpending = previousSpending
        self.standingOrders = standingOrders
        self.freshness = freshness
        self.window = window
        self.fetchedAt = fetchedAt
        self.transactions = transactions
        self.forecast = forecast
    }

    public var liquidBalance: Decimal {
        accounts.filter(\.contributesToLiquidBalance).reduce(Decimal.zero) { $0 + $1.balance.value }
    }

    public var hasMultipleCurrencies: Bool {
        accounts.contains { $0.currency != "NZD" }
    }

    public var currentCashflow: MonthlyCashflow? {
        cashflow.value?.first { $0.month == window.month }
    }

    public func previousMonthlyAverage(category: String) -> Decimal? {
        guard let rows = previousSpending.value else { return nil }
        return rows.filter { $0.category == category }.reduce(Decimal.zero) { $0 + $1.spent.value } / 3
    }
}

public enum BankFormatting {
    public static func money(_ amount: Decimal, currency: String? = "NZD", compact: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_NZ")
        formatter.numberStyle = currency == nil ? .decimal : .currency
        formatter.currencyCode = currency
        if currency == "NZD" { formatter.currencySymbol = "$" }
        formatter.minimumFractionDigits = compact ? 0 : 2
        formatter.maximumFractionDigits = compact ? 0 : 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "—"
    }
}
