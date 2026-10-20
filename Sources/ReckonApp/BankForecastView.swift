import ReckonCore
import SwiftUI

struct BankForecastView: View {
    let section: BankSection<BankForecast>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text("Dead reckoning").font(.system(.title2, design: .serif).weight(.semibold))
                ReckonInfoHelp(subject: "Dead reckoning", explanation: "A 30-day estimate for NZD checking and savings, based on detected regular income and bills. Everyday spending and unexpected payments are not included. Hover or drag across the chart to inspect a day.")
            }
            if let forecast = section.value {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("In 30 days · estimated").font(.caption).foregroundStyle(.secondary)
                        Text(BankFormatting.money(forecast.endingBalance.value))
                            .font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                }
                BankLineChart(points: forecast.points.compactMap { point in
                    BankCalendar.date(point.date).map { BankChartPoint(id: point.date, date: $0, balance: point.projectedBalance.value) }
                }).frame(height: 170)
                Text("NZD · excludes everyday spending")
                    .font(.caption2).foregroundStyle(.secondary)
                if let risk = forecast.risks.first {
                    Label("Could fall below zero on \(BankCalendar.label(risk.date)): \(BankFormatting.money(risk.projectedBalance.value)).",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                Divider()
                BankPaydayView(forecast: section)
            } else {
                Label(section.errorMessage ?? "Dead reckoning unavailable.", systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct BankPaydayView: View {
    let forecast: BankSection<BankForecast>

    var body: some View {
        if let forecast = forecast.value {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text("Estimated payday").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ReckonInfoHelp(subject: "Estimated payday", explanation: "Recurring deposits of at least NZ$200 in the next 30 days. Interest, dividends, refunds, cashback and rental payments are excluded. This is an estimate, not a confirmed salary payment.")
                    }
                    if let income = forecast.estimatedPayday {
                        let days = BankCalendar.days(from: forecast.startDate, to: income.date) ?? 0
                        Text("\(days == 0 ? "Today" : "In \(days) days") · \(BankFormatting.money(income.amount.value))")
                            .font(.callout.weight(.medium)).monospacedDigit()
                        Text("\(income.description) · \(BankCalendar.label(income.date))")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("No likely payday detected in the next 30 days.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct BankUpcomingBillsView: View {
    let section: BankSection<BankForecast>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Next 7 days").font(.headline)
                ReckonInfoHelp(subject: "Upcoming standing orders", explanation: "Bills expected in the next seven days, estimated from previous charges in NZD checking and savings accounts. Actual payment dates and amounts may differ.")
            }
            Text("Estimated · NZD").font(.caption2).foregroundStyle(.secondary)
            if let forecast = section.value {
                if forecast.upcomingBills.isEmpty {
                    Text("No standing orders expected in this window.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(forecast.upcomingBills.enumerated()), id: \.offset) { _, bill in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bill.description).lineLimit(2)
                            Text(BankCalendar.label(bill.date)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(BankFormatting.money(abs(bill.amount.value))).monospacedDigit().fixedSize()
                    }
                }
            } else {
                Text(section.errorMessage ?? "Upcoming bills unavailable.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
