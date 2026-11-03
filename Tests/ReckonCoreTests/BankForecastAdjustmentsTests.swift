import Foundation
import ReckonCore

struct BankForecastAdjustmentsTests {
    func correctionsApplyOnlyToMatchingSeriesAndSpendingDoesNotDoubleCount() throws {
        let rent = BankForecastEvent(accountId: "a", currency: "NZD", merchantLogo: nil, date: "2026-11-04", description: "Rent", amount: BankMoney(value: -100), kind: "recurring_charge")
        let other = BankForecastEvent(accountId: "b", currency: "NZD", merchantLogo: nil, date: "2026-11-04", description: "Rent", amount: BankMoney(value: -50), kind: "recurring_charge")
        let points = ["2026-11-03", "2026-11-04", "2026-11-05"].map { BankForecastPoint(date: $0, projectedBalance: BankMoney(value: 0)) }
        let source = BankForecast(startDate: "2026-11-03", endDate: "2026-11-05", startingBalance: BankMoney(value: 200), endingBalance: BankMoney(value: 50), points: points, events: [rent, other], risks: [])
        var adjustments = BankForecastAdjustments()
        adjustments.weeklySpending = 70
        adjustments.corrections[BankForecastAdjustments.seriesKey(rent)] = BankForecastCorrection(excluded: false, amount: 120)
        let result = adjustments.apply(to: source)
        try bankExpect(result.points.map { $0.projectedBalance.value } == [200, 20, 10])
        try bankExpect(result.events.map { $0.amount.value } == [-120, -50])
        adjustments.corrections[BankForecastAdjustments.seriesKey(rent)] = BankForecastCorrection(excluded: true, amount: nil)
        let excluded = adjustments.apply(to: source)
        try bankExpect(excluded.endingBalance.value == 130)
        try bankExpect(excluded.events.count == 1)
        adjustments.weeklySpending = 700
        let risk = adjustments.apply(to: source)
        try bankExpect(risk.risks.first?.date == "2026-11-05")
    }
}

extension BankForecastAdjustmentsTests {
    func manualSchedulesAndDateOverridesCoverBoundariesAndAccountScope() throws {
        let points = ["2028-02-28", "2028-02-29", "2028-03-01", "2028-03-02", "2028-03-03"].map {
            BankForecastPoint(date: $0, projectedBalance: BankMoney(value: 0))
        }
        let event = BankForecastEvent(accountId: "a", currency: "NZD", merchantLogo: nil, date: "2028-02-28", description: "Bill", amount: BankMoney(value: -30), kind: "recurring_charge")
        let source = BankForecast(startDate: points[0].date, endDate: points[4].date, startingBalance: BankMoney(value: 100), endingBalance: BankMoney(value: 70), points: points, events: [event], risks: [])
        var settings = BankForecastAdjustments()
        let correction = BankForecastDateOverride(event: event, date: "2028-03-02")
        settings.dateOverrides = [correction.id: correction]
        settings.manualSchedules = [
            BankManualForecastSchedule(accountId: "a", name: "Salary", amount: 50, isIncome: true, startDate: "2028-02-29", frequency: .monthly),
            BankManualForecastSchedule(accountId: "removed", name: "Other", amount: 500, isIncome: true, startDate: "2028-02-29", frequency: .monthly)
        ]
        let result = settings.apply(to: source, eligibleAccountIDs: ["a"])
        try bankExpect(result.points.map { $0.projectedBalance.value } == [100, 150, 150, 120, 120])
        try bankExpect(result.events.count == 2)
        try bankExpect(result.events.first?.isManual == true)
        try bankExpect(result.upcomingBills.first?.date == "2028-03-02")
        let later = BankForecast(startDate: "2028-02-29", endDate: points[4].date, startingBalance: BankMoney(value: 100), endingBalance: BankMoney(value: 100), points: Array(points.dropFirst()), events: [], risks: [])
        let laterResult = settings.apply(to: later, eligibleAccountIDs: ["a"])
        try bankExpect(laterResult.events.contains { $0.description == "Bill" && $0.date == "2028-03-02" })
        try bankExpect(laterResult.endingBalance.value == 120)
        let hidden = settings.apply(to: later, eligibleAccountIDs: [])
        try bankExpect(hidden.events.isEmpty && hidden.endingBalance.value == 100)
    }

    func manualCalendarSchedulesHandleMonthEndsAndLegacySettings() throws {
        let monthly = BankManualForecastSchedule(accountId: "a", name: "Bill", amount: 20, isIncome: false, startDate: "2028-01-31", frequency: .monthly)
        try bankExpect(monthly.occurs(on: "2028-02-29"))
        try bankExpect(monthly.occurs(on: "2028-03-31"))
        try bankExpect(!monthly.occurs(on: "2028-03-29"))
        let fortnightly = BankManualForecastSchedule(accountId: "a", name: "Pay", amount: 10, isIncome: true, startDate: "2028-02-29", frequency: .fortnightly)
        try bankExpect(fortnightly.occurs(on: "2028-03-14"))
        try bankExpect(!fortnightly.occurs(on: "2028-03-13"))
        let old = Data(#"{"weeklySpending":0,"corrections":{}}"#.utf8)
        let restored = try JSONDecoder().decode(BankForecastAdjustments.self, from: old)
        try bankExpect(restored.manualSchedules == nil && restored.dateOverrides == nil)
        let encoded = try JSONEncoder().encode(monthly)
        let decoded = try JSONDecoder().decode(BankManualForecastSchedule.self, from: encoded)
        try bankExpect(decoded.startDate == "2028-01-31" && decoded.frequency == .monthly)
    }
}
