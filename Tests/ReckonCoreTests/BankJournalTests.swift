import Foundation
import ReckonCore

struct BankJournalTests: Sendable {
    private func dashboard(balance: String, day: String = "2026-10-20", currency: String = "NZD",
                           bill: String = "10.00", transactions: String = "[]") throws -> BankDashboard {
        let accounts = try JSONDecoder().decode([BankAccount].self, from: Data("""
        [{"id":"a1","name":"Private account","type":"checking","currency":"\(currency)","balance":"\(balance)"}]
        """.utf8))
        let forecast = try JSONDecoder().decode(BankForecast.self, from: Data("""
        {"startDate":"\(day)","endDate":"\(BankCalendar.addDays(30, to: day) ?? day)","startingBalance":"\(balance)","endingBalance":"\(balance)","points":[],"events":[{"date":"\(day)","description":"Private bill","kind":"recurring_charge","amount":"-\(bill)"}],"risks":[]}
        """.utf8))
        let now = try bankRequire(BankCalendar.date(day))
        let rows = try JSONDecoder().decode([BankTransaction].self, from: Data(transactions.utf8))
        return BankDashboard(accounts: accounts, cashflow: .loaded([]), spending: .loaded([]), previousSpending: .loaded([]),
                             standingOrders: .loaded([]), freshness: .loaded([]), window: BankDateWindow(now: now), fetchedAt: now,
                             transactions: .loaded(rows), forecast: .loaded(forecast))
    }

    func balanceLimitsOnlyAlertOnCrossings() throws {
        var journal = BankJournal()
        journal.notificationsEnabled = true
        journal.alertLimits["a1"] = 100
        try bankExpect(journal.record(try dashboard(balance: "150")).isEmpty)
        let crossed = journal.record(try dashboard(balance: "99.99"))
        try bankExpect(crossed.count == 1 && crossed.first?.kind == .lowBalance)
        try bankExpect(journal.record(try dashboard(balance: "99.99")).isEmpty)
        try bankExpect(journal.record(try dashboard(balance: "100")).isEmpty)
        try bankExpect(journal.record(try dashboard(balance: "99")).count == 1)
        try bankExpect(journal.record(try dashboard(balance: "1000")).isEmpty)
        try bankExpect(journal.record(try dashboard(balance: "1", currency: "USD")).isEmpty)
        try bankExpect(journal.alertLimits["a1"] == nil)
        journal.notificationsEnabled = false
        _ = journal.record(try dashboard(balance: "200"))
        try bankExpect(journal.record(try dashboard(balance: "0")).isEmpty)
    }

    func chargeIncreasesDoNotAlertOnFirstObservationOrRepeats() throws {
        var journal = BankJournal()
        journal.notificationsEnabled = true
        journal.chargeIncreaseAlerts = true
        try bankExpect(journal.record(try dashboard(balance: "500", bill: "10.00")).isEmpty)
        let increase = journal.record(try dashboard(balance: "500", bill: "10.01"))
        try bankExpect(increase.count == 1 && increase.first?.kind == .chargeIncrease)
        try bankExpect(increase.first?.currency == "NZD")
        try bankExpect(journal.record(try dashboard(balance: "500", bill: "10.01")).isEmpty)
        try bankExpect(journal.record(try dashboard(balance: "500", bill: "9.00")).isEmpty)
    }

    func historyKeepsNinetyDailyObservationsAndPreservesCurrencies() throws {
        var journal = BankJournal()
        for day in 0..<110 {
            let date = try bankRequire(BankCalendar.addDays(day, to: "2026-01-01"))
            _ = journal.record(try dashboard(balance: "123.45", day: date))
        }
        try bankExpect(journal.samples["a1"]?.count == 90)
        let lastDay = try bankRequire(journal.samples["a1"]?.last?.day)
        _ = journal.record(try dashboard(balance: "99.10", day: lastDay))
        try bankExpect(journal.samples["a1"]?.count == 90)
        try bankExpect(journal.samples["a1"]?.last?.balance == Decimal(string: "99.10"))
        let foreign = try dashboard(balance: "10", day: lastDay, currency: "USD")
        try bankExpect(journal.history(for: foreign.accounts[0]).isEmpty)
        try bankExpect(journal.isValid)
    }

