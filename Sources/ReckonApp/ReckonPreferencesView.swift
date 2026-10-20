import ReckonCore
import SwiftUI

struct ReckonPreferencesView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var shortcut: ReckonKeyboardShortcut
    @ObservedObject var softwareUpdates: ReckonSoftwareUpdates
    let close: () -> Void
    @State private var selectedTab = "Connection"
    @State private var limits: [String: String] = [:]
    @State private var changingPermission = false
    private let tabs = ["Connection", "Alerts", "Controls", "Updates"]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { tab in
                    Button { selectedTab = tab } label: {
                        Image(systemName: tab == "Connection" ? "link" : tab == "Alerts" ? "bell" : tab == "Updates" ? "arrow.down.circle" : "slider.horizontal.3")
                            .font(.system(size: 17)).frame(maxWidth: .infinity).frame(height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(tab).accessibilityLabel(tab)
                    .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                    .background(selectedTab == tab ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
                }
            }
            .padding(5).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20).padding(.top, 20)
            ScrollView {
                if selectedTab == "Connection" {
                    ReckonConnectionView(store: store, closeConnection: close)
                } else if selectedTab == "Alerts" {
                    alertSettings.padding(24)
                } else if selectedTab == "Updates" {
                    updateSettings.padding(24)
                } else {
                    controls.padding(24)
                }
            }
            if selectedTab != "Connection" {
                HStack { Spacer(); Button("Done", action: close).keyboardShortcut(.defaultAction) }
                    .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .frame(width: 480, height: 580).background(.regularMaterial)
        .task {
            limits = store.journal.alertLimits.mapValues { NSDecimalNumber(decimal: $0).stringValue }
            await store.refreshNotificationStatus()
        }
    }

    private var alertSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Text("Quiet alerts").font(.system(.title2, design: .serif).weight(.semibold))
                ReckonInfoHelp(subject: "Quiet alerts", explanation: "Only changes trigger an alert. Notification banners have no sounds, account names or amounts. Enable notifications to request macOS permission.")
            }
            Toggle("Enable notifications", isOn: Binding(get: { store.journal.notificationsEnabled }, set: { enabled in
                changingPermission = true
                Task { await store.setNotificationsEnabled(enabled); changingPermission = false }
            }))
            .disabled(store.isDemo || changingPermission || store.historyError != nil)
            if let message = store.notificationMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack(spacing: 6) {
                Toggle("Flag increases in standing order estimates", isOn: Binding(
                    get: { store.journal.chargeIncreaseAlerts }, set: { store.setChargeIncreaseAlerts($0) }))
                    .disabled(store.isDemo)
                ReckonInfoHelp(subject: "Standing order alerts", explanation: "Compares NZD charges used in Dead reckoning with the previous fetch. First observations set the baseline. These are changes in detected estimates, not confirmation that a merchant changed its price.")
            }
            Divider()
            HStack(spacing: 6) {
                Text("Balance limits").font(.headline)
                ReckonInfoHelp(subject: "Balance limits", explanation: "Alert when an account crosses from at or above its limit to below it. First observations and repeated below-limit readings do not alert. Leave a limit blank to turn it off, then save.")
            }
            ForEach(store.dashboard?.accounts ?? []) { account in
                HStack {
                    Text(account.name).lineLimit(2)
                    Spacer()
                    Text(account.currency).font(.caption).foregroundStyle(.secondary)
                    TextField("Off", text: Binding(get: { limits[account.id] ?? "" }, set: { limits[account.id] = $0 }))
                        .textFieldStyle(.roundedBorder).frame(width: 88)
                        .accessibilityLabel("\(account.name) balance limit in \(account.currency)")
                }
            }
            if let error = store.alertSettingsError { Text(error).font(.caption).foregroundStyle(.red) }
            Button("Save limits") { store.saveAlertLimits(limits) }.disabled(store.isDemo || store.historyError != nil)
            if !store.journal.alerts.isEmpty {
                Divider()
                Text("Recent alerts").font(.headline)
                ForEach(store.journal.alerts.prefix(5)) { alert in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.subject).font(.callout.weight(.medium))
                        Text("\(BankFormatting.money(alert.previous, currency: alert.currency)) → \(BankFormatting.money(alert.current, currency: alert.currency))")
                            .font(.caption).monospacedDigit()
                        Text(alert.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var updateSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) {
                Text("Software updates").font(.system(.title2, design: .serif).weight(.semibold))
                ReckonInfoHelp(subject: "Software updates", explanation: "Checks GitHub every six hours. Sparkle verifies signed feeds and update archives before installation. Updates preserve your Keychain connection, encrypted history and login preference. No bank data or system profile is sent to GitHub.")
            }
            Text("Reckon \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { softwareUpdates.checkForUpdates() }
                .disabled(store.isDemo || !softwareUpdates.canCheckForUpdates)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { softwareUpdates.automaticallyChecks }, set: { softwareUpdates.setAutomaticChecks($0) }))
                .disabled(store.isDemo)
            Toggle("Download and install updates automatically", isOn: Binding(
                get: { softwareUpdates.automaticallyInstalls }, set: { softwareUpdates.setAutomaticInstalls($0) }))
                .disabled(store.isDemo || !softwareUpdates.automaticallyChecks)
            if let message = softwareUpdates.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Open from anywhere").font(.system(.title2, design: .serif).weight(.semibold))
            Toggle("Control–Option–R", isOn: Binding(get: { shortcut.isEnabled }, set: { shortcut.setEnabled($0) }))
            Text("The shortcut opens Reckon. Authentication still applies, with the same ten-minute session.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = shortcut.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Divider()
            HStack(spacing: 6) {
                Text("Balance history").font(.headline)
                ReckonInfoHelp(subject: "Balance history", explanation: "Up to 90 daily balance observations stay encrypted on this Mac. The key stays in Keychain. Trends appear after two days; missing days are not filled in.")
            }
            Text("90 days · encrypted on this Mac").font(.callout).foregroundStyle(.secondary)
            if let error = store.historyError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
