import ReckonCore
import SwiftUI

struct BankManualScheduleEditor: View {
    @ObservedObject var store: BankDashboardStore
    let schedule: BankManualForecastSchedule?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var amount = ""
    @State private var accountID = ""
    @State private var isIncome = false
    @State private var startDate = Date.now
    @State private var frequency = BankManualForecastSchedule.Frequency.monthly
    @State private var error: String?
    private var accounts: [BankAccount] { (store.dashboard?.accounts ?? []).filter(\.contributesToLiquidBalance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(schedule == nil ? "Add recurring income or bill" : "Edit recurring item").font(.title2.weight(.semibold))
            TextField("Name", text: $name)
            Picker("Type", selection: $isIncome) { Text("Bill").tag(false); Text("Income").tag(true) }
            Picker("Account", selection: $accountID) {
                if accounts.isEmpty { Text("No NZD checking or savings account available").tag("") }
                ForEach(accounts) { account in Text("\(account.bankName ?? "Account") · \(account.name)").tag(account.id) }
            }
            TextField("Amount per occurrence", text: $amount)
            Picker("Repeats", selection: $frequency) {
                ForEach(BankManualForecastSchedule.Frequency.allCases, id: \.self) { value in Text(value.rawValue.capitalized).tag(value) }
            }
            DatePicker("First occurrence", selection: $startDate, displayedComponents: .date)
                .environment(\.calendar, BankCalendar.calendar).environment(\.timeZone, BankCalendar.calendar.timeZone)
            Text("The first occurrence anchors the schedule. Monthly and yearly items follow the calendar.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 460)
            .onAppear {
                accountID = schedule?.accountId ?? accounts.first?.id ?? ""
                if let schedule {
                    name = schedule.name; amount = NSDecimalNumber(decimal: schedule.amount).stringValue
                    isIncome = schedule.isIncome; startDate = BankCalendar.date(schedule.startDate) ?? .now; frequency = schedule.frequency
                }
            }
    }

    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, accounts.contains(where: { $0.id == accountID }),
              amount.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, value > 0 else {
            error = "Enter a name, eligible account and positive amount with up to two decimal places."
            return
        }
        let item = BankManualForecastSchedule(id: schedule?.id ?? UUID(), accountId: accountID, name: cleanName,
            amount: value, isIncome: isIncome, startDate: BankCalendar.day(startDate), frequency: frequency)
        var next = store.forecastAdjustments
        var schedules = next.manualSchedules ?? []
        if let index = schedules.firstIndex(where: { $0.id == item.id }) { schedules[index] = item }
        else { schedules.append(item) }
        next.manualSchedules = schedules
        if store.saveForecastAdjustments(next) { dismiss() } else { error = store.manualAccountsError }
    }
}

struct BankForecastDateEditor: View {
    @ObservedObject var store: BankDashboardStore
    let occurrence: BankForecastDateOverride
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date.now
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Change estimated date").font(.title2.weight(.semibold))
            Text("\(occurrence.description) · originally \(BankCalendar.label(occurrence.originalDate))")
            DatePicker("New date", selection: $date, displayedComponents: .date)
                .environment(\.calendar, BankCalendar.calendar).environment(\.timeZone, BankCalendar.calendar.timeZone)
            Text("Only this occurrence moves. It remains an estimate and does not change a bank payment.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Reset") {
                    var next = store.forecastAdjustments
                    next.dateOverrides?.removeValue(forKey: occurrence.id)
                    if store.saveForecastAdjustments(next) { dismiss() } else { error = store.manualAccountsError }
                }
                Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 460)
            .onAppear { date = BankCalendar.date(occurrence.date) ?? .now }
    }
    private func save() {
        let day = BankCalendar.day(date)
        guard day >= BankCalendar.day(.now) else { error = "Choose today or a future date."; return }
        var next = store.forecastAdjustments
        var changed = occurrence
        changed.date = day
        if next.dateOverrides == nil { next.dateOverrides = [:] }
        next.dateOverrides?[occurrence.id] = changed
        if store.saveForecastAdjustments(next) { dismiss() } else { error = store.manualAccountsError }
    }
}
