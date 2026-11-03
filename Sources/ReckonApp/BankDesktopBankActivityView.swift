import ReckonCore
import SwiftUI

/// Shows the selected bank's transactions from the shared recent activity page.
struct BankDesktopBankActivityView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var navigation: ReckonDesktopNavigation
    let bank: BankAccountGroup

    private var rows: [BankTransaction] {
        let accounts = Set(bank.accounts.map(\.id))
        return (store.dashboard?.transactions.value ?? []).filter { accounts.contains($0.accountId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent activity").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button("View in Activity") { openActivity() }
                    .buttonStyle(.plain).foregroundStyle(ReckonAppearance.accent)
            }
            Text("\(rows.count) shown · from the latest 100 non-transfer transactions across all accounts · last six months")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = store.dashboard?.transactions.errorMessage {
                BankDesktopSectionError(message: error)
            } else if rows.isEmpty {
                Text("No recent transactions for this bank in the current activity page.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Merchant").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Account").frame(width: 120, alignment: .leading)
                    Text("Date").frame(width: 88, alignment: .leading)
                    Text("Amount").frame(width: 110, alignment: .trailing)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        Button { openActivity(transactionID: row.id) } label: {
                            HStack(spacing: 10) {
                                BankDesktopMerchantIdentity(transaction: row)
                                Text(row.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(bank.accounts.first { $0.id == row.accountId }?.name ?? "Unknown account")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
                                Text(BankCalendar.label(row.date)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 88, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(BankFormatting.money(row.amount.value, currency: row.currency)).fontWeight(.medium)
                                    Text(row.currency).font(.system(size: 9)).foregroundStyle(.secondary)
                                }.font(.system(size: 12)).monospacedDigit().frame(width: 110, alignment: .trailing)
                            }.padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
    }

    private func openActivity(transactionID: String? = nil) {
        navigation.bankID = bank.id
        navigation.accountID = nil
        navigation.search = ""
        navigation.onlyNew = false
        navigation.transactionID = transactionID
        navigation.section = .activity
    }
}
