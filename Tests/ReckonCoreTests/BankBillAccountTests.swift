import Foundation
import ReckonCore

struct BankBillAccountTests {
    func billModelsRetainAccountCurrencyAndOptionalMetadata() throws {
        let decoder = JSONDecoder()
        let current = try decoder.decode(StandingOrder.self, from: Data(#"{"merchant":"Fixture merchant","accountId":"fixture-account","currency":"USD","merchantLogo":"https://example.com/logo.png","cadence":"monthly","occurrences":6,"averageAmount":"25.50","lastDate":"2026-10-01"}"#.utf8))
        try bankExpect(current.accountId == "fixture-account" && current.currency == "USD")
        try bankExpect(current.merchantLogo == "https://example.com/logo.png" && current.averageAmount.value == Decimal(string: "25.50"))
        let legacy = try decoder.decode(StandingOrder.self, from: Data(#"{"merchant":"Fixture merchant","cadence":"monthly","occurrences":6,"averageAmount":"25.50","lastDate":"2026-10-01"}"#.utf8))
        try bankExpect(legacy.accountId == nil && legacy.currency == nil && legacy.merchantLogo == nil)
        let event = try decoder.decode(BankForecastEvent.self, from: Data(#"{"description":"Fixture merchant","date":"2026-11-05","kind":"recurring_charge","amount":"-25.50","accountId":"fixture-account","currency":"NZD"}"#.utf8))
        try bankExpect(event.accountId == "fixture-account" && event.currency == "NZD")
    }

    func chargeAlertsSeparateAccountsAndResetPooledBaselines() throws {
        let base = try BankDashboard.sampleDashboard()
        func dashboard(_ first: String, _ second: String) throws -> BankDashboard {
            let payload = """
            {"startDate":"2026-11-03","endDate":"2026-12-03","startingBalance":"1000","endingBalance":"900","points":[],"risks":[],"events":[
            {"date":"2026-11-05","description":"Fixture merchant","kind":"recurring_charge","amount":"-\(first)","accountId":"spending","currency":"NZD"},
            {"date":"2026-11-06","description":"Fixture merchant","kind":"recurring_charge","amount":"-\(second)","accountId":"savings","currency":"NZD"}]}
            """
            let forecast = try JSONDecoder().decode(BankForecast.self, from: Data(payload.utf8))
            return BankDashboard(accounts: base.accounts, cashflow: base.cashflow, spending: base.spending, previousSpending: base.previousSpending,
                                 standingOrders: base.standingOrders, freshness: base.freshness, window: base.window, fetchedAt: base.fetchedAt, forecast: .loaded(forecast))
        }
        // The old merchant-only amount must not trigger an alert when account metadata first arrives.
        var journal = try JSONDecoder().decode(BankJournal.self, from: Data(#"{"samples":{},"alertLimits":{},"notificationsEnabled":true,"chargeIncreaseAlerts":true,"alerts":[],"previousBalances":{},"previousCharges":{"Fixture merchant":1}}"#.utf8))
        try bankExpect(journal.record(try dashboard("10", "30")).isEmpty)
        let firstIncrease = journal.record(try dashboard("11", "30"))
        try bankExpect(firstIncrease.count == 1 && firstIncrease.first?.current == 11)
        let secondIncrease = journal.record(try dashboard("11", "31"))
        try bankExpect(secondIncrease.count == 1 && secondIncrease.first?.current == 31)
        try bankExpect(journal.record(try dashboard("11", "31")).isEmpty)
    }
}
