import ReckonCore
import ReckonImages
import SwiftUI

struct BankActivityView: View {
    @ObservedObject var store: BankDashboardStore
    @State private var search = ""
    @State private var onlyNew = false

    private var rows: [BankTransaction] {
        let all = onlyNew ? (store.visitSummary?.newTransactions ?? []) : (store.dashboard?.transactions.value ?? [])
        return all.filter { row in
            search.isEmpty || "\(row.displayName) \(row.description) \(row.category ?? "")".localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text("Since you last looked").font(.headline)
                    ReckonInfoHelp(subject: "Activity comparison", explanation: "Compares this visit with the previous one. Activity includes the latest 100 transactions from the last six months, excluding transfers. Newly seen can include older transactions added by the bank. The first visit sets a baseline.")
                }
                if let summary = store.visitSummary {
                    Text(summary.since, format: .dateTime.day().month().hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                    if let change = summary.liquidChange {
                        Text("Liquid balance \(change >= 0 ? "+" : "")\(BankFormatting.money(change))")
                            .font(.callout.weight(.medium)).monospacedDigit()
                    } else { Text("Connected accounts changed; balance comparison unavailable.").font(.caption).foregroundStyle(.secondary) }
                    if let transactions = summary.newTransactions {
                        Text("\(transactions.count) newly seen transactions\(summary.isLimited ? " · latest 100" : "")")
                            .font(.callout)
                        let received = Dictionary(grouping: transactions.filter { $0.amount.value > 0 }, by: \.currency)
                        ForEach(received.keys.sorted(), id: \.self) { currency in
                            let amount = (received[currency] ?? []).reduce(Decimal.zero) { $0 + $1.amount.value }
                            Text("Received \(BankFormatting.money(amount, currency: currency)) \(currency)")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else { Text("Transaction comparison unavailable for this visit.").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("First look · baseline saved")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            TextField("Search recent activity", text: $search).textFieldStyle(.roundedBorder)
            Toggle("Only newly seen", isOn: $onlyNew)
                .disabled(store.visitSummary?.newTransactions == nil).font(.callout)
            if let error = store.dashboard?.transactions.errorMessage {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text("No matching transactions.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .center, spacing: 10) {
                    BankMerchantLogoView(transaction: row)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName).lineLimit(2)
                        Text("\(BankCalendar.label(row.date)) · \(row.category ?? "Uncategorised")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(BankFormatting.money(row.amount.value, currency: row.currency))
                        .font(.callout).monospacedDigit().fixedSize()
                        .foregroundStyle(row.amount.value > 0 ? Color.green : Color.primary)
                }
            }
        }
    }
}

private struct BankMerchantLogoView: View {
    let transaction: BankTransaction
    private var initials: String {
        let words = transaction.displayName.split(separator: " ")
        return words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Group {
            if let url = transaction.logoURL {
                CachedBankImage(url: url) { logo in
                    if let image = logo { image.resizable().scaledToFit().padding(3) }
                    else { Text(initials).font(.caption.weight(.semibold)) }
                }
            } else { Text(initials).font(.caption.weight(.semibold)) }
        }
        .frame(width: 32, height: 32)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7)).clipped().accessibilityHidden(true)
    }
}
