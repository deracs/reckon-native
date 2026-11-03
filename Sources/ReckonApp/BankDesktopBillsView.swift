import ReckonCore
import ReckonImages
import SwiftUI

/// Upcoming NZD estimates and account-scoped recurring payments remain distinct from confirmed payments.
struct BankDesktopBillsView: View {
    let dashboard: BankDashboard
    let forecast: BankSection<BankForecast>
    private var recurring: [StandingOrder] { (dashboard.standingOrders.value ?? []).sorted { $0.averageAmount.value > $1.averageAmount.value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            upcomingPayments
            recurringPayments
        }
        .frame(maxWidth: 1040, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var upcomingPayments: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Next 7 days").font(.system(size: 18, weight: .semibold))
                        Text("Estimated").font(.system(size: 10, weight: .medium)).foregroundStyle(ReckonAppearance.accent)
                            .padding(.horizontal, 7).padding(.vertical, 4).background(.white.opacity(0.8), in: Capsule())
                    }
                    Text("NZD checking and savings · dates and amounts may change")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 20)
                if let forecast = forecast.value {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(BankFormatting.money(forecast.upcomingBills.reduce(Decimal.zero) { $0 + abs($1.amount.value) }))
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                        Text("\(forecast.upcomingBills.count) expected \(forecast.upcomingBills.count == 1 ? "payment" : "payments") · NZD")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if let forecast = forecast.value {
                if forecast.upcomingBills.isEmpty {
                    Label("No payments expected in the next seven days.", systemImage: "calendar.badge.checkmark")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                VStack(spacing: 0) {
                    ForEach(Array(forecast.upcomingBills.enumerated()), id: \.offset) { index, bill in
                        if index > 0 { Divider() }
                        HStack(spacing: 14) {
                            let dateParts = BankCalendar.label(bill.date).split(separator: " ", maxSplits: 1)
                            VStack(spacing: 3) {
                                Text(dateParts.first.map(String.init) ?? "").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                                Text(dateParts.dropFirst().joined(separator: " ")).font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 58, height: 44).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                            let source = recurring.first { $0.accountId == bill.accountId && $0.merchant == bill.description }
                            BankBillMerchantIcon(name: bill.description, category: source?.category, logo: bill.merchantLogo)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(bill.description).font(.system(size: 13, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                accountLabel(bill.accountId, compact: true)
                                if bill.isManual == true { Text("Manual estimate").font(.system(size: 10)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 12)
                            Text(BankFormatting.money(abs(bill.amount.value)))
                                .font(.system(size: 15, weight: .semibold)).monospacedDigit().fixedSize()
                        }.padding(.vertical, 6)
                    }
                }
            } else { BankDesktopSectionError(message: forecast.errorMessage ?? "Upcoming bills unavailable.") }
        }
        .padding(20)
        .background(ReckonDesktopAppearance.selection.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ReckonAppearance.accent.opacity(0.08)))
    }

    private var recurringPayments: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recurring payments").font(.system(size: 20, weight: .semibold))
                Spacer()
                if dashboard.standingOrders.value != nil {
                    Text("\(recurring.count) detected").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Text("Patterns from the last six months · average per payment, not confirmed future bills")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let error = dashboard.standingOrders.errorMessage { BankDesktopSectionError(message: error) }
            else if recurring.isEmpty {
                Label("No recurring payment patterns detected yet.", systemImage: "repeat")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                if recurring.contains(where: { $0.currency == nil }), dashboard.hasMultipleCurrencies {
                    BankDesktopSectionError(message: "Some legacy amounts combine currencies without conversion. Reload stats to read account-specific patterns.")
                }
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 0) {
                    GridRow {
                        Text("Merchant").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Paid from").frame(width: 178, alignment: .leading)
                        Text("Frequency").frame(width: 94, alignment: .leading)
                        Text("Average charge").frame(width: 112, alignment: .trailing).gridColumnAlignment(.trailing)
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 10)
                    GridRow { Divider().gridCellColumns(4) }
                    ForEach(Array(recurring.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            HStack(spacing: 10) {
                                BankBillMerchantIcon(name: row.merchant, category: row.category, logo: row.merchantLogo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.merchant).font(.system(size: 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    if let category = row.category { Text(category).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).help(category) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            accountLabel(row.accountId, compact: false).frame(width: 178, alignment: .leading)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.cadence.capitalized).font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 3).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
                                Text("Seen \(row.occurrences) times").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(BankFormatting.money(row.averageAmount.value, currency: row.currency ?? (dashboard.hasMultipleCurrencies ? nil : dashboard.accounts.first?.currency)))
                                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                                Text(row.currency ?? (dashboard.hasMultipleCurrencies ? "Unconverted" : dashboard.accounts.first?.currency ?? "Currency unknown"))
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(width: 112, alignment: .trailing)
                        }.padding(.vertical, 13)
                        GridRow { Divider().gridCellColumns(4) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func accountLabel(_ id: String?, compact: Bool) -> some View {
        if let account = dashboard.accounts.first(where: { $0.id == id }) {
            HStack(spacing: 6) {
                BankLogoView(account: account).scaleEffect(compact ? 0.5 : 0.75).frame(width: compact ? 16 : 24, height: compact ? 16 : 24)
                if compact {
                    Text("\(account.bankName ?? "Other accounts") · \(account.name)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.name).font(.system(size: 11)).lineLimit(1)
                        Text(account.bankName ?? "Other accounts").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } else {
            Label("Account unavailable", systemImage: "building.columns").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// Merchant artwork uses existing source metadata; unknown merchants retain a quiet category symbol.
private struct BankBillMerchantIcon: View {
    let name: String
    let category: String?
    let logo: String?
    private var logoURL: URL? {
        guard let logo, let url = URL(string: logo), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    private var symbol: String {
        let label = "\(category ?? "") \(name)".lowercased()
        if label.contains("rent") || label.contains("housing") { return "house" }
        if label.contains("power") || label.contains("utilit") { return "bolt" }
        if label.contains("internet") || label.contains("telecom") { return "wifi" }
        if label.contains("stream") || label.contains("entertainment") { return "play.rectangle" }
        return "repeat"
    }
    var body: some View {
        CachedBankImage(url: logoURL) { image in
            if let image { image.resizable().scaledToFit().padding(3) }
            else { Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(ReckonAppearance.accent) }
        }
        .frame(width: 32, height: 32).background(ReckonAppearance.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
    }
}
