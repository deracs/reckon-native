import ReckonCore
import SwiftUI

/// The desktop overview uses the same snapshot and currency rules as the menu-bar dashboard.
struct BankDesktopOverviewView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var navigation: ReckonDesktopNavigation

    var body: some View {
        if let dashboard = store.dashboard {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 24) {
                        balance(dashboard)
                        if let forecast = dashboard.forecast.value { BankDesktopForecastChart(forecast: forecast) }
                        else { BankDesktopSectionError(message: dashboard.forecast.errorMessage ?? "Forecast unavailable.") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(.primary.opacity(0.1)).frame(width: 1).frame(height: 412)
                    VStack(alignment: .leading, spacing: 22) {
                        cashflow(dashboard)
                        Divider()
                        comingUp(dashboard)
                    }
                    .frame(width: 238, alignment: .leading)
                }
                Divider()
                recentActivity(dashboard)
                sourceFreshness(dashboard)
            }
        }
    }

    private func balance(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("LIQUID BALANCE").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ReckonInfoHelp(subject: "Liquid balance", explanation: "NZD checking and savings only. Investments and foreign-currency accounts are excluded.")
            }
            Text(BankFormatting.money(dashboard.liquidBalance))
                .font(.system(size: 44, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                .foregroundStyle(dashboard.liquidBalance < 0 ? .red : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 10) {
                Text("NZD · checking and savings")
                if let change = store.visitSummary?.liquidChange {
                    Text("\(change >= 0 ? "+" : "")\(BankFormatting.money(change)) since last look")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cashflow(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This month").font(.system(size: 18, weight: .semibold))
            Text(dashboard.hasMultipleCurrencies ? "Mixed currencies · unconverted" : "\(dashboard.window.month) · NZD")
                .font(.system(size: 11)).foregroundStyle(dashboard.hasMultipleCurrencies ? .orange : Color.secondary)
            if let cashflow = dashboard.currentCashflow {
                metric("Income", value: cashflow.income.value, color: ReckonDesktopAppearance.income, dashboard: dashboard)
                Divider()
                metric("Spending", value: cashflow.spending.value, color: ReckonDesktopAppearance.expense, dashboard: dashboard)
                Divider()
                metric("Net", value: cashflow.net.value, color: .primary, dashboard: dashboard)
            } else if let error = dashboard.cashflow.errorMessage { BankDesktopSectionError(message: error) }
            else { Text("No cashflow recorded this month.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func metric(_ label: String, value: Decimal, color: Color, dashboard: BankDashboard) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(BankFormatting.money(value, currency: dashboard.hasMultipleCurrencies ? nil : "NZD", compact: true))
                .font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func comingUp(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Coming up").font(.system(size: 18, weight: .semibold))
            if let forecast = dashboard.forecast.value {
                if let payday = forecast.estimatedPayday {
                    eventRow("Estimated payday", date: payday.date, amount: payday.amount.value, image: "calendar", income: true)
                    Divider()
                } else { Text("No likely payday detected.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(forecast.upcomingBills.prefix(3).enumerated()), id: \.offset) { _, bill in
                    eventRow(bill.description, date: bill.date, amount: abs(bill.amount.value), image: "calendar.badge.clock", income: false)
                }
                if forecast.upcomingBills.isEmpty { Text("No bills expected in the next 7 days.").font(.caption).foregroundStyle(.secondary) }
                Text("Estimates · NZD").font(.system(size: 10)).foregroundStyle(.secondary)
            } else { BankDesktopSectionError(message: dashboard.forecast.errorMessage ?? "Upcoming events unavailable.") }
        }
    }

    private func eventRow(_ title: String, date: String, amount: Decimal, image: String, income: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: image).font(.system(size: 17)).foregroundStyle(income ? ReckonAppearance.accent : Color.orange)
                .frame(width: 32, height: 32).background((income ? ReckonAppearance.accent : Color.orange).opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(BankCalendar.label(date)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Text("\(income ? "+" : "")\(BankFormatting.money(amount))").font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }

    private func recentActivity(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent activity").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("View all") { navigation.selectSection(.activity) }.buttonStyle(.plain).foregroundStyle(ReckonAppearance.accent)
            }
            if let error = dashboard.transactions.errorMessage { BankDesktopSectionError(message: error) }
            else if let rows = dashboard.transactions.value, !rows.isEmpty {
                HStack {
                    Text("Merchant").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Account").frame(width: 120, alignment: .leading)
                    Text("Date").frame(width: 88, alignment: .leading)
                    Text("Amount").frame(width: 110, alignment: .trailing)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(rows.prefix(4)) { row in
                    Button {
                        navigation.selectSection(.activity)
                        navigation.search = ""
                        navigation.onlyNew = false
                        navigation.transactionID = row.id
                    } label: {
                        HStack(spacing: 10) {
                            BankDesktopMerchantIdentity(transaction: row)
                            Text(row.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text(dashboard.accounts.first { $0.id == row.accountId }?.name ?? "Unknown account")
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
                            Text(BankCalendar.label(row.date)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(BankFormatting.money(row.amount.value, currency: row.currency)).fontWeight(.medium)
                                Text(row.currency).font(.system(size: 9)).foregroundStyle(.secondary)
                            }.font(.system(size: 12)).monospacedDigit().frame(width: 110, alignment: .trailing)
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
                if (dashboard.transactions.value?.count ?? 0) >= 100 {
                    Text("Latest 100 non-transfer transactions.").font(.caption).foregroundStyle(.secondary)
                }
            } else { Text("No recent transactions.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private func sourceFreshness(_ dashboard: BankDashboard) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                if let error = dashboard.freshness.errorMessage { BankDesktopSectionError(message: error) }
                else if let rows = dashboard.freshness.value, !rows.isEmpty {
                    let latest = rows.compactMap { AccountFreshness.parseTimestamp($0.transactionsRefreshedAt) }.max()
                    if let latest {
                        let stale = context.date.timeIntervalSince(latest) >= 12 * 3600
                        Label(stale ? "Latest bank transaction refresh is over 12 hours old." : "Latest bank transaction refresh is within 12 hours.",
                              systemImage: stale ? "clock.badge.exclamationmark" : "checkmark.circle")
                            .foregroundStyle(stale ? Color.orange : Color.secondary)
                    } else { Text("Transaction refresh time unknown.").foregroundStyle(.orange) }
                    DisclosureGroup("Bank refresh times") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(rows, id: \.accountId) { row in
                                HStack(alignment: .top) {
                                    Text(row.accountName)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        refreshTimestamp("Balance", timestamp: row.balanceRefreshedAt, now: context.date)
                                        refreshTimestamp("Transactions", timestamp: row.transactionsRefreshedAt, now: context.date)
                                    }
                                }
                            }
                        }.padding(.top, 10)
                    }
                } else { Text("Bank refresh times unavailable.").foregroundStyle(.secondary) }
            }
        }.font(.system(size: 11))
    }

    private func refreshTimestamp(_ name: String, timestamp: String?, now: Date) -> some View {
        let date = AccountFreshness.parseTimestamp(timestamp)
        return Text("\(name): \(date?.formatted(.relative(presentation: .named)) ?? "unknown")")
            .foregroundStyle(date.map { now.timeIntervalSince($0) >= 12 * 3600 } == true ? Color.orange : Color.secondary)
            .help(date?.formatted(date: .complete, time: .shortened) ?? "No source timestamp")
    }
}