    func activityComparesIDsAndRejectsChangedLiquidScope() throws {
        let old = try dashboard(balance: "100", transactions: #"[{"id":"t1","accountId":"a1","date":"2026-10-19","description":"Shop","amount":"-10","currency":"NZD"}]"#)
        let current = try dashboard(balance: "125", transactions: #"[{"id":"t1","accountId":"a1","date":"2026-10-19","description":"Shop","amount":"-10","currency":"NZD"},{"id":"t2","accountId":"a1","date":"2026-10-20","description":"Pay","amount":"25","currency":"NZD"}]"#)
        let previous = BankViewedSnapshot(dashboard: old)
        let summary = BankVisitSummary(previous: previous, dashboard: current)
        try bankExpect(summary.liquidChange == 25)
        try bankExpect(summary.newTransactions?.map(\.id) == ["t2"])
        try bankExpect(!summary.isLimited)
        let changed = BankVisitSummary(previous: previous, dashboard: try dashboard(balance: "125", currency: "USD"))
        try bankExpect(changed.liquidChange == nil)
    }

    func encryptedHistoryRoundTripsWithoutPlaintextAndRejectsTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.enc")
        let storage = try EncryptedBankHistory(url: url, key: Data(repeating: 42, count: 32))
        var journal = BankJournal()
        journal.alertLimits["a1"] = 100
        journal.notificationsEnabled = true
        _ = journal.record(try dashboard(balance: "150"))
        _ = journal.record(try dashboard(balance: "99"))
        try storage.save(journal)
        let encrypted = try Data(contentsOf: url)
        try bankExpect(encrypted.range(of: Data("Private account".utf8)) == nil)
        var loaded = try storage.load()
        try bankExpect(loaded.samples["a1"]?.last?.balance == 99)
        try bankExpect(loaded.alerts.count == 1)
        try bankExpect(loaded.record(try dashboard(balance: "99")).isEmpty)
        let wrongKey = try EncryptedBankHistory(url: url, key: Data(repeating: 7, count: 32))
        try bankExpectError { _ = try wrongKey.load() }
        var changed = encrypted
        changed[10] ^= 1
        try changed.write(to: url)
        try bankExpectError { _ = try storage.load() }
        let remaining = try Data(contentsOf: url)
        try bankExpect(remaining == changed)
    }

    func forecastBillsPaydayAndAucklandCalendar() throws {
        let sample = try BankDashboard.sampleDashboard(now: try bankRequire(BankCalendar.date("2026-10-20")))
        let forecast = try bankRequire(sample.forecast.value)
        try bankExpect(forecast.points.count == 31)
        try bankExpect(forecast.upcomingBills.count == 2)
        try bankExpect(forecast.estimatedPayday?.description == "Employer")
        let deposits = try JSONDecoder().decode(BankForecast.self, from: Data(#"{"startDate":"2026-10-20","endDate":"2026-11-19","startingBalance":"1","endingBalance":"1","points":[],"risks":[],"events":[{"date":"2026-10-21","description":"REWARD INTEREST","amount":"0.06","kind":"expected_income"},{"date":"2026-10-22","description":"Interest credit","amount":"500","kind":"expected_income"},{"date":"2026-10-23","description":"Employer","amount":"3200","kind":"expected_income"}]}"#.utf8))
        try bankExpect(deposits.nextIncome?.description == "REWARD INTEREST")
        try bankExpect(deposits.estimatedPayday?.description == "Employer")
        try bankExpect(BankCalendar.days(from: forecast.startDate, to: forecast.nextIncome?.date ?? "") == 7)
        try bankExpect(BankCalendar.addDays(1, to: "2026-09-27") == "2026-09-28")
        try bankExpect(BankCalendar.date("2026-02-30") == nil)
    }
}
