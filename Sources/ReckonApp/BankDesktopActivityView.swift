import ReckonCore
import ReckonImages
import SwiftUI

/// Native table selection and sorting operate on the fetched page, with explicit bank and account scope.
struct BankDesktopActivityView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var navigation: ReckonDesktopNavigation
    @State private var sortOrder = [KeyPathComparator(\BankTransaction.date, order: .reverse)]

    private var banks: [BankAccountGroup] { BankAccountGroup.groupAccounts(store.dashboard?.accounts ?? []) }
    private var selectedAccount: BankAccount? { store.dashboard?.accounts.first { $0.id == navigation.accountID } }
    private var selectedBank: BankAccountGroup? {
        banks.first { bank in
            if let account = selectedAccount { return bank.accounts.contains { $0.id == account.id } }
            return bank.id == navigation.bankID
        }
    }
    private var rows: [BankTransaction] {
        let all = navigation.onlyNew ? (store.visitSummary?.newTransactions ?? []) : (store.dashboard?.transactions.value ?? [])
        return BankActivityFilter(search: navigation.search, bankID: navigation.bankID, accountID: navigation.accountID)
            .apply(to: all, accounts: store.dashboard?.accounts ?? []).sorted(using: sortOrder)
    }
    private var selectedTransaction: BankTransaction? { rows.first { $0.id == navigation.transactionID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                accountFilterMenu
                Spacer(minLength: 5)
                Toggle("Only newly seen", isOn: $navigation.onlyNew).toggleStyle(.switch).controlSize(.small)
                    .disabled(store.visitSummary?.newTransactions == nil)
            }.font(.system(size: 12))
            Text("\(rows.count) shown · latest \(store.dashboard?.transactions.value?.count ?? 0) non-transfer transactions · last six months")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = store.dashboard?.transactions.errorMessage { BankDesktopSectionError(message: error) }
            HStack(alignment: .top, spacing: 18) {
                activityTable
                if let transaction = selectedTransaction {
                    Divider()
                    transactionDetails(transaction).frame(width: 226)
                }
            }
            if rows.isEmpty { Text("No matching transactions on this activity page.").font(.callout).foregroundStyle(.secondary) }
            Text("Amounts retain their source currency. No currency conversion.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onChange(of: rows.map(\.id)) {
            if let selected = navigation.transactionID, !rows.contains(where: { $0.id == selected }) { navigation.transactionID = nil }
        }
    }

    private var accountFilterMenu: some View {
        HStack(spacing: 10) {
            if let account = selectedBank?.logoAccount { BankLogoView(account: account) }
            else {
                Image(systemName: "building.2").font(.system(size: 17)).foregroundStyle(ReckonAppearance.accent)
                    .frame(width: 32, height: 32).background(ReckonDesktopAppearance.selection, in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Menu { accountFilterOptions } label: {
                    Text(selectedAccount.map { "\($0.name) · \($0.currency)" } ?? "All accounts")
                }
                .menuStyle(.borderlessButton).font(.system(size: 12, weight: .medium))
                .accessibilityLabel("Filter activity accounts")
                .accessibilityValue("\(selectedBank?.name ?? "All banks"), \(selectedAccount?.name ?? "All accounts")")
                Text(selectedBank?.name ?? "All banks").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 260, alignment: .leading)
        .background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
    }

    @ViewBuilder private var accountFilterOptions: some View {
        Button { selectActivityScope(bankID: nil, accountID: nil) } label: {
            Label("All banks · all accounts", systemImage: navigation.bankID == nil && navigation.accountID == nil ? "checkmark" : "building.2")
        }
        ForEach(banks) { bank in
            Section(bank.name) {
                Button { selectActivityScope(bankID: bank.id, accountID: nil) } label: {
                    Label("All \(bank.name) accounts", systemImage: navigation.bankID == bank.id && navigation.accountID == nil ? "checkmark" : "building.columns")
                }
                ForEach(bank.accounts) { account in
                    Button { selectActivityScope(bankID: bank.id, accountID: account.id) } label: {
                        Label("\(account.name) · \(account.currency)", systemImage: navigation.accountID == account.id ? "checkmark" : "creditcard")
                    }
                }
            }
        }
    }

    private func selectActivityScope(bankID: String?, accountID: String?) {
        navigation.bankID = bankID
        navigation.accountID = accountID
        navigation.transactionID = nil
    }

    private var activityTable: some View {
        Table(rows, selection: $navigation.transactionID, sortOrder: $sortOrder) {
            TableColumn("Merchant", value: \.displayName) { row in
                HStack(spacing: 10) {
                    BankDesktopMerchantIdentity(transaction: row)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(row.category ?? "Uncategorised").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, 5)
            }.width(min: 145, ideal: 220)
            TableColumn("Account") { row in
                if let account = store.dashboard?.accounts.first(where: { $0.id == row.accountId }) {
                    HStack(spacing: 6) {
                        BankLogoView(account: account).scaleEffect(0.65).frame(width: 21, height: 21)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.name).font(.system(size: 11)).lineLimit(1)
                            Text(account.bankName ?? "Other accounts").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else { Text("Unknown account").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.width(min: 95, ideal: 140)
            TableColumn("Date", value: \.date) { row in Text(BankCalendar.label(row.date)).font(.system(size: 11)) }
                .width(min: 85, ideal: 95)
            TableColumn("Amount", value: \.amount.value) { row in
                Text(BankFormatting.money(row.amount.value, currency: row.currency)).font(.system(size: 12, weight: .medium))
                    .monospacedDigit().foregroundStyle(row.amount.value > 0 ? ReckonDesktopAppearance.income : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 100, ideal: 110)
            TableColumn("Currency", value: \.currency) { row in Text(row.currency).font(.system(size: 10)).foregroundStyle(.secondary) }
                .width(55)
        }
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Recent transactions")
    }

    private func transactionDetails(_ transaction: BankTransaction) -> some View {
        let account = store.dashboard?.accounts.first { $0.id == transaction.accountId }
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Transaction").font(.headline)
                    Spacer()
                    Button { navigation.transactionID = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Close transaction details")
                }
                BankDesktopMerchantIdentity(transaction: transaction)
                Text(transaction.displayName).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(BankFormatting.money(transaction.amount.value, currency: transaction.currency))
                    .font(.system(size: 26, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                Divider()
                detail("Date", value: BankCalendar.label(transaction.date))
                detail("Bank", value: account?.bankName ?? "Unknown")
                detail("Account", value: account?.name ?? "Unknown account")
                detail("Currency", value: transaction.currency)
                detail("Category", value: transaction.category ?? "Uncategorised")
                detail("Description", value: transaction.description)
            }.padding(.top, 10).padding(.trailing, 5)
        }
    }

    private func detail(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Merchant logos reuse the image cache, with quiet category identities when no image is available.
struct BankDesktopMerchantIdentity: View {
    let transaction: BankTransaction
    private var symbol: String {
        switch transaction.category?.lowercased() {
        case "groceries": "cart"
        case "cafes", "takeaways", "restaurants": "cup.and.saucer"
        case "income": "arrow.down.left"
        case "transport", "travel": "tram"
        case "utilities", "bills": "bolt"
        default: "creditcard"
        }
    }
    private var color: Color {
        switch transaction.category?.lowercased() {
        case "groceries": ReckonDesktopAppearance.expense
        case "cafes", "takeaways", "restaurants": .orange
        case "income": ReckonDesktopAppearance.income
        default: ReckonAppearance.accent
        }
    }
    var body: some View {
        CachedBankImage(url: transaction.logoURL) { image in
            if let image { image.resizable().scaledToFit().padding(3) }
            else { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(color) }
        }
        .frame(width: 30, height: 30).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
    }
}
