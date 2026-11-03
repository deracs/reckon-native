import Foundation

public struct BankBalanceSample: Codable, Identifiable, Sendable {
    public let day: String
    public let balance: Decimal
    public let currency: String
    public var id: String { day }

    public init(day: String, balance: Decimal, currency: String) {
        self.day = day; self.balance = balance; self.currency = currency
    }
}

public struct BankViewedSnapshot: Codable, Sendable {
    public let date: Date
    public let liquidBalance: Decimal
    public let liquidAccountIDs: Set<String>
    public let transactionIDs: Set<String>?

    public init(dashboard: BankDashboard, viewedAt: Date = .now) {
        date = viewedAt
        liquidBalance = dashboard.liquidBalance
        liquidAccountIDs = Set(dashboard.accounts.filter(\.contributesToLiquidBalance).map(\.id))
        transactionIDs = dashboard.transactions.value.map { Set($0.map(\.id)) }
    }
}

/// Counts newly observed transactions; a full page is labelled as a lower bound.
public struct BankVisitSummary: Sendable {
    public let since: Date
    public let liquidChange: Decimal?
    public let newTransactions: [BankTransaction]?
    public let isLimited: Bool

    public init(previous: BankViewedSnapshot, dashboard: BankDashboard) {
        since = previous.date
        let ids = Set(dashboard.accounts.filter(\.contributesToLiquidBalance).map(\.id))
        liquidChange = ids == previous.liquidAccountIDs ? dashboard.liquidBalance - previous.liquidBalance : nil
        if let seen = previous.transactionIDs, let transactions = dashboard.transactions.value {
            newTransactions = transactions.filter { !seen.contains($0.id) }
            isLimited = transactions.count >= 100
        } else {
            newTransactions = nil
            isLimited = false
        }
    }
}

public struct BankAlert: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case lowBalance, chargeIncrease, balanceTarget, deposit }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let subject: String
    public let previous: Decimal
    public let current: Decimal
    public let currency: String

    public init(date: Date, kind: Kind, subject: String, previous: Decimal, current: Decimal, currency: String) {
        id = UUID(); self.date = date; self.kind = kind; self.subject = subject
        self.previous = previous; self.current = current; self.currency = currency
    }
}

private struct BankObservedBalance: Codable, Sendable {
    let amount: Decimal
    let currency: String
}

/// Local history stores daily observations, never reconstructed historical balances.
public struct BankJournal: Codable, Sendable {
    public var samples: [String: [BankBalanceSample]] = [:]
    public var lastViewed: BankViewedSnapshot?
    public var alertLimits: [String: Decimal] = [:]
    public var balanceTargets: [String: Decimal]?
    public var depositThreshold: Decimal?
    private var seenDepositTransactionIDs: Set<String>?
    public var notificationsEnabled = false
    public var chargeIncreaseAlerts = false
    public private(set) var alerts: [BankAlert] = []
    private var previousBalances: [String: BankObservedBalance] = [:]
    private var previousCharges: [String: Decimal] = [:]

    public init() {}

    public mutating func record(_ dashboard: BankDashboard) -> [BankAlert] {
        let day = dashboard.window.today
        let cutoff = BankCalendar.addDays(-89, to: day) ?? day
        for id in Array(samples.keys) {
            samples[id] = samples[id]?.filter { $0.day >= cutoff }
            if samples[id]?.isEmpty == true { samples.removeValue(forKey: id) }
        }
        var found: [BankAlert] = []
        for account in dashboard.accounts {
            var history = samples[account.id] ?? []
            history.removeAll { $0.day == day }
            history.append(BankBalanceSample(day: day, balance: account.balance.value, currency: account.currency))
            samples[account.id] = history.sorted { $0.day < $1.day }
            if let previous = previousBalances[account.id], previous.currency != account.currency {
                alertLimits.removeValue(forKey: account.id)
                balanceTargets?.removeValue(forKey: account.id)
            }
            if notificationsEnabled, let limit = alertLimits[account.id], let previous = previousBalances[account.id],
               previous.currency == account.currency, previous.amount >= limit, account.balance.value < limit {
                found.append(BankAlert(date: dashboard.fetchedAt, kind: .lowBalance, subject: account.name,
                                       previous: previous.amount, current: account.balance.value, currency: account.currency))
            }
            if notificationsEnabled, let target = balanceTargets?[account.id], let previous = previousBalances[account.id],
               previous.currency == account.currency, previous.amount < target, account.balance.value >= target {
                found.append(BankAlert(date: dashboard.fetchedAt, kind: .balanceTarget, subject: account.name,
                                       previous: previous.amount, current: account.balance.value, currency: account.currency))
            }
            previousBalances[account.id] = BankObservedBalance(amount: account.balance.value, currency: account.currency)
        }
        if let transactions = dashboard.transactions.value {
            let ids = Set(transactions.map(\.id))
            if notificationsEnabled, let threshold = depositThreshold, let seen = seenDepositTransactionIDs {
                for transaction in transactions where !seen.contains(transaction.id) && transaction.currency == "NZD" && transaction.amount.value > 0 && transaction.amount.value >= threshold {
                    found.append(BankAlert(date: dashboard.fetchedAt, kind: .deposit, subject: transaction.displayName,
                                           previous: 0, current: transaction.amount.value, currency: transaction.currency))
                }
            }
            seenDepositTransactionIDs = (seenDepositTransactionIDs ?? []).union(ids)
        }
        if let forecast = dashboard.forecast.value {
            var charges: [String: (name: String, amount: Decimal)] = [:]
            for event in forecast.events where event.kind == "recurring_charge" {
                charges[recurringChargeKey(for: event)] = (event.description, abs(event.amount.value))
            }
            for (key, charge) in charges {
                if notificationsEnabled, chargeIncreaseAlerts, let previous = previousCharges[key], charge.amount >= previous + Decimal(1) / 100 {
                    found.append(BankAlert(date: dashboard.fetchedAt, kind: .chargeIncrease, subject: charge.name,
                                           previous: previous, current: charge.amount, currency: "NZD"))
                }
            }
            previousCharges = charges.mapValues(\.amount)
        }
        alerts = Array((found + alerts).prefix(30))
        return found
    }

    /// Starts a new deposit baseline after changing the deposit threshold.
    public mutating func resetDepositBaseline() {
        seenDepositTransactionIDs = nil
    }

    /// Account-scoped patterns establish new baselines instead of reusing a pooled merchant amount.
    private func recurringChargeKey(for event: BankForecastEvent) -> String {
        guard let accountID = event.accountId else { return event.description }
        // Length prefixes keep arbitrary account and merchant strings from colliding at separators.
        return [accountID, event.currency ?? "NZD", event.description].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public func history(for account: BankAccount) -> [BankBalanceSample] {
        (samples[account.id] ?? []).filter { $0.currency == account.currency }
    }

    public var isValid: Bool {
        samples.values.allSatisfy { rows in
            rows.count <= 90 && rows.allSatisfy { BankCalendar.date($0.day) != nil && !$0.balance.isNaN && $0.currency.count == 3 }
        } && alertLimits.values.allSatisfy { !$0.isNaN }
          && (balanceTargets?.values.allSatisfy { !$0.isNaN } ?? true)
          && (depositThreshold.map { !$0.isNaN && $0 > 0 } ?? true)
          && previousBalances.values.allSatisfy { !$0.amount.isNaN && $0.currency.count == 3 }
          && previousCharges.values.allSatisfy { !$0.isNaN }
    }
}
