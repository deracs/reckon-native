import ReckonCore
import SwiftUI

struct ManualAccountsView: View {
    @ObservedObject var store: BankDashboardStore
    @State private var editing: ManualFinancialAccount?
    @State private var adding = false
    @State private var deleting: ManualFinancialAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Manual accounts").font(.headline)
                Spacer()
                Button("Add manual account") { adding = true }
            }
            if let error = store.manualAccountsError { BankDesktopSectionError(message: error) }
            if store.manualAccounts.isEmpty { Text("Add KiwiSaver, investments, property or debts.").foregroundStyle(.secondary) }
            ForEach(store.manualAccounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.name).fontWeight(.medium)
                        Text("\(account.kind) · Updated \(account.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(BankFormatting.money(account.balance, currency: account.currency)) \(account.currency)").monospacedDigit()
                    Button("Edit") { editing = account }
                    Button("Delete") { deleting = account }
                }.padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(isPresented: $adding) { ManualAccountEditor(store: store, account: nil) }
        .sheet(item: $editing) { account in ManualAccountEditor(store: store, account: account) }
        .confirmationDialog("Delete this manual account?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete account", role: .destructive) { if let deleting { _ = store.deleteManualAccount(deleting) }; deleting = nil }
        }
    }
}

struct ManualAccountEditor: View {
    @ObservedObject var store: BankDashboardStore
    @Environment(\.dismiss) private var dismiss
    let account: ManualFinancialAccount?
    @State private var name = ""
    @State private var kind = "KiwiSaver"
    @State private var currency = "NZD"
    @State private var balance = ""
    @State private var error: String?
    private let kinds = ["KiwiSaver", "Investment", "Property", "Cash", "Savings", "Debt", "Other asset"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account == nil ? "Add manual account" : "Edit manual account").font(.title2.weight(.semibold))
            TextField("Name", text: $name)
            Picker("Type", selection: $kind) { ForEach(kinds, id: \.self) { Text($0) } }
            TextField("Currency code, e.g. NZD", text: $currency)
            TextField(kind == "Debt" ? "Amount owed" : "Balance", text: $balance)
            Text("Enter a positive amount. Manual balances update only when you change them.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 420)
            .onAppear {
                if let account {
                    name = account.name; kind = account.kind; currency = account.currency
                    balance = NSDecimalNumber(decimal: account.balance).stringValue
                }
            }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanName.isEmpty, code.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
              balance.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else {
            error = "Enter a name, three-letter currency and a positive balance with up to two decimal places."
            return
        }
        var updated = account ?? ManualFinancialAccount(name: cleanName, kind: kind, currency: code, balance: amount)
        if account == nil || updated.balance != amount || updated.currency != code { updated.updatedAt = .now }
        updated.name = cleanName; updated.kind = kind; updated.currency = code; updated.balance = amount
        if store.saveManualAccount(updated) { dismiss() } else { error = store.manualAccountsError }
    }
}

struct NetWorthView: View {
    @ObservedObject var store: BankDashboardStore
    var prominent = false

    private var connected: [BankAccount] { store.dashboard?.accounts ?? [] }
    private var currencies: [String] {
        let values = Set(connected.map(\.currency) + store.manualAccounts.map(\.currency))
        return values.sorted { lhs, rhs in
            if lhs == "NZD" { return rhs != "NZD" }
            if rhs == "NZD" { return false }
            return lhs < rhs
        }
    }
    private func balance(for currency: String) -> Decimal {
        let bank = connected.filter { $0.currency == currency }.reduce(Decimal.zero) { $0 + $1.balance.value }
        let manual = store.manualAccounts.filter { $0.currency == currency }.reduce(Decimal.zero) { $0 + ($1.kind == "Debt" ? -$1.balance : $1.balance) }
        return bank + manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 7 : 8) {
            if prominent {
                HStack(spacing: 6) {
                    Text("NET WORTH").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ReckonInfoHelp(subject: "Net worth", explanation: "Includes connected and manual accounts only. Debts reduce the total. Currencies stay separate and are not converted.")
                }
            } else { Text("Net worth").font(.headline) }
            if let primary = currencies.first {
                Text("\(BankFormatting.money(balance(for: primary), currency: primary))\(prominent ? "" : " \(primary)")")
                    .font(prominent ? .system(size: 44, weight: .semibold) : .body)
                    .monospacedDigit().textSelection(.enabled).lineLimit(1).minimumScaleFactor(0.6)
                    .foregroundStyle(balance(for: primary) < 0 ? Color.red : Color.primary)
                if prominent { Text("\(primary) · connected and manual accounts").font(.system(size: 11)).foregroundStyle(.secondary) }
                ForEach(Array(currencies.dropFirst()), id: \.self) { currency in
                    Text("\(BankFormatting.money(balance(for: currency), currency: currency)) \(currency)")
                        .font(prominent ? .system(size: 11) : .body).monospacedDigit().foregroundStyle(.secondary)
                }
            } else { Text("No accounts added.").foregroundStyle(.secondary) }
            if store.dashboard == nil {
                Text("Connected accounts unavailable. Only manual accounts are included.").font(.caption).foregroundStyle(.orange)
            } else if !prominent {
                Text("Includes connected and manual accounts only. Currencies are kept separate.").font(.caption).foregroundStyle(.secondary)
            } else if currencies.count > 1 {
                Text("Currencies are not converted.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
