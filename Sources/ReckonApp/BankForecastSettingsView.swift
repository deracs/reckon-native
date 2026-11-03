import ReckonCore
import SwiftUI

struct BankForecastSettingsView: View {
    @ObservedObject var store: BankDashboardStore
    let forecast: BankForecast
    @State private var spending = ""
    @State private var interval = 7
    @State private var selectedEvent: BankForecastEvent?
    @State private var selectedOccurrence: BankForecastDateOverride?
    @State private var addingSchedule = false
    @State private var editingSchedule: BankManualForecastSchedule?
    @State private var deletingSchedule: BankManualForecastSchedule?
    @State private var error: String?

    private var series: [BankForecastEvent] {
        var seen = Set<String>()
        return forecast.events.filter { seen.insert(BankForecastAdjustments.seriesKey($0)).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forecast assumptions").font(.headline)
            HStack {
                TextField("Everyday spending", text: $spending).frame(width: 180)
                Picker("Frequency", selection: $interval) { Text("Weekly").tag(7); Text("Fortnightly").tag(14) }.frame(width: 180)
                    .onChange(of: interval) { spending = NSDecimalNumber(decimal: store.forecastAdjustments.weeklySpending * Decimal(interval / 7)).stringValue }
                Button("Save allowance") { saveSpending() }
            }
            Text("Enter spending excluding bills listed below. It is spread evenly across future days.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(Array(series.enumerated()), id: \.offset) { _, event in
                let correction = store.forecastAdjustments.corrections[BankForecastAdjustments.seriesKey(event)]
                HStack {
                    VStack(alignment: .leading) {
                        Text(event.description)
                        Text(store.dashboard?.accounts.first(where: { $0.id == event.accountId })?.name ?? "Account unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(correction?.excluded == true ? "Excluded" : BankFormatting.money(correction?.amount ?? abs(event.amount.value)))
                    Button("Edit") { selectedEvent = event }
                }.padding(.vertical, 3)
            }
            Divider()
            HStack { Text("Manual income and bills").font(.headline); Spacer(); Button("Add recurring item") { addingSchedule = true } }
            Text("Manual items are estimates and do not create payments. Exclude a detected item if you are replacing it to avoid counting it twice.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.forecastAdjustments.manualSchedules ?? []) { schedule in
                HStack {
                    VStack(alignment: .leading) {
                        Text(schedule.name)
                        Text("\(schedule.isIncome ? "Income" : "Bill") · \(schedule.frequency.rawValue.capitalized) · from \(BankCalendar.label(schedule.startDate)) · \(store.dashboard?.accounts.first(where: { $0.id == schedule.accountId })?.name ?? "Account unavailable · not included")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(BankFormatting.money(schedule.amount)).monospacedDigit()
                    Button("Edit") { editingSchedule = schedule }
                    Button("Delete") { deletingSchedule = schedule }
                }.padding(.vertical, 3)
            }
            Divider()
            Text("Change a detected date").font(.headline)
            Text("Move one estimated occurrence; later occurrences keep their detected dates.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(forecast.events.enumerated()), id: \.offset) { _, event in
                let override = store.forecastAdjustments.dateOverrides?[BankForecastAdjustments.occurrenceKey(event)]
                HStack {
                    Text(event.description)
                    Text("· \(store.dashboard?.accounts.first(where: { $0.id == event.accountId })?.name ?? "Account unavailable · not included")").foregroundStyle(.secondary)
                    Spacer()
                    Text(override.map { "\(BankCalendar.label(event.date)) → \(BankCalendar.label($0.date))" } ?? BankCalendar.label(event.date))
                        .foregroundStyle(.secondary)
                    Button("Change date") { selectedOccurrence = override ?? BankForecastDateOverride(event: event, date: event.date) }
                }.font(.callout).padding(.vertical, 2)
            }
            ForEach((store.forecastAdjustments.dateOverrides ?? [:]).values.filter { saved in
                !forecast.events.contains { BankForecastAdjustments.occurrenceKey($0) == saved.id }
            }.sorted { $0.date < $1.date }) { saved in
                HStack {
                    Text(saved.description)
                    Spacer()
                    Text("\(BankCalendar.label(saved.originalDate)) → \(BankCalendar.label(saved.date))").foregroundStyle(.secondary)
                    Button("Change date") { selectedOccurrence = saved }
                }.font(.callout).padding(.vertical, 2)
            }
        }.onAppear { spending = NSDecimalNumber(decimal: store.forecastAdjustments.weeklySpending).stringValue }
        .sheet(item: $selectedEvent) { event in BankForecastCorrectionEditor(store: store, event: event) }
        .sheet(item: $selectedOccurrence) { occurrence in BankForecastDateEditor(store: store, occurrence: occurrence) }
        .sheet(isPresented: $addingSchedule) { BankManualScheduleEditor(store: store, schedule: nil) }
        .sheet(item: $editingSchedule) { schedule in BankManualScheduleEditor(store: store, schedule: schedule) }
        .confirmationDialog("Delete this recurring item?", isPresented: Binding(get: { deletingSchedule != nil }, set: { if !$0 { deletingSchedule = nil } })) {
            Button("Delete item", role: .destructive) {
                if let deletingSchedule {
                    var next = store.forecastAdjustments
                    next.manualSchedules = (next.manualSchedules ?? []).filter { $0.id != deletingSchedule.id }
                    if !store.saveForecastAdjustments(next) { error = store.manualAccountsError }
                }
                deletingSchedule = nil
            }
        }
    }
    private func saveSpending() {
        guard spending.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: spending, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else {
            error = "Enter a weekly amount with up to two decimal places."
            return
        }
        var adjustments = store.forecastAdjustments
        adjustments.weeklySpending = amount / Decimal(interval / 7)
        error = store.saveForecastAdjustments(adjustments) ? nil : store.manualAccountsError
    }
}

extension BankForecastEvent: Identifiable {
    public var id: String { BankForecastAdjustments.seriesKey(self) }
}

private struct BankForecastCorrectionEditor: View {
    @ObservedObject var store: BankDashboardStore
    let event: BankForecastEvent
    @Environment(\.dismiss) private var dismiss
    @State private var excluded = false
    @State private var amount = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event.description).font(.title2.weight(.semibold))
            Text("This changes every future occurrence of this detected series in the forecast.").font(.caption).foregroundStyle(.secondary)
            Toggle("Exclude from forecast", isOn: $excluded)
            TextField("Amount per occurrence", text: $amount).disabled(excluded)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Reset") { var next = store.forecastAdjustments; next.corrections.removeValue(forKey: BankForecastAdjustments.seriesKey(event)); if store.saveForecastAdjustments(next) { dismiss() } }
                Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 420)
            .onAppear {
                let correction = store.forecastAdjustments.corrections[BankForecastAdjustments.seriesKey(event)]
                excluded = correction?.excluded ?? false
                amount = NSDecimalNumber(decimal: correction?.amount ?? abs(event.amount.value)).stringValue
            }
    }
    private func save() {
        guard amount.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            error = "Enter a positive amount with up to two decimal places."
            return
        }
        var next = store.forecastAdjustments
        next.corrections[BankForecastAdjustments.seriesKey(event)] = BankForecastCorrection(excluded: excluded, amount: value)
        if store.saveForecastAdjustments(next) { dismiss() } else { error = store.manualAccountsError }
    }
}
