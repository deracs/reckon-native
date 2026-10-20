import AppKit
import SwiftUI

struct ReckonConnectionView: View {
    @ObservedObject var store: BankDashboardStore
    let closeConnection: () -> Void
    @State private var appToken = ""
    @State private var userToken = ""
    @State private var launchAtLogin = ReckonLoginItem.isEnabled
    @State private var loginMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Akahu").font(.system(.title, design: .serif).weight(.semibold))
                Text("Reckon runs its own backend. Add your personal Akahu tokens to read your accounts.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("App ID token").font(.headline)
                SecureField(store.isConfigured ? "Leave blank to keep the saved token" : "AKAHU_APP_TOKEN", text: $appToken)
                    .autocorrectionDisabled().accessibilityIdentifier("akahu-app-token")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("User access token").font(.headline)
                SecureField(store.isConfigured ? "Leave blank to keep the saved token" : "AKAHU_USER_TOKEN", text: $userToken)
                    .autocorrectionDisabled().accessibilityIdentifier("akahu-user-token")
                Text("Both tokens stay in your Mac’s Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let akahuURL = URL(string: "https://my.akahu.nz") {
                Link("Get tokens from Akahu’s Developers page", destination: akahuURL).font(.callout)
            }
            if let error = store.connectionError {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { enabled in
                    do {
                        try ReckonLoginItem.setEnabled(enabled)
                        launchAtLogin = ReckonLoginItem.isEnabled
                        loginMessage = ReckonLoginItem.requiresApproval
                            ? "Allow Reckon in System Settings → General → Login Items." : nil
                    } catch {
                        loginMessage = "Could not change launch at login. Open Reckon from its app bundle and try again."
                        launchAtLogin = ReckonLoginItem.isEnabled
                    }
                }))
                .disabled(store.isDemo)
            if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            if store.isConfigured {
                Button("Disconnect & clear local history", role: .destructive) {
                    store.disconnect(); appToken = ""; userToken = ""
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { appToken = ""; userToken = ""; closeConnection() }.keyboardShortcut(.cancelAction)
                Button("Save and connect") {
                    if store.saveAkahuCredentials(appToken: appToken, userToken: userToken) {
                        appToken = ""
                        userToken = ""
                        closeConnection()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.isDemo)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(26)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { appToken = ""; userToken = "" }
    }
}
