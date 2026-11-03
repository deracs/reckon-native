import ReckonCore
import SwiftUI

/// Upcoming estimates and detected recurring charges remain distinct from confirmed payments.
struct BankDesktopBillsView: View {
    let dashboard: BankDashboard
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            BankUpcomingBillsView(section: dashboard.forecast).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Text("Standing orders").font(.system(size: 22, weight: .semibold))
            Text("Detected over six months · average charge · \(dashboard.hasMultipleCurrencies ? "mixed currencies, unconverted" : "NZD")")
                .font(.callout).foregroundStyle(dashboard.hasMultipleCurrencies ? .orange : Color.secondary)
            if let error = dashboard.standingOrders.errorMessage { BankDesktopSectionError(message: error) }
            else if let rows = dashboard.standingOrders.value, !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 20) {
                    GridRow { Text("Merchant"); Text("Cadence"); Text("Observed"); Text("Average charge") }
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(rows.sorted { $0.averageAmount.value > $1.averageAmount.value }.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.merchant).fontWeight(.medium)
                                if let category = row.category { Text(category).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.cadence.capitalized)
                            Text("\(row.occurrences) times").foregroundStyle(.secondary)
                            Text(BankFormatting.money(row.averageAmount.value, currency: dashboard.hasMultipleCurrencies ? nil : "NZD")).monospacedDigit()
                        }.font(.callout)
                    }
                }
                Text("Detected patterns are estimates, not confirmed future payments.").font(.caption).foregroundStyle(.secondary)
            } else { Text("No recurring charges detected.").foregroundStyle(.secondary) }
        }
    }
}
