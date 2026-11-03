import ReckonCore
import SwiftUI

private struct GoalAccount: Identifiable {
    let id: String
    let name: String
    let balance: Decimal
}

struct SavingsGoalsView: View {
    @ObservedObject var store: BankDashboardStore
    @State private var adding = false
    @State private var editing: SavingsGoal?
    @State private var deleting: SavingsGoal?

    private var accounts: [GoalAccount] {
        let connected = (store.dashboard?.accounts ?? []).filter { $0.type == "savings" && $0.currency == "NZD" }
            .map { GoalAccount(id: $0.id, name: $0.name, balance: $0.balance.value) }
        let manual = store.manualAccounts.filter { $0.kind == "Savings" && $0.currency == "NZD" }
            .map { GoalAccount(id: $0.id.uuidString, name: $0.name, balance: $0.balance) }
        return connected + manual
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Savings goals").font(.headline); Spacer(); Button("Create goal") { adding = true }.disabled(accounts.isEmpty) }
            if accounts.isEmpty { Text("Add or connect an NZD savings account to create a goal.").font(.caption).foregroundStyle(.secondary) }
            if store.savingsGoals.isEmpty && !accounts.isEmpty { Text("No savings goals yet.").foregroundStyle(.secondary) }
            ForEach(store.savingsGoals) { goal in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(goal.name).fontWeight(.medium); Spacer()
                        Button("Edit") { editing = goal }
                        Button("Delete") { deleting = goal }
                    }
                    if let account = accounts.first(where: { $0.id == goal.accountID }) {
                        Text("\(account.name) · \(BankFormatting.money(account.balance)) of \(BankFormatting.money(goal.target))")
                        ProgressView(value: min(max(NSDecimalNumber(decimal: account.balance / goal.target).doubleValue, 0), 1))
                        if let deadline = goal.deadline {
                            let days = max(0, BankCalendar.calendar.dateComponents([.day], from: BankCalendar.calendar.startOfDay(for: .now), to: BankCalendar.calendar.startOfDay(for: deadline)).day ?? 0)
                            let periods = max(1, Int(ceil(Double(days) / Double(goal.paydayIntervalDays))))
                            let remaining = max(Decimal.zero, goal.target - account.balance)
                            Text("\(BankFormatting.money(remaining / Decimal(periods))) per \(goal.paydayIntervalDays == 7 ? "week" : "fortnight") to \(deadline.formatted(date: .abbreviated, time: .omitted)) · estimate")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else { Text("Linked savings account unavailable.").foregroundStyle(.orange) }
                }.padding(12).background(.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
            if !store.savingsGoals.isEmpty { Text("Current account balances include existing funds and are assumed available for the goal.").font(.caption).foregroundStyle(.secondary) }
            if let error = store.manualAccountsError { BankDesktopSectionError(message: error) }
        }
        .sheet(isPresented: $adding) { SavingsGoalEditor(store: store, accounts: accounts, goal: nil) }
        .sheet(item: $editing) { goal in SavingsGoalEditor(store: store, accounts: accounts, goal: goal) }
        .confirmationDialog("Delete this savings goal?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete goal", role: .destructive) { if let deleting { _ = store.deleteSavingsGoal(deleting) }; deleting = nil }
        }
    }
}

private struct SavingsGoalEditor: View {
    @ObservedObject var store: BankDashboardStore
    let accounts: [GoalAccount]
    let goal: SavingsGoal?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var accountID = ""
    @State private var target = ""
    @State private var hasDeadline = false
    @State private var deadline = Date.now
    @State private var interval = 14
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(goal == nil ? "Create savings goal" : "Edit savings goal").font(.title2.weight(.semibold))
            TextField("Goal name", text: $name)
            Picker("Savings account", selection: $accountID) { ForEach(accounts) { Text($0.name).tag($0.id) } }
            TextField("Target amount", text: $target)
            Toggle("Set a deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Deadline", selection: $deadline, displayedComponents: .date)
                Picker("Contribution frequency", selection: $interval) { Text("Weekly").tag(7); Text("Fortnightly").tag(14) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { save() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 420)
            .onAppear {
                accountID = goal?.accountID ?? accounts.first?.id ?? ""
                if let goal { name = goal.name; target = NSDecimalNumber(decimal: goal.target).stringValue; hasDeadline = goal.deadline != nil; deadline = goal.deadline ?? .now; interval = goal.paydayIntervalDays }
            }
    }
    private func save() {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, accounts.contains(where: { $0.id == accountID }),
              target.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: target, locale: Locale(identifier: "en_US_POSIX")), amount > 0,
              !hasDeadline || deadline >= BankCalendar.calendar.startOfDay(for: .now) else {
            error = "Enter a name, positive target and a deadline that has not passed."
            return
        }
        var result = goal ?? SavingsGoal(accountID: accountID, name: cleanName, target: amount, deadline: nil, paydayIntervalDays: interval)
        result.accountID = accountID; result.name = cleanName; result.target = amount; result.deadline = hasDeadline ? deadline : nil; result.paydayIntervalDays = interval
        if store.saveSavingsGoal(result) { dismiss() } else { error = store.manualAccountsError }
    }
}
