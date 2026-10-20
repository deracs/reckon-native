import AppKit
import ReckonCore
import SwiftUI

private enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case accounts = "Accounts"
    case activity = "Activity"
    case forecast = "Dead reckoning"
    case spending = "The bleed"
    case standingOrders = "Standing orders"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .accounts: "building.columns"
        case .activity: "list.bullet.rectangle"
        case .forecast: "chart.xyaxis.line"
        case .spending: "flame"
        case .standingOrders: "calendar.badge.clock"
        }
    }
}

struct BankDashboardView: View {
    @ObservedObject var store: BankDashboardStore
    let openSettings: () -> Void
    let lockReckon: () -> Void
    let dismissDashboard: () -> Void
    @State private var selectedTab = DashboardTab.overview
    @State private var expandedBanks: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reckon").font(.system(size: 23, weight: .semibold, design: .serif))
                if store.isDemo { Text("SAMPLE DATA").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading stats") }
                Button(action: lockReckon) { Image(systemName: "lock") }
                    .buttonStyle(.plain).help("Lock Reckon").accessibilityLabel("Lock Reckon")
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Settings").accessibilityLabel("Settings")
            }
            .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
            Divider()

            if let dashboard = store.dashboard {
                HStack(spacing: 4) {
                    ForEach(DashboardTab.allCases) { tab in
                        Button { selectedTab = tab } label: {
                            Image(systemName: tab.systemImage).font(.system(size: 17))
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                        .background(selectedTab == tab ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .help(tab.rawValue)
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                    }
                }
                .padding(5).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16).padding(.vertical, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let error = store.loadError {
                            Label("\(error) Showing the last fetched figures.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                        switch selectedTab {
                        case .overview:
                            liquidBalance(dashboard)
                            cashflow(dashboard)
                            freshness(dashboard)
                        case .accounts:
                            accountBalances(dashboard)
                        case .activity:
                            BankActivityView(store: store)
                        case .forecast:
                            BankForecastView(section: dashboard.forecast)
                        case .spending:
                            spending(dashboard)
                        case .standingOrders:
                            BankUpcomingBillsView(section: dashboard.forecast)
                            Divider()
                            standingOrders(dashboard)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selectedTab)
                .frame(height: 500)
            } else {
                emptyDashboard.frame(height: 250)
            }

            Divider()
            HStack {
                Button("Reload stats", systemImage: "arrow.clockwise") { store.reloadDashboard() }
                    .disabled(!store.isConfigured || store.isLoading || store.isDemo)
                    .help("Read the current Akahu data. Bank data refreshes separately.")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.callout)
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 410)
        .background(.regularMaterial)
        .onExitCommand(perform: dismissDashboard)
    }

    @ViewBuilder private var emptyDashboard: some View {
        VStack(spacing: 14) {
            Image(systemName: store.isConfigured ? "chart.bar.xaxis" : "link")
                .font(.system(size: 28)).foregroundStyle(.secondary)
            if store.isLoading {
                Text("Reading Reckon…").font(.headline)
                Text("Balances and stats from your Akahu accounts.").font(.callout).foregroundStyle(.secondary)
            } else if let error = store.loadError ?? store.connectionError {
                Text("Couldn’t read Reckon").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Connection settings", action: openSettings)
            } else {
                Text("Your accounts, at a glance.").font(.headline)
                Text("Connect Akahu to see liquid balance, cashflow, and standing orders.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Connect Akahu", action: openSettings).buttonStyle(.borderedProminent)
            }
        }.padding(24)
    }

    private func liquidBalance(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionHeading("Liquid balance", explanation: "The sum of NZD checking and savings accounts. Investments and foreign-currency accounts are excluded.")
            Text(BankFormatting.money(dashboard.liquidBalance))
                .font(.system(size: 38, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(dashboard.liquidBalance < 0 ? Color.red : Color.primary)
                .textSelection(.enabled)
            Text("NZD").font(.caption).foregroundStyle(.secondary)
            if let change = store.visitSummary?.liquidChange {
                Text("\(change >= 0 ? "+" : "")\(BankFormatting.money(change)) since last look")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            BankPaydayView(forecast: dashboard.forecast).padding(.top, 8)
        }
    }

    private func accountBalances(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Accounts", explanation: "Current balances for all connected accounts at each bank or service, including investments and negative balances. Each currency is totalled separately without conversion. Expand a row to see individual accounts.")
            if dashboard.accounts.isEmpty {
                emptySection("No connected accounts.")
            }
            ForEach(BankAccountGroup.groupAccounts(dashboard.accounts)) { bank in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedBanks.contains(bank.id) },
                    set: { expanded in
                        if expanded { expandedBanks.insert(bank.id) }
                        else { expandedBanks.remove(bank.id) }
                    }
                )) {
                    VStack(spacing: 12) {
                        ForEach(bank.accounts) { account in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).lineLimit(2)
                                    Text([account.type.capitalized, account.currency,
                                          account.status == "inactive" ? "Inactive" : nil]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.secondary)
                                    AccountBalanceHistoryView(samples: store.journal.history(for: account))
                                }
                                Spacer(minLength: 10)
                                Text(BankFormatting.money(account.balance.value, currency: account.currency))
                                    .monospacedDigit().fontWeight(account.contributesToLiquidBalance ? .medium : .regular)
                                    .foregroundStyle(account.contributesToLiquidBalance ? .primary : .secondary)
                                    .fixedSize()
                            }
                        }
                    }
                    .padding(.leading, 8).padding(.top, 10).padding(.bottom, 6)
                } label: {
                    HStack(spacing: 10) {
                        if let account = bank.logoAccount { BankLogoView(account: account) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bank.name).fontWeight(.medium)
                            Text("\(bank.accounts.count) \(bank.accounts.count == 1 ? "account" : "accounts")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 3) {
                            ForEach(bank.currencyBalances) { total in
                                Text("\(BankFormatting.money(total.balance, currency: total.currency)) \(total.currency)")
                                    .font(.callout.weight(.medium)).monospacedDigit().fixedSize()
                                    .foregroundStyle(total.balance < 0 ? Color.red : Color.primary)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .disclosureGroupStyle(BankDisclosureGroupStyle())
                Divider()
            }
        }
    }

    private func cashflow(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("This month", explanation: "Income, spending and net cashflow from the start of this month through today. Inter-account transfers are excluded. Reckon API totals combine currencies without conversion.")
            Text("\(dashboard.window.monthStart) – \(dashboard.window.today)")
                .font(.caption).foregroundStyle(.secondary)
            if let error = dashboard.cashflow.errorMessage {
                sectionError(error)
            } else if let cashflow = dashboard.currentCashflow {
                HStack(spacing: 0) {
                    cashflowMetric("Income", value: cashflow.income.value, dashboard: dashboard)
                    Spacer()
                    cashflowMetric("Spending", value: cashflow.spending.value, dashboard: dashboard)
                    Spacer()
                    cashflowMetric("Net", value: cashflow.net.value, dashboard: dashboard)
                }
                .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else {
                emptySection("No cashflow recorded this month.")
            }
            Text(dashboard.hasMultipleCurrencies ? "Mixed currencies · unconverted" : "NZD")
                .font(.caption2).foregroundStyle(dashboard.hasMultipleCurrencies ? Color.orange : Color.secondary)
        }
    }

    private func cashflowMetric(_ name: String, value: Decimal, dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(BankFormatting.money(value, currency: dashboard.hasMultipleCurrencies ? nil : "NZD", compact: true))
                .font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
                .foregroundStyle(name == "Net" && value < 0 ? Color.red : Color.primary)
        }
    }

    private func spending(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("The bleed", explanation: "The five largest spending categories this month. Comparisons use the previous three full months’ monthly average. Inter-account transfers are excluded.")
            Text(dashboard.hasMultipleCurrencies ? "This month · mixed currencies, unconverted" : "This month · NZD")
                .font(.caption).foregroundStyle(dashboard.hasMultipleCurrencies ? Color.orange : Color.secondary)
            if let error = dashboard.spending.errorMessage {
                sectionError(error)
            } else if let rows = dashboard.spending.value, !rows.isEmpty {
                ForEach(Array(rows.sorted { $0.spent.value > $1.spent.value }.prefix(5).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.category)
                            if let average = dashboard.previousMonthlyAverage(category: row.category), average > 0 {
                                let percent = NSDecimalNumber(decimal: ((row.spent.value - average) / average) * 100).doubleValue
                                Text("\(percent >= 0 ? "+" : "")\(percent.formatted(.number.precision(.fractionLength(0))))% vs avg month")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(BankFormatting.money(row.spent.value, currency: dashboard.hasMultipleCurrencies ? nil : "NZD"))
                            .monospacedDigit().fixedSize()
                    }
                }
                if dashboard.previousSpending.errorMessage != nil {
                    emptySection("Trailing average unavailable.")
                }
            } else {
                emptySection("No spending recorded this month.")
            }
        }
    }

    private func standingOrders(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Standing orders", explanation: "Recurring charges detected over the last six months, with their cadence and average amount per charge. These are detected patterns, not confirmed future payments.")
            Text(dashboard.hasMultipleCurrencies ? "Average charge · mixed currencies, unconverted" : "Average charge · NZD")
                .font(.caption).foregroundStyle(dashboard.hasMultipleCurrencies ? Color.orange : Color.secondary)
            if let error = dashboard.standingOrders.errorMessage {
                sectionError(error)
            } else if let rows = dashboard.standingOrders.value, !rows.isEmpty {
                ForEach(Array(rows.sorted { $0.averageAmount.value > $1.averageAmount.value }.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.merchant).lineLimit(2)
                            Text(row.cadence.capitalized).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(BankFormatting.money(row.averageAmount.value, currency: dashboard.hasMultipleCurrencies ? nil : "NZD"))
                            .monospacedDigit().fixedSize()
                    }
                }
            } else {
                emptySection("No recurring charges detected.")
            }
        }
    }

    private func freshness(_ dashboard: BankDashboard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Data freshness", explanation: "Reckon reads stats every five minutes. Bank data refreshes separately. Freshness uses the latest transaction refresh across connected accounts; expand Bank refresh times to check each account.")
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stats fetched \(dashboard.fetchedAt.formatted(.relative(presentation: .named))).")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = dashboard.freshness.errorMessage {
                        sectionError(error)
                    } else if let rows = dashboard.freshness.value, !rows.isEmpty {
                        DisclosureGroup("Bank refresh times") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(rows, id: \.accountId) { row in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(row.accountName).font(.caption.weight(.medium))
                                        refreshTimestamp("Balance", timestamp: row.balanceRefreshedAt, now: context.date)
                                        refreshTimestamp("Transactions", timestamp: row.transactionsRefreshedAt, now: context.date)
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.callout)
                        let dates = rows.compactMap { AccountFreshness.parseTimestamp($0.transactionsRefreshedAt) }
                        if let latest = dates.max() {
                            let stale = context.date.timeIntervalSince(latest) >= 12 * 3600
                            Label(stale ? "Latest transaction refresh is over 12 hours old." : "Latest transaction refresh is within 12 hours.",
                                  systemImage: stale ? "clock.badge.exclamationmark" : "checkmark.circle")
                                .font(.caption).foregroundStyle(stale ? Color.orange : Color.secondary)
                        } else { emptySection("Transaction refresh time unknown.") }
                    } else { emptySection("Bank refresh times unavailable.") }
                }
            }
        }
    }

    private func refreshTimestamp(_ name: String, timestamp: String?, now: Date) -> some View {
        let date = AccountFreshness.parseTimestamp(timestamp)
        return Text("\(name): \(date?.formatted(.relative(presentation: .named)) ?? "unknown")")
            .font(.caption2)
            .foregroundStyle(date.map { now.timeIntervalSince($0) >= 12 * 3600 } == true ? Color.orange : Color.secondary)
            .help(date?.formatted(date: .complete, time: .shortened) ?? "No source timestamp")
    }

    private func sectionHeading(_ title: String, explanation: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let explanation { ReckonInfoHelp(subject: title, explanation: explanation) }
        }
    }

    private func emptySection(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private func sectionError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}
