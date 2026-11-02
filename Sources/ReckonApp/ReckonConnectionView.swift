import SwiftUI

struct ReckonConnectionView: View {
    @ObservedObject var store: BankDashboardStore
    let connectionUpdated: () -> Void
    @State private var appToken = ""
    @State private var userToken = ""
    @State private var editingTokens = false
    @State private var confirmingDisconnect = false

    private var hasConnection: Bool { store.isConfigured || store.isDemo }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "link")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(ReckonAppearance.accent)
                        .frame(width: 44, height: 44)
                        .background(ReckonAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Akahu").font(.headline)
                        Label(store.isDemo ? "Sample connection" : store.isConfigured ? "Connection saved" : "Not connected",
                              systemImage: hasConnection ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text(hasConnection ? "Your tokens stay in your Mac’s Keychain." : "Connect Akahu to read your accounts.")
                    .font(.callout).foregroundStyle(.secondary)
                if hasConnection && !editingTokens {
                    Button("Change tokens…") { editingTokens = true }
                }
                if !hasConnection || editingTokens { tokenFields }
            }
            .reckonCard()

            if let error = store.connectionError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            if store.isConfigured {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Disconnect Akahu").font(.callout.weight(.medium))
                        Text("Remove this connection and its local history.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
                }
                .padding(.horizontal, 4).padding(.top, 8)
            }
        }
        .textFieldStyle(.roundedBorder)
        .alert("Disconnect Akahu?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) { }
            Button("Disconnect and clear history", role: .destructive) {
                store.disconnect()
                clearTokens()
                editingTokens = false
                if !store.isConfigured { connectionUpdated() }
            }
        } message: {
            Text("This removes your saved tokens, balance history, visit comparisons, and alert settings from this Mac. You can reconnect at any time.")
        }
        .onDisappear { clearTokens() }
    }

    private var tokenFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("App ID token").font(.callout.weight(.medium))
                SecureField(store.isConfigured ? "Saved token · leave blank to keep" : "Enter your app ID token", text: $appToken)
                    .autocorrectionDisabled().accessibilityIdentifier("akahu-app-token")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("User access token").font(.callout.weight(.medium))
                SecureField(store.isConfigured ? "Saved token · leave blank to keep" : "Enter your user access token", text: $userToken)
                    .autocorrectionDisabled().accessibilityIdentifier("akahu-user-token")
            }
            if !hasConnection {
                Label("Stored securely in Keychain", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let akahuURL = URL(string: "https://my.akahu.nz") {
                Link("Get Akahu tokens ↗", destination: akahuURL).font(.callout)
            }
            HStack {
                Spacer()
                if hasConnection {
                    Button("Cancel") { clearTokens(); editingTokens = false }
                }
                Button(store.isConfigured ? "Save changes" : "Connect Akahu") {
                    if store.saveAkahuCredentials(appToken: appToken, userToken: userToken) {
                        clearTokens()
                        editingTokens = false
                        connectionUpdated()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isDemo || (store.isConfigured
                    ? appToken.isEmpty && userToken.isEmpty
                    : appToken.isEmpty || userToken.isEmpty))
            }
        }
    }

    private func clearTokens() { appToken = ""; userToken = "" }
}
