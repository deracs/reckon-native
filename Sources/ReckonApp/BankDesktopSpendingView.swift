import Charts
import ReckonCore
import SwiftUI

private enum BankSpendingChartStyle: String, CaseIterable, Identifiable {
    case bar, pie
    var id: Self { self }
}

private struct BankSpendingSlice: Identifiable {
    let id: String
    let category: String
    let amount: Decimal
}

/// Both chart styles use the same current-month category totals; pie includes the remaining categories.
struct BankDesktopSpendingView: View {
    let dashboard: BankDashboard
    @AppStorage("ReckonSpendingChartStyle") private var chartStyle = BankSpendingChartStyle.bar
    @State private var selectedAngle: Double?
    private var allRows: [CategorySpending] { (dashboard.spending.value ?? []).filter { $0.spent.value > 0 }.sorted { $0.spent.value > $1.spent.value } }
    private var rows: [CategorySpending] { Array(allRows.prefix(5)) }
    private var total: Decimal { allRows.reduce(Decimal.zero) { $0 + $1.spent.value } }
    private var currency: String? { dashboard.hasMultipleCurrencies ? nil : dashboard.accounts.first?.currency }
    private var slices: [BankSpendingSlice] {
        var values = rows.map { BankSpendingSlice(id: "category:\($0.category)", category: $0.category, amount: $0.spent.value) }
        let remainder = allRows.dropFirst(5).reduce(Decimal.zero) { $0 + $1.spent.value }
        if remainder > 0 { values.append(BankSpendingSlice(id: "remaining", category: "Other categories", amount: remainder)) }
        return values
    }
    private var selectedSlice: BankSpendingSlice? {
        guard let selectedAngle else { return nil }
        var cumulative = 0.0
        for slice in slices {
            cumulative += NSDecimalNumber(decimal: slice.amount).doubleValue
            if selectedAngle <= cumulative { return slice }
        }
        return nil
    }
    private var hasNamedCategories: Bool {
        allRows.contains { !["uncategorized", "uncategorised", ""].contains($0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }
    private let palette: [Color] = [Color(red: 0.23, green: 0.51, blue: 0.81), Color(red: 0.18, green: 0.59, blue: 0.61), Color(red: 0.39, green: 0.65, blue: 0.48), Color(red: 0.84, green: 0.63, blue: 0.28), Color(red: 0.78, green: 0.44, blue: 0.36), Color.gray.opacity(0.65)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Spending by category").font(.system(size: 20, weight: .semibold))
                    Text("This month · \(BankCalendar.label(dashboard.window.monthStart)) – \(BankCalendar.label(dashboard.window.today))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Chart style", selection: $chartStyle) {
                    Label("Bar", systemImage: "chart.bar.xaxis").tag(BankSpendingChartStyle.bar)
                    Label("Pie", systemImage: "chart.pie").tag(BankSpendingChartStyle.pie)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 148).accessibilityLabel("Spending chart style")
            }
            if dashboard.hasMultipleCurrencies {
                Label("Mixed currencies · amounts are unconverted", systemImage: "exclamationmark.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            if let error = dashboard.spending.errorMessage { BankDesktopSectionError(message: error) }
            else if allRows.isEmpty {
                Label("No spending recorded in this period.", systemImage: "chart.pie").font(.callout).foregroundStyle(.secondary).padding(.vertical, 28)
            } else {
                if !hasNamedCategories {
                    Label("These transactions have no source categories yet. Activity includes older transactions, which may already be categorized.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(ReckonDesktopAppearance.selection.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
                if chartStyle == .pie { pieChart } else { barChart }
                Divider()
                categoryComparison
            }
        }
        .frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: chartStyle) { selectedAngle = nil }
        .onChange(of: slices.map(\.amount)) { selectedAngle = nil }
    }

    private var barChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Five largest categories").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 18) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.category).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Spacer(minLength: 16)
                            Text(BankFormatting.money(row.spent.value, currency: currency)).font(.system(size: 12)).monospacedDigit()
                        }
                        GeometryReader { geometry in
                            let proportion = NSDecimalNumber(decimal: row.spent.value / (rows.first?.spent.value ?? 1)).doubleValue
                            Capsule().fill(.primary.opacity(0.045))
                            Capsule().fill(palette[index]).frame(width: geometry.size.width * proportion)
                        }.frame(height: 10).accessibilityHidden(true)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.category)
                    .accessibilityValue(BankFormatting.money(row.spent.value, currency: currency))
                }
            }
        }
    }

    private var pieChart: some View {
        HStack(spacing: 34) {
            ZStack {
                Chart(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    SectorMark(angle: .value("Spent", NSDecimalNumber(decimal: slice.amount).doubleValue), innerRadius: .ratio(0.66), angularInset: 2)
                        .cornerRadius(4).foregroundStyle(palette[index].opacity(selectedSlice == nil || selectedSlice?.id == slice.id ? 1 : 0.4))
                        .accessibilityLabel(slice.category).accessibilityValue(BankFormatting.money(slice.amount, currency: currency))
                }
                .chartAngleSelection(value: $selectedAngle).chartLegend(.hidden)
                VStack(spacing: 6) {
                    Text(selectedSlice?.category ?? "This month").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
                    Text(BankFormatting.money(selectedSlice?.amount ?? total, currency: currency))
                        .font(.system(size: 22, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                }.frame(width: 134).allowsHitTesting(false)
            }.frame(width: 260, height: 260)
            VStack(spacing: 16) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    Button {
                        selectedAngle = NSDecimalNumber(decimal: slices.prefix(index).reduce(Decimal.zero) { $0 + $1.amount } + slice.amount / 2).doubleValue
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(palette[index]).frame(width: 8, height: 8).accessibilityHidden(true)
                            Text(slice.category).font(.system(size: 12)).lineLimit(2)
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(BankFormatting.money(slice.amount, currency: currency)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                Text("\(NSDecimalNumber(decimal: slice.amount / total * 100).doubleValue.formatted(.number.precision(.fractionLength(1))))%")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain).help("Inspect \(slice.category)")
                        .accessibilityLabel("Inspect \(slice.category), \(BankFormatting.money(slice.amount, currency: currency))")
                }
                Text("All categories are included. Select a category to inspect it.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: 360)
            Spacer(minLength: 0)
        }.padding(.vertical, 8)
    }

    private var categoryComparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                GridRow {
                    Text("Category").frame(maxWidth: .infinity, alignment: .leading)
                    Text("This month")
                    Text("Average month")
                    Text("vs average")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.category).fontWeight(.medium)
                        Text(BankFormatting.money(row.spent.value, currency: currency)).monospacedDigit()
                        if let average = dashboard.previousMonthlyAverage(category: row.category) {
                            Text(BankFormatting.money(average, currency: currency)).monospacedDigit()
                            if average > 0 {
                                let percent = NSDecimalNumber(decimal: (row.spent.value - average) / average * 100).doubleValue
                                Text("\(percent >= 0 ? "+" : "")\(percent.formatted(.number.precision(.fractionLength(0))))%")
                                    .foregroundStyle(percent > 0 ? ReckonDesktopAppearance.expense : ReckonDesktopAppearance.income)
                            } else { Text("—").foregroundStyle(.secondary) }
                        } else { Text("Unavailable"); Text("—") }
                    }.font(.system(size: 12))
                }
            }
            Text("The comparison covers the five largest categories. Average month uses the previous three full months. Transfers are excluded.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if let error = dashboard.previousSpending.errorMessage { BankDesktopSectionError(message: error) }
        }
    }
}
