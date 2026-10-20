import Foundation

/// Reporting dates use Auckland time, including month boundaries and daylight saving.
public struct BankDateWindow: Sendable {
    public let month: String
    public let monthStart: String
    public let today: String
    public let previousThreeMonthsStart: String
    public let previousMonthEnd: String
    public let recurringStart: String

    public init(now: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Pacific/Auckland") ?? .gmt
        let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        today = formatter.string(from: now)
        monthStart = formatter.string(from: start)
        month = String(monthStart.prefix(7))
        previousThreeMonthsStart = formatter.string(from: calendar.date(byAdding: .month, value: -3, to: start) ?? start)
        previousMonthEnd = formatter.string(from: calendar.date(byAdding: .day, value: -1, to: start) ?? start)
        recurringStart = formatter.string(from: calendar.date(byAdding: .month, value: -6, to: now) ?? now)
    }

    public func query(from: String, to: String) -> [URLQueryItem] {
        [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
    }
}
