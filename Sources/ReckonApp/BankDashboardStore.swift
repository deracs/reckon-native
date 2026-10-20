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
    let isDemo: Bool

    private var historyStorage: EncryptedBankHistory?
    private let notifications = BankNotifications()
    private var visitBaseline: BankViewedSnapshot?
    private var visitIsActive = false
    private var credentials: AkahuCredentials?
    private var client: ReckonAPIClient?
    private let backend = BundledBackend(bundleURL: Bundle.main.bundleURL)
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
            return
        }
        do {
            let storage = try BankHistoryKeychain.openHistory()
            journal = try storage.load()
            historyStorage = storage
        } catch { historyError = error.localizedDescription }
        backend.onUnexpectedExit = { [weak self] error in
            guard let self else { return }
            self.generation = UUID()
            self.loadTask?.cancel()
            self.client = nil
            self.isLoading = false
            self.loadError = error.localizedDescription
        }
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
            backend.stop()
            isLoading = false
            dashboard = nil
            loadError = nil
            connectionError = nil
            credentials = newCredentials
            client = nil
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
            backend.stop()
            credentials = nil
            client = nil
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
                let client: ReckonAPIClient
                if let existing = self.client, self.backend.isRunning {
                    client = existing
                } else {
                    let connection = try await self.backend.start(credentials: credentials)
                    try Task.checkCancellation()
                    guard self.generation == requestGeneration else { return }
                    client = ReckonAPIClient(connection: connection)
                    self.client = client
                }
                let dashboard = try await client.fetchDashboard()
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                self.dashboard = dashboard
                self.recordDashboard(dashboard)
                self.loadError = nil
                self.isLoading = false
            } catch {
                guard self.generation == requestGeneration, !Task.isCancelled else { return }
                if let apiError = error as? ReckonAPIError {
                    switch apiError {
                    case .connectionFailed, .unauthorized:
                        self.client = nil
                        self.backend.stop()
                    default: break
                    }
                }
                self.loadError = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func beginVisit() {
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

    func shutdown() {
        generation = UUID()
        loadTask?.cancel()
        pollTask?.cancel()
        backend.stop()
    }
}
