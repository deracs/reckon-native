import Charts
import ReckonCore
import SwiftUI

/// Category comparisons retain the backend's mixed-currency warning and three-full-month average.
struct BankDesktopSpendingView: View {
    let dashboard: BankDashboard
    private var rows: [CategorySpending] { Array((dashboard.spending.value ?? []).sorted { $0.spent.value > $1.spent.value }.prefix(5)) }
    private var currency: String? { dashboard.hasMultipleCurrencies ? nil : "NZD" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("The bleed").font(.system(size: 22, weight: .semibold))
            Text("Five largest categories this month · \(dashboard.hasMultipleCurrencies ? "mixed currencies, unconverted" : "NZD")")
                .font(.callout).foregroundStyle(dashboard.hasMultipleCurrencies ? .orange : Color.secondary)
            if let error = dashboard.spending.errorMessage { BankDesktopSectionError(message: error) }
            else if rows.isEmpty { Text("No spending recorded this month.").foregroundStyle(.secondary) }
            else {
                Chart(Array(rows.enumerated()), id: \.offset) { _, row in
                    BarMark(x: .value("Spent", NSDecimalNumber(decimal: row.spent.value).doubleValue), y: .value("Category", row.category))
                        .foregroundStyle(ReckonAppearance.accent).cornerRadius(4)
                }.frame(height: CGFloat(rows.count * 48)).padding(.trailing, 12)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 20) {
                    GridRow {
                        Text("Category")
                        Text("This month")
                        Text("Average month")
                        Text("vs average")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.category).frame(maxWidth: .infinity, alignment: .leading)
                            Text(BankFormatting.money(row.spent.value, currency: currency)).monospacedDigit()
                            if let average = dashboard.previousMonthlyAverage(category: row.category) {
                                Text(BankFormatting.money(average, currency: currency)).monospacedDigit()
                                if average > 0 {
                                    let percent = NSDecimalNumber(decimal: (row.spent.value - average) / average * 100).doubleValue
                                    Text("\(percent >= 0 ? "+" : "")\(percent.formatted(.number.precision(.fractionLength(0))))%")
                                        .foregroundStyle(percent > 0 ? ReckonDesktopAppearance.expense : ReckonDesktopAppearance.income)
                                } else { Text("—").foregroundStyle(.secondary) }
                            } else { Text("Unavailable"); Text("—") }
                        }.font(.callout)
                    }
                }
                Text("Average month uses the previous three full months. Transfers are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = dashboard.previousSpending.errorMessage { BankDesktopSectionError(message: error) }
            }
        }
    }
}
