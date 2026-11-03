import Foundation

/// A correction applies to one detected account, currency, direction and merchant series.
public struct BankForecastCorrection: Codable, Sendable {
    public var excluded: Bool
    public var amount: Decimal?
    public init(excluded: Bool, amount: Decimal?) { self.excluded = excluded; self.amount = amount }
}

/// A date correction moves one detected occurrence, leaving the rest of its series unchanged.
public struct BankForecastDateOverride: Codable, Identifiable, Sendable {
    public let id: String
    public let accountId: String?
    public let currency: String?
    public let merchantLogo: String?
    public let originalDate: String
    public var date: String
    public let description: String
    public let amount: Decimal
    public let kind: String

    public init(event: BankForecastEvent, date: String) {
        id = BankForecastAdjustments.occurrenceKey(event)
        accountId = event.accountId; currency = event.currency; merchantLogo = event.merchantLogo
        originalDate = event.date; self.date = date; description = event.description
        amount = event.amount.value; kind = event.kind
    }

    public var originalEvent: BankForecastEvent {
        BankForecastEvent(accountId: accountId, currency: currency, merchantLogo: merchantLogo,
                          date: originalDate, description: description, amount: BankMoney(value: amount), kind: kind)
    }
}

/// A manual schedule starts on an Auckland calendar day and uses calendar months for monthly intervals.
public struct BankManualForecastSchedule: Codable, Identifiable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case weekly, fortnightly, monthly, quarterly, yearly
    }
    public var id: UUID
    public var accountId: String
    public var name: String
    public var amount: Decimal
    public var isIncome: Bool
    public var startDate: String
    public var frequency: Frequency

    public init(id: UUID = UUID(), accountId: String, name: String, amount: Decimal, isIncome: Bool, startDate: String, frequency: Frequency) {
        self.id = id; self.accountId = accountId; self.name = name; self.amount = amount
        self.isIncome = isIncome; self.startDate = startDate; self.frequency = frequency
    }

    public func occurs(on day: String) -> Bool {
        guard let start = BankCalendar.date(startDate), let date = BankCalendar.date(day), date >= start else { return false }
        let calendar = BankCalendar.calendar
        switch frequency {
        case .weekly, .fortnightly:
            let days = calendar.dateComponents([.day], from: start, to: date).day ?? -1
            return days >= 0 && days % (frequency == .weekly ? 7 : 14) == 0
        case .monthly, .quarterly, .yearly:
            let months = (calendar.component(.year, from: date) - calendar.component(.year, from: start)) * 12
                + calendar.component(.month, from: date) - calendar.component(.month, from: start)
            let interval = frequency == .monthly ? 1 : frequency == .quarterly ? 3 : 12
            guard months >= 0, months % interval == 0,
                  let occurrence = calendar.date(byAdding: .month, value: months, to: start) else { return false }
            return calendar.isDate(occurrence, inSameDayAs: date)
        }
    }
}

/// User-entered weekly spending excludes the bills already represented by forecast events.
public struct BankForecastAdjustments: Codable, Sendable {
    public var weeklySpending: Decimal = 0
    public var corrections: [String: BankForecastCorrection] = [:]
    public var dateOverrides: [String: BankForecastDateOverride]?
    public var manualSchedules: [BankManualForecastSchedule]?
    public init() {}

    public static func seriesKey(_ event: BankForecastEvent) -> String {
        [event.accountId ?? "", event.currency ?? "", event.kind, event.description].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public static func occurrenceKey(_ event: BankForecastEvent) -> String {
        seriesKey(event) + "\(event.date.utf8.count):\(event.date)"
    }

    public func apply(to forecast: BankForecast, eligibleAccountIDs: Set<String>? = nil) -> BankForecast {
        let overrides = dateOverrides ?? [:]
        var sourceEvents = forecast.events
        let known = Set(sourceEvents.map(Self.occurrenceKey))
        for override in overrides.values where !known.contains(override.id) && override.date >= forecast.startDate && override.date <= forecast.endDate {
            if let eligibleAccountIDs, let accountId = override.accountId, !eligibleAccountIDs.contains(accountId) { continue }
            sourceEvents.append(override.originalEvent)
        }
        var events = sourceEvents.compactMap { event -> BankForecastEvent? in
            let correction = corrections[Self.seriesKey(event)]
            if correction?.excluded == true { return nil }
            let amount = correction?.amount.map { event.amount.value < 0 ? -$0 : $0 } ?? event.amount.value
            let date = overrides[Self.occurrenceKey(event)]?.date ?? event.date
            guard date >= forecast.startDate, date <= forecast.endDate else { return nil }
            return BankForecastEvent(accountId: event.accountId, currency: event.currency, merchantLogo: event.merchantLogo,
                                     date: date, description: event.description, amount: BankMoney(value: amount), kind: event.kind)
        }
        for schedule in manualSchedules ?? [] {
            if let eligibleAccountIDs, !eligibleAccountIDs.contains(schedule.accountId) { continue }
            for point in forecast.points where schedule.occurs(on: point.date) {
                events.append(BankForecastEvent(accountId: schedule.accountId, currency: "NZD", merchantLogo: nil,
                    date: point.date, description: schedule.name, amount: BankMoney(value: schedule.isIncome ? schedule.amount : -schedule.amount),
                    kind: schedule.isIncome ? "expected_income" : "recurring_charge", isManual: true))
            }
        }
        events.sort { $0.date < $1.date }
        var balance = forecast.startingBalance.value
        var points: [BankForecastPoint] = []
        var risks: [BankForecastRisk] = []
        for (index, point) in forecast.points.enumerated() {
            balance += events.filter { $0.date == point.date }.reduce(Decimal.zero) { $0 + $1.amount.value }
            if index > 0 { balance -= weeklySpending / 7 }
            points.append(BankForecastPoint(date: point.date, projectedBalance: BankMoney(value: balance)))
            if balance < 0 { risks.append(BankForecastRisk(date: point.date, projectedBalance: BankMoney(value: balance), reason: "Projected balance crosses zero")) }
        }
        return BankForecast(startDate: forecast.startDate, endDate: forecast.endDate, startingBalance: forecast.startingBalance,
                            endingBalance: BankMoney(value: balance), points: points, events: events, risks: risks)
    }
}
