import Foundation

extension BankDashboard {
    /// Sample data is explicit and never reads or writes a saved connection.
    public static func sampleDashboard(now: Date = .now) throws -> BankDashboard {
        let decoder = JSONDecoder()
        func decode<Value: Decodable>(_ text: String) throws -> Value {
            try decoder.decode(Value.self, from: Data(text.utf8))
        }
        let window = BankDateWindow(now: now)
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let sampleEvents: [(Int, String, String, String)] = [
            (2, "Power", "-145.70", "recurring_charge"), (5, "Rent", "-600.00", "recurring_charge"),
            (7, "Employer", "6400.00", "expected_income"), (12, "Internet", "-85.00", "recurring_charge"),
            (19, "Rent", "-600.00", "recurring_charge")]
        let events = sampleEvents.map { offset, name, amount, kind in
            "{\"date\":\"\(BankCalendar.addDays(offset, to: window.today) ?? window.today)\",\"description\":\"\(name)\",\"amount\":\"\(amount)\",\"kind\":\"\(kind)\"}"
        }.joined(separator: ",")
        var balance = Decimal(string: "12480.45") ?? 0
        let points = (0...30).map { offset in
            for event in sampleEvents where event.0 == offset { balance += Decimal(string: event.2) ?? 0 }
            return "{\"date\":\"\(BankCalendar.addDays(offset, to: window.today) ?? window.today)\",\"projectedBalance\":\"\(balance)\"}"
        }.joined(separator: ",")
        let forecastJSON = "{\"startDate\":\"\(window.today)\",\"endDate\":\"\(BankCalendar.addDays(30, to: window.today) ?? window.today)\",\"startingBalance\":\"12480.45\",\"endingBalance\":\"\(balance)\",\"points\":[\(points)],\"events\":[\(events)],\"risks\":[]}"
        return try BankDashboard(
            accounts: decode(#"[{"id":"spending","name":"Everyday","type":"checking","currency":"NZD","balance":"2480.45","bankName":"Sample Bank","status":"active"},{"id":"savings","name":"Rainy day","type":"savings","currency":"NZD","balance":"10000.00","bankName":"Sample Bank","status":"active"},{"id":"investment","name":"Long term","type":"investment","currency":"NZD","balance":"28400.25","bankName":"Sample Investments"}]"#),
            cashflow: .loaded(decode("""
            [{"month":"\(window.month)","income":"6400.00","spending":"3820.65","net":"2579.35","transactionCount":82}]
            """)),
            spending: .loaded(decode(#"[{"category":"Groceries","spent":"645.30","transactionCount":14},{"category":"Rent","spent":"1800.00","transactionCount":3},{"category":"Takeaways","spent":"180.00","transactionCount":9}]"#)),
            previousSpending: .loaded(decode(#"[{"category":"Groceries","spent":"1800.00","transactionCount":39},{"category":"Rent","spent":"5400.00","transactionCount":9},{"category":"Takeaways","spent":"457.62","transactionCount":23}]"#)),
            standingOrders: .loaded(decode(#"[{"merchant":"Rent","cadence":"weekly","occurrences":24,"averageAmount":"600.00","lastDate":"2026-10-19"},{"merchant":"Power","cadence":"monthly","occurrences":6,"averageAmount":"145.70","lastDate":"2026-10-12"},{"merchant":"Internet","cadence":"monthly","occurrences":6,"averageAmount":"85.00","lastDate":"2026-10-10"}]"#)),
            freshness: .loaded(decode("""
            [{"accountId":"spending","accountName":"Everyday","balanceRefreshedAt":"\(timestamp)","transactionsRefreshedAt":"\(timestamp)"},{"accountId":"savings","accountName":"Rainy day","balanceRefreshedAt":"\(timestamp)","transactionsRefreshedAt":"\(timestamp)"}]
            """)),
            window: window,
            fetchedAt: now,
            transactions: .loaded(decode("""
            [{"id":"sample-1","accountId":"spending","date":"\(window.today)","description":"Weekly shop","merchant":"Grocer","category":"Groceries","amount":"-86.40","currency":"NZD"},
             {"id":"sample-2","accountId":"spending","date":"\(window.today)","description":"Coffee","merchant":"Corner café","category":"Cafes","amount":"-6.50","currency":"NZD"},
             {"id":"sample-3","accountId":"spending","date":"\(window.monthStart)","description":"Salary","merchant":"Employer","category":"Income","amount":"6400.00","currency":"NZD"}]
            """)),
            forecast: .loaded(decode(forecastJSON))
        )
    }
}
