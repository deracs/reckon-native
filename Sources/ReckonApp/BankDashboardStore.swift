import AppKit
import Combine
import Foundation
import ReckonCore

@MainActor
final class BankDashboardStore: ObservableObject {
    @Published private(set) var dashboard: BankDashboard?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var connectionError: String?
    @Published private(set) var isConfigured = false
    @Published private(set) var journal = BankJournal()
    @Published private(set) var historyError: String?
    @Published private(set) var visitSummary: BankVisitSummary?
    @Published private(set) var notificationMessage: String?
    @Published private(set) var alertSettingsError: String?
    @Published private(set) var manualAccounts: [ManualFinancialAccount] = []
    @Published private(set) var forecastAdjustments = BankForecastAdjustments()
    @Published private(set) var savingsGoals: [SavingsGoal] = []
    @Published private(set) var manualAccountsError: String?
    private var manualAccountsStorage: ManualFinancialAccountsStorage?
    let isDemo: Bool

    private var historyStorage: EncryptedBankHistory?
    private let notifications = BankNotifications()
    private var visitBaseline: BankViewedSnapshot?
    private var visitIsActive = false
    private var credentials: AkahuCredentials?
    private var loadTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var generation = UUID()
    private var terminationObserver: NSObjectProtocol?

    init(isDemo: Bool = false) {
        self.isDemo = isDemo
        if isDemo {
            do {
                let sample = try BankDashboard.sampleDashboard()
                dashboard = sample
                for offset in (-13)...0 {
                    for account in sample.accounts {
                        let day = BankCalendar.addDays(offset, to: sample.window.today) ?? sample.window.today
                        journal.samples[account.id, default: []].append(BankBalanceSample(day: day,
                            balance: account.balance.value + Decimal(offset * 80), currency: account.currency))
                    }
                }
            }
            catch { loadError = "Could not load the sample dashboard." }
            manualAccounts = [ManualFinancialAccount(name: "Sample KiwiSaver", kind: "KiwiSaver", currency: "NZD", balance: 25000)]
            return
        }
        do {
            let storage = try ManualFinancialAccountsStorage()
            let saved = try storage.load()
            manualAccounts = saved.accounts
            savingsGoals = saved.goals
            forecastAdjustments = saved.forecastAdjustments
            manualAccountsStorage = storage
        } catch { manualAccountsError = "Could not open manual accounts. Existing data has been left in place." }
        do {
            let storage = try BankHistoryKeychain.openHistory()
            journal = try storage.load()
            historyStorage = storage
        } catch { historyError = error.localizedDescription }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        do {
            if let saved = try AkahuKeychain.loadCredentials() {
                credentials = saved
                isConfigured = true
            }
        } catch { connectionError = error.localizedDescription }
        reloadDashboard()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) }
                catch { return }
                self?.reloadDashboard()
            }
        }
    }

    func saveManualAccount(_ account: ManualFinancialAccount) -> Bool {
        var next = manualAccounts
        if let index = next.firstIndex(where: { $0.id == account.id }) { next[index] = account }
        else { next.append(account) }
        return persistFinancialSettings(accounts: next, goals: savingsGoals)
    }

    func deleteManualAccount(_ account: ManualFinancialAccount) -> Bool {
        persistFinancialSettings(accounts: manualAccounts.filter { $0.id != account.id }, goals: savingsGoals.filter { $0.accountID != account.id.uuidString })
    }

    var adjustedForecast: BankSection<BankForecast> {
        guard let section = dashboard?.forecast else { return .failed("Dead reckoning unavailable.") }
        guard let value = section.value else { return section }
        let eligible = Set((dashboard?.accounts ?? []).filter(\.contributesToLiquidBalance).map(\.id))
        return .loaded(forecastAdjustments.apply(to: value, eligibleAccountIDs: eligible))
    }

    func saveForecastAdjustments(_ adjustments: BankForecastAdjustments) -> Bool {
        persistFinancialSettings(accounts: manualAccounts, goals: savingsGoals, adjustments: adjustments)
    }

    func saveSavingsGoal(_ goal: SavingsGoal) -> Bool {
        var next = savingsGoals.filter { $0.id != goal.id }
        guard !next.contains(where: { $0.accountID == goal.accountID }) else {
            manualAccountsError = "This account already has a savings goal."
            return false
        }
        next.append(goal)
        return persistFinancialSettings(accounts: manualAccounts, goals: next)
    }

    func deleteSavingsGoal(_ goal: SavingsGoal) -> Bool {
        persistFinancialSettings(accounts: manualAccounts, goals: savingsGoals.filter { $0.id != goal.id })
    }

    private func persistFinancialSettings(accounts: [ManualFinancialAccount], goals: [SavingsGoal], adjustments: BankForecastAdjustments? = nil) -> Bool {
        let adjustments = adjustments ?? forecastAdjustments
        if isDemo { manualAccounts = accounts; savingsGoals = goals; forecastAdjustments = adjustments; return true }
        guard let manualAccountsStorage else { return false }
        do {
            try manualAccountsStorage.save(LocalFinancialSettings(accounts: accounts, goals: goals, forecastAdjustments: adjustments))
            manualAccounts = accounts
            savingsGoals = goals
            forecastAdjustments = adjustments
            manualAccountsError = nil
            return true
        } catch {
            manualAccountsError = "Could not save your changes. Existing data has been left in place."
            return false
        }
    }

    var menuBarTitle: String {
        guard let dashboard else { return "Reckon" }
        return BankFormatting.money(dashboard.liquidBalance, compact: true)
    }

    var hasWarning: Bool {
        loadError != nil || connectionError != nil
    }

    func saveAkahuCredentials(appToken: String, userToken: String) -> Bool {
        guard !isDemo else { return false }
        do {
            let newCredentials = try AkahuCredentials(
                appToken: appToken.isEmpty ? (credentials?.appToken ?? "") : appToken,
                userToken: userToken.isEmpty ? (credentials?.userToken ?? "") : userToken
            )
            try AkahuKeychain.saveCredentials(newCredentials)
            if credentials?.userToken != newCredentials.userToken { resetLocalHistory() }
            generation = UUID()
            loadTask?.cancel()
            isLoading = false
            dashboard = nil
            loadError = nil
            connectionError = nil
            credentials = newCredentials
            isConfigured = true
            reloadDashboard()
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        do {
            try AkahuKeychain.deleteCredentials()
            resetLocalHistory()
            generation = UUID()
            loadTask?.cancel()
            credentials = nil
            dashboard = nil
            isConfigured = false
            isLoading = false
            loadError = nil
            connectionError = nil
        } catch { connectionError = error.localizedDescription }
    }

    func reloadDashboard() {
        guard !isDemo, !isLoading, let credentials else { return }
        isLoading = true
        let requestGeneration = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dashboard = try await BundledBackend.fetchDashboard(
                    bundleURL: Bundle.main.bundleURL, credentials: credentials
                )
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                self.dashboard = dashboard
                self.recordDashboard(dashboard)
                self.loadError = nil
                self.isLoading = false
            } catch {
                guard self.generation == requestGeneration, !Task.isCancelled else { return }
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func fetchSpending(from: String, to: String) async throws -> [CategorySpending] {
        if isDemo { return dashboard?.spending.value ?? [] }
        guard let credentials else { throw ReckonAPIError.missingToken }
        let requestGeneration = generation
        let rows = try await BundledBackend.fetchSpending(bundleURL: Bundle.main.bundleURL, credentials: credentials, from: from, to: to)
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        return rows
    }

    func beginVisit() {
        guard !visitIsActive else { return }
        visitIsActive = true
        visitBaseline = journal.lastViewed
        updateVisit()
        persistHistory()
    }

    func endVisit() { visitIsActive = false }

    private func updateVisit() {
        guard visitIsActive, let dashboard else { return }
        visitSummary = visitBaseline.map { BankVisitSummary(previous: $0, dashboard: dashboard) }
        journal.lastViewed = BankViewedSnapshot(dashboard: dashboard)
    }

    private func recordDashboard(_ dashboard: BankDashboard) {
        let alerts = journal.record(dashboard)
        updateVisit()
        persistHistory()
        guard !alerts.isEmpty, !isDemo else { return }
        Task { [weak self, notifications] in
            do { try await notifications.deliver(alerts) }
            catch { self?.notificationMessage = "Could not deliver an alert. Check Reckon in System Settings → Notifications." }
        }
    }

    private func persistHistory() {
        guard !isDemo, let historyStorage else { return }
        do { try historyStorage.save(journal); historyError = nil }
        catch { historyError = error.localizedDescription }
    }

    private func resetLocalHistory() {
        journal = BankJournal()
        visitBaseline = nil
        visitSummary = nil
        persistHistory()
    }

    func refreshNotificationStatus() async {
        guard !isDemo else { return }
        notificationMessage = await notifications.permissionDescription()
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        guard !isDemo, historyStorage != nil else { return }
        if enabled {
            do {
                journal.notificationsEnabled = try await notifications.requestPermission()
                notificationMessage = await notifications.permissionDescription()
            } catch { notificationMessage = "Could not request notification permission. Try again." }
        } else { journal.notificationsEnabled = false }
        persistHistory()
    }

    func setChargeIncreaseAlerts(_ enabled: Bool) {
        journal.chargeIncreaseAlerts = enabled
        persistHistory()
    }

    func saveAlertLimits(_ values: [String: String]) {
        var limits: [String: Decimal] = [:]
        for (id, text) in values {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            guard value.range(of: #"^-?[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil,
                  let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else {
                alertSettingsError = "Enter a balance with up to two decimal places, or leave it blank to turn that limit off."
                return
            }
            limits[id] = decimal
        }
        journal.alertLimits = limits
        alertSettingsError = nil
        persistHistory()
    }

    func saveNewAlertSettings(targets: [String: String], deposit: String) {
        var parsedTargets: [String: Decimal] = [:]
        for (id, text) in targets {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { continue }
            guard let amount = parseAlertAmount(value, allowNegative: true) else {
                alertSettingsError = "Enter a balance with up to two decimal places, or leave it blank."
                return
            }
            parsedTargets[id] = amount
        }
        let value = deposit.trimmingCharacters(in: .whitespacesAndNewlines)
        let threshold = value.isEmpty ? nil : parseAlertAmount(value, allowNegative: false)
        guard value.isEmpty || (threshold != nil && threshold! > 0) else {
            alertSettingsError = "Enter a deposit amount greater than zero with up to two decimal places, or leave it blank."
            return
        }
        if journal.depositThreshold != threshold { journal.resetDepositBaseline() }
        journal.depositThreshold = threshold
        journal.balanceTargets = parsedTargets
        alertSettingsError = nil
        persistHistory()
    }

    private func parseAlertAmount(_ value: String, allowNegative: Bool) -> Decimal? {
        let pattern = allowNegative ? #"^-?[0-9]+(?:\.[0-9]{1,2})?$"# : #"^[0-9]+(?:\.[0-9]{1,2})?$"#
        guard value.range(of: pattern, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN else { return nil }
        return amount
    }

    func shutdown() {
        generation = UUID()
        loadTask?.cancel()
        pollTask?.cancel()
    }
}
