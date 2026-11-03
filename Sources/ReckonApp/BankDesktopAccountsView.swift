import ReckonCore
import SwiftUI

/// Bank and account navigation preserves separate currency balances and opens scoped activity.
struct BankDesktopAccountsView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var navigation: ReckonDesktopNavigation
    private var banks: [BankAccountGroup] {
        BankAccountGroup.groupAccounts(store.dashboard?.accounts ?? []).filter { navigation.bankID == nil || $0.id == navigation.bankID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if navigation.bankID != nil {
                Button("Show all banks") { navigation.bankID = nil; navigation.accountID = nil }.buttonStyle(.borderless)
            }
            ForEach(banks) { bank in
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        if let account = bank.logoAccount { BankLogoView(account: account) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bank.name).font(.system(size: 18, weight: .semibold))
                            Text("\(bank.accounts.count) \(bank.accounts.count == 1 ? "account" : "accounts")").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(bank.currencyBalances) { total in
                                Text("\(BankFormatting.money(total.balance, currency: total.currency)) \(total.currency)")
                                    .font(.system(size: 15, weight: .medium)).monospacedDigit()
                            }
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(bank.accounts) { account in accountCard(account) }
                    }
                    Divider()
                    if navigation.bankID != nil { BankDesktopBankActivityView(store: store, navigation: navigation, bank: bank) }
                }
            }
            if banks.isEmpty { Text("No connected accounts.").foregroundStyle(.secondary) }
            if navigation.bankID == nil { Divider(); ManualAccountsView(store: store); Divider(); SavingsGoalsView(store: store) }
            Text("Each currency is totalled separately. Click an account for its recent activity.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountCard(_ account: BankAccount) -> some View {
        Button { navigation.selectAccount(account.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(account.name).font(.system(size: 14, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }
                Text("\(account.type.capitalized) · \(account.currency)\(account.status == "inactive" ? " · Inactive" : "")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text(BankFormatting.money(account.balance.value, currency: account.currency))
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(account.balance.value < 0 ? .red : Color.primary)
                let history = store.journal.history(for: account)
                if history.count >= 2 {
                    BankLineChart(points: history.compactMap { sample in
                        BankCalendar.date(sample.day).map { BankChartPoint(id: sample.day, date: $0, balance: sample.balance) }
                    }, compact: true).frame(height: 44)
                    Text("\(history.count) daily observations").font(.system(size: 10)).foregroundStyle(.secondary)
                } else { Text("History starts today").font(.caption).foregroundStyle(.secondary).frame(height: 44) }
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).accessibilityLabel("\(account.name), \(account.currency). Show account activity")
    }
}
