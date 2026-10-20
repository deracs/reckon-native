import Foundation
import ReckonCore

struct BankDashboardTests: Sendable {
    func accountGroupsRetainEveryAccountAndCurrency() throws {
        let accounts = try JSONDecoder().decode([BankAccount].self, from: Data(#"[{"id":"1","name":"Everyday","type":"checking","currency":"NZD","balance":"12.34","bankName":"ASB"},{"id":"2","name":"Dollar wallet","type":"checking","currency":"USD","balance":"99.10","bankName":" ASB ","bankLogo":"https://example.com/asb.png"},{"id":"3","name":"Savings","type":"savings","currency":"NZD","balance":"400","bankName":"ANZ"},{"id":"4","name":"Unknown","type":"investment","currency":"NZD","balance":"10"},{"id":"5","name":"Blank source","type":"checking","currency":"AUD","balance":"1","bankName":"  "}]"#.utf8))
        let groups = BankAccountGroup.groupAccounts(accounts)
        try bankExpect(groups.map(\.name) == ["ANZ", "ASB", "Other accounts"])
        try bankExpect(groups.flatMap(\.accounts).map(\.id).sorted() == accounts.map(\.id).sorted())
        try bankExpect(groups[1].accounts.map(\.currency) == ["NZD", "USD"])
        try bankExpect(groups[1].logoAccount?.id == "2")
        try bankExpect(groups[2].accounts.count == 2)
        try bankExpect(groups[1].currencyBalances.map(\.currency) == ["NZD", "USD"])
        try bankExpect(groups[1].currencyBalances.map(\.balance) == [Decimal(string: "12.34")!, Decimal(string: "99.10")!])
        try bankExpect(BankAccountGroup.groupAccounts([]).isEmpty)
    }

    func bankCurrencyBalancesSumPreciselyAndIncludeDebt() throws {
        let accounts = try JSONDecoder().decode([BankAccount].self, from: Data(#"[{"id":"1","name":"Main","type":"checking","currency":"NZD","balance":"0.10","bankName":"Bank"},{"id":"2","name":"Savings","type":"savings","currency":"NZD","balance":"0.20","bankName":"Bank"},{"id":"3","name":"Credit","type":"credit","currency":"NZD","balance":"-5","bankName":"Bank"},{"id":"4","name":"Investment","type":"investment","currency":"USD","balance":"12.34","bankName":"Bank"}]"#.utf8))
        let totals = try bankRequire(BankAccountGroup.groupAccounts(accounts).first).currencyBalances
        try bankExpect(totals.map(\.currency) == ["NZD", "USD"])
        try bankExpect(totals[0].balance == Decimal(string: "-4.70"))
        try bankExpect(totals[1].balance == Decimal(string: "12.34"))
    }

    func liquidBalanceExcludesInvestmentsCreditAndForeignCurrency() throws {
        let data = Data(#"[{"id":"1","name":"Main","type":"checking","currency":"NZD","balance":"0.10"},{"id":"2","name":"Savings","type":"savings","currency":"NZD","balance":"0.20"},{"id":"3","name":"Investment","type":"investment","currency":"NZD","balance":"50000"},{"id":"4","name":"USD","type":"checking","currency":"USD","balance":"900"},{"id":"5","name":"Credit","type":"credit","currency":"NZD","balance":"-200"},{"id":"6","name":"Loan","type":"loan","currency":"NZD","balance":"-5000"}]"#.utf8)
        let accounts = try JSONDecoder().decode([BankAccount].self, from: data)
        let dashboard = BankDashboard(accounts: accounts, cashflow: .loaded([]), spending: .loaded([]),
                                      previousSpending: .loaded([]), standingOrders: .loaded([]), freshness: .loaded([]),
                                      window: BankDateWindow(now: .now), fetchedAt: .now)
        try bankExpect(dashboard.liquidBalance == Decimal(string: "0.30"))
        try bankExpect(dashboard.hasMultipleCurrencies)
    }

    func negativeBalanceAndNoAccountsRemainHonest() throws {
        let money = try JSONDecoder().decode(BankMoney.self, from: Data(#""-123.45""#.utf8))
        try bankExpect(money.value == Decimal(string: "-123.45"))
        try bankExpect(BankFormatting.money(money.value).contains("123.45"))
        let dashboard = BankDashboard(accounts: [], cashflow: .loaded([]), spending: .loaded([]),
                                      previousSpending: .loaded([]), standingOrders: .loaded([]), freshness: .loaded([]),
                                      window: BankDateWindow(now: .now), fetchedAt: .now)
        try bankExpect(dashboard.liquidBalance == 0)
        try bankExpect(dashboard.currentCashflow == nil)
    }

    func malformedMoneyFailsDecoding(json: String) throws {
        try bankExpectError {
            _ = try JSONDecoder().decode(BankMoney.self, from: Data(json.utf8))
        }
    }

    func aucklandMonthBoundaryAndYearRollover() throws {
        let date = try bankRequire(ISO8601DateFormatter().date(from: "2026-12-31T11:30:00Z"))
        let window = BankDateWindow(now: date)
        try bankExpect(window.month == "2027-01")
        try bankExpect(window.monthStart == "2027-01-01")
        try bankExpect(window.today == "2027-01-01")
        try bankExpect(window.previousThreeMonthsStart == "2026-10-01")
        try bankExpect(window.previousMonthEnd == "2026-12-31")
        try bankExpect(window.recurringStart == "2026-07-01")
    }

    func leapDayAndWinterTime() throws {
        let date = try bankRequire(ISO8601DateFormatter().date(from: "2028-02-29T12:00:00Z"))
        try bankExpect(BankDateWindow(now: date).previousMonthEnd == "2028-02-29")
        let winter = try bankRequire(ISO8601DateFormatter().date(from: "2026-06-30T11:30:00Z"))
        try bankExpect(BankDateWindow(now: winter).today == "2026-06-30")
    }

    func timestampFormatsAndMissingValues() throws {
        try bankExpect(AccountFreshness.parseTimestamp("2026-10-20T01:02:03.123Z") != nil)
        try bankExpect(AccountFreshness.parseTimestamp("2026-10-20T01:02:03Z") != nil)
        try bankExpect(AccountFreshness.parseTimestamp(nil) == nil)
        try bankExpect(AccountFreshness.parseTimestamp("invalid") == nil)
    }

    func trailingAverageUsesThreeFullMonthsIncludingZeroMonths() throws {
        let dashboard = try BankDashboard.sampleDashboard()
        try bankExpect(dashboard.previousMonthlyAverage(category: "Groceries") == 600)
        try bankExpect(dashboard.previousMonthlyAverage(category: "No previous spending") == 0)
        try bankExpect(dashboard.liquidBalance == Decimal(string: "12480.45"))
        try bankExpect(dashboard.currentCashflow?.net.value == Decimal(string: "2579.35"))
    }

    func rejectsUnsafeConnectionURLs(url: String) throws {
        try bankExpectError { _ = try ReckonConnection(baseURL: url, token: "test-token") }
    }

    func acceptsHTTPSAndLoopbackURLs(url: String) throws {
        let connection = try ReckonConnection(baseURL: url, token: " test-token ")
        try bankExpect(connection.token == "test-token")
    }

    func rejectsMissingAndMultilineTokens() throws {
        for token in ["", "   ", "first\nsecond"] {
            try bankExpectError { _ = try ReckonConnection(baseURL: "https://bank.invalid", token: token) }
        }
    }
}
