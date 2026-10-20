import Foundation

/// Recent transactions retain their source currency and optional Akahu merchant logo.
public struct BankTransaction: Decodable, Identifiable, Sendable {
    public let id: String
    public let accountId: String
    public let date: String
    public let description: String
    public let merchant: String?
    public let merchantLogo: String?
    public let category: String?
    public let amount: BankMoney
    public let currency: String

    public var displayName: String { merchant ?? description }
    public var logoURL: URL? {
        guard let merchantLogo, let url = URL(string: merchantLogo), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// Forecast amounts are estimates for NZD checking and savings accounts only.
public struct BankForecast: Decodable, Sendable {
    public let startDate: String
    public let endDate: String
    public let startingBalance: BankMoney
    public let endingBalance: BankMoney
    public let points: [BankForecastPoint]
    public let events: [BankForecastEvent]
    public let risks: [BankForecastRisk]

    public var nextIncome: BankForecastEvent? {
        events.filter { $0.kind == "expected_income" && $0.amount.value > 0 }
            .sorted { $0.date < $1.date }.first
    }

    /// A conservative pay estimate excludes small deposits and obvious non-pay credits.
    public var estimatedPayday: BankForecastEvent? {
        let excluded = ["interest", "dividend", "refund", "cashback", "cash back", "rental", "rent payment"]
        return events.filter { event in
            event.kind == "expected_income" && event.amount.value >= 200 &&
            !excluded.contains { event.description.localizedCaseInsensitiveContains($0) }
        }.sorted { $0.date < $1.date }.first
    }

    public var upcomingBills: [BankForecastEvent] {
        guard let end = BankCalendar.addDays(7, to: startDate) else { return [] }
        return events.filter { $0.kind == "recurring_charge" && $0.date >= startDate && $0.date <= end }
            .sorted { $0.date < $1.date }
    }
}

public struct BankForecastPoint: Decodable, Identifiable, Sendable {
    public let date: String
    public let projectedBalance: BankMoney
    public var id: String { date }
}

public struct BankForecastEvent: Decodable, Sendable {
    public let date: String
    public let description: String
    public let amount: BankMoney
    public let kind: String
}

public struct BankForecastRisk: Decodable, Sendable {
    public let date: String
    public let projectedBalance: BankMoney
    public let reason: String
}

/// Bank dates are calendar days in Auckland, including daylight-saving changes.
public enum BankCalendar {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland") ?? .gmt
        return calendar
    }

    public static func date(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard text.count == 10, let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    public static func day(_ date: Date) -> String { BankDateWindow(now: date).today }

    public static func addDays(_ days: Int, to text: String) -> String? {
        guard let start = date(text), let date = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        return day(date)
    }

    public static func days(from start: String, to end: String) -> Int? {
        guard let start = date(start), let end = date(end) else { return nil }
        return calendar.dateComponents([.day], from: start, to: end).day
    }

    public static func label(_ text: String) -> String {
        guard let date = date(text) else { return text }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_NZ")
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }
}
