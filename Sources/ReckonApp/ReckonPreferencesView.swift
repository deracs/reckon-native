import ReckonCore
import SwiftUI

private enum ReckonSettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case connection = "Connection"
    case alerts = "Alerts"
    case updates = "Updates"

    var id: Self { self }
    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .connection: "link"
        case .alerts: "bell"
        case .updates: "arrow.down.circle"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Make Reckon at home on your Mac."
        case .connection: "Your accounts, connected through Akahu."
        case .alerts: "A quiet heads-up when something changes."
        case .updates: "Keep Reckon up to date."
        }
    }
}

struct ReckonPreferencesView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var shortcut: ReckonKeyboardShortcut
    @ObservedObject var softwareUpdates: ReckonSoftwareUpdates
    let close: () -> Void
    @State private var selectedSection = ReckonSettingsSection.connection
    @State private var limits: [String: String] = [:]
    @State private var targets: [String: String] = [:]
    @State private var depositThreshold = ""
    @State private var changingPermission = false
    @State private var launchAtLogin = false
    @State private var loginMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(selectedSection.rawValue).font(.system(size: 24, weight: .semibold))
                    Text(selectedSection.subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 24)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selectedSection {
                        case .connection: ReckonConnectionView(store: store, connectionUpdated: { reloadAlertDrafts() })
                        case .alerts: alertSettings
                        case .updates: updateSettings
                        case .general: generalSettings
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(selectedSection)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 740, height: 590)
        .background(ReckonAppearance.background)
        .tint(ReckonAppearance.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onExitCommand(perform: close)
        .task {
            reloadAlertDrafts()
            if !store.isDemo { launchAtLogin = ReckonLoginItem.isEnabled }
            await store.refreshNotificationStatus()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Reckon").font(.system(size: 21, weight: .semibold))
                Text("Settings").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            VStack(spacing: 5) {
                ForEach(ReckonSettingsSection.allCases) { section in
                    Button { selectedSection = section } label: {
                        Label(section.rawValue, systemImage: section.systemImage)
                            .font(.system(size: 13, weight: selectedSection == section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedSection == section ? ReckonAppearance.accent : Color.primary)
                    .background(selectedSection == section ? ReckonAppearance.accent.opacity(0.09) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityAddTraits(selectedSection == section ? [.isSelected] : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 5) {
                Text("Reckon \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
                if store.isDemo { Text("Sample data").foregroundStyle(.orange) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
        }
        .padding(.horizontal, 14).padding(.top, 58).padding(.bottom, 24)
        .frame(width: 184)
        .background(.primary.opacity(0.025))
    }

    @ViewBuilder private var alertSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsHeading("Notifications", explanation: "Only changes trigger an alert. Notification banners have no sounds, account names or amounts. Enable notifications to request macOS permission.")
            Toggle(isOn: Binding(get: { store.journal.notificationsEnabled }, set: { enabled in
                changingPermission = true
                Task { await store.setNotificationsEnabled(enabled); changingPermission = false }
            })) { Text("Enable notifications").frame(maxWidth: .infinity, alignment: .leading) }
            .disabled(store.isDemo || changingPermission || store.historyError != nil)
            if let message = store.notificationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack(spacing: 6) {
                Text("Standing order increases")
                ReckonInfoHelp(subject: "Standing order alerts", explanation: "Compares NZD charges used in Dead reckoning with the previous fetch. First observations set the baseline. These are changes in detected estimates, not confirmation that a merchant changed its price.")
                Spacer()
                Toggle("Standing order increases", isOn: Binding(
                    get: { store.journal.chargeIncreaseAlerts }, set: { store.setChargeIncreaseAlerts($0) }))
                    .labelsHidden().disabled(store.isDemo)
            }
        }
        .toggleStyle(.switch).controlSize(.small).reckonCard()

        if let error = store.alertSettingsError {
            Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        }

        VStack(alignment: .leading, spacing: 16) {
            settingsHeading("Balance limits", explanation: "Alert when an account crosses from at or above its limit to below it. First observations and repeated below-limit readings do not alert. Leave a limit blank to turn it off, then save.")
            Text("Get an alert when a balance falls below its limit.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.dashboard?.accounts ?? []) { account in
                alertAmountRow(account, amounts: $limits, purpose: "balance limit")
            }
            if store.dashboard?.accounts.isEmpty != false { noAccounts }
            if limits.filter({ !$0.value.isEmpty }) != savedLimits {
                HStack {
                    Spacer()
                    Button("Save limits") {
                        store.saveAlertLimits(limits)
                        if store.alertSettingsError == nil { limits = savedLimits }
                    }
                }
                    .disabled(store.isDemo || store.historyError != nil)
            }
        }
        .reckonCard()

        VStack(alignment: .leading, spacing: 16) {
            settingsHeading("Balance targets", explanation: "Alert when an account crosses from below its target to at or above it. It can alert again after falling below the target. Leave blank to turn it off.")
            Text("Get an alert when a balance reaches its target.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.dashboard?.accounts ?? []) { account in
                alertAmountRow(account, amounts: $targets, purpose: "balance target")
            }
            if store.dashboard?.accounts.isEmpty != false { noAccounts }
            Divider()
            settingsHeading("New deposits", explanation: "Alert for newly seen NZD deposits at or above this amount. Detected transfers are excluded. The first successful activity fetch sets a baseline. Activity is limited to the latest 100 transactions, and late imports may appear as new.")
            HStack {
                Text("Minimum deposit").font(.callout)
                Spacer()
                Text("NZD").font(.caption).foregroundStyle(.secondary)
                TextField("Off", text: $depositThreshold).textFieldStyle(.roundedBorder).frame(width: 88)
                    .accessibilityLabel("Minimum deposit in NZD")
            }
            if targets.filter({ !$0.value.isEmpty }) != savedTargets || depositThreshold != savedDepositThreshold {
                HStack {
                    Spacer()
                    Button("Save targets and deposit alert") {
                        store.saveNewAlertSettings(targets: targets, deposit: depositThreshold)
                        if store.alertSettingsError == nil {
                            targets = savedTargets
                            depositThreshold = savedDepositThreshold
                        }
                    }
                }
                .disabled(store.isDemo || store.historyError != nil)
            }
        }
        .reckonCard()

        if !store.journal.alerts.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Recent alerts").font(.headline)
                ForEach(store.journal.alerts.prefix(5)) { alert in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(alert.subject).font(.callout.weight(.medium))
                        Text(alert.kind == .deposit ? BankFormatting.money(alert.current, currency: alert.currency) : "\(BankFormatting.money(alert.previous, currency: alert.currency)) → \(BankFormatting.money(alert.current, currency: alert.currency))")
                            .font(.caption).monospacedDigit()
                        Text(alert.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .reckonCard()
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 28, weight: .light)).foregroundStyle(ReckonAppearance.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reckon").font(.headline)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                    .disabled(store.isDemo || !softwareUpdates.canCheckForUpdates)
            }
            Divider()
            Toggle(isOn: Binding(
                get: { softwareUpdates.automaticallyChecks }, set: { softwareUpdates.setAutomaticChecks($0) })) {
                Text("Check for updates automatically").frame(maxWidth: .infinity, alignment: .leading)
            }
                .disabled(store.isDemo)
            Toggle(isOn: Binding(
                get: { softwareUpdates.automaticallyInstalls }, set: { softwareUpdates.setAutomaticInstalls($0) })) {
                Text("Download and install automatically").frame(maxWidth: .infinity, alignment: .leading)
            }
                .disabled(store.isDemo || !softwareUpdates.automaticallyChecks)
            settingsHeading("About updates", explanation: "Checks GitHub every six hours. Sparkle verifies signed feeds and update archives before installation. Updates preserve your Keychain connection, encrypted history and login preference. No bank data or system profile is sent to GitHub.")
            if let message = softwareUpdates.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .toggleStyle(.switch).controlSize(.small).reckonCard()
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Startup & shortcut").font(.headline)
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) })) {
                    Text("Launch at login").frame(maxWidth: .infinity, alignment: .leading)
                }
                    .disabled(store.isDemo)
                if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
                Divider()
                Toggle(isOn: Binding(get: { shortcut.isEnabled }, set: { shortcut.setEnabled($0) })) {
                    Text("Global keyboard shortcut").frame(maxWidth: .infinity, alignment: .leading)
                }
                    .disabled(store.isDemo)
                HStack {
                    Text("Open Reckon from any app").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("⌃ ⌥ R").font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(ReckonAppearance.background, in: RoundedRectangle(cornerRadius: 6))
                }
                if let message = shortcut.message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            .toggleStyle(.switch).controlSize(.small).reckonCard()
            VStack(alignment: .leading, spacing: 12) {
                settingsHeading("Privacy & history", explanation: "Up to 90 daily balance observations stay encrypted on this Mac. The key stays in Keychain. Trends appear after two days; missing days are not filled in.")
                Label("90 days of encrypted balance history", systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Unlock with your Mac. Reckon locks after ten minutes, when your Mac sleeps, or when you switch sessions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            .reckonCard()
        }
    }

    private var savedLimits: [String: String] {
        store.journal.alertLimits.mapValues { NSDecimalNumber(decimal: $0).stringValue }
    }
    private var savedTargets: [String: String] {
        (store.journal.balanceTargets ?? [:]).mapValues { NSDecimalNumber(decimal: $0).stringValue }
    }
    private var savedDepositThreshold: String {
        store.journal.depositThreshold.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
    }
    private var noAccounts: some View {
        Text("Your accounts will appear after connecting Akahu.").font(.caption).foregroundStyle(.secondary)
    }

    private func reloadAlertDrafts() {
        limits = savedLimits
        targets = savedTargets
        depositThreshold = savedDepositThreshold
    }

    private func alertAmountRow(_ account: BankAccount, amounts: Binding<[String: String]>, purpose: String) -> some View {
        HStack {
            Text(account.name).font(.callout).lineLimit(2)
            Spacer(minLength: 12)
            Text(account.currency).font(.caption).foregroundStyle(.secondary)
            TextField("Off", text: Binding(get: { amounts.wrappedValue[account.id] ?? "" }, set: { amounts.wrappedValue[account.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 88)
                .accessibilityLabel("\(account.name) \(purpose) in \(account.currency)")
        }
    }

    private func settingsHeading(_ title: String, explanation: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.headline)
            ReckonInfoHelp(subject: title, explanation: explanation)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try ReckonLoginItem.setEnabled(enabled)
            launchAtLogin = ReckonLoginItem.isEnabled
            loginMessage = ReckonLoginItem.requiresApproval
                ? "Allow Reckon in System Settings → General → Login Items." : nil
        } catch {
            loginMessage = "Could not change launch at login. Open Reckon from its app bundle and try again."
            launchAtLogin = ReckonLoginItem.isEnabled
        }
    }
}
