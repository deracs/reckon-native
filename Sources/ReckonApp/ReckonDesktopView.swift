import AppKit
import ReckonCore
import SwiftUI

/// Both entry points share authentication; private desktop content exists only during an unlocked session.
struct ReckonDesktopView: View {
    @ObservedObject var store: BankDashboardStore
    @ObservedObject var appLock: ReckonAppLock
    @ObservedObject var navigation: ReckonDesktopNavigation
    @ObservedObject var softwareUpdates: ReckonSoftwareUpdates
    let openSettings: () -> Void
    let unlock: () -> Void
    let lock: () -> Void
    let openSoftwareUpdate: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if appLock.isUnlocked {
                HStack(spacing: 0) {
                    sidebar
                    VStack(spacing: 0) {
                        header
                        if let error = store.loadError {
                            BankDesktopSectionError(message: "\(error) Showing the last fetched figures.")
                                .padding(.horizontal, 28).padding(.bottom, 12)
                        }
                        content
                        footer
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield").font(.system(size: 44, weight: .light)).foregroundStyle(ReckonAppearance.accent)
                    Text("Unlock Reckon").font(.system(size: 28, weight: .semibold))
                    Text(appLock.errorMessage ?? "Use Touch ID, Apple Watch, or your Mac login password to view your accounts.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    Button(appLock.state == .authenticating ? "Unlock in the macOS prompt…" : "Unlock Reckon", action: unlock)
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).disabled(appLock.state == .authenticating)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(ReckonDesktopAppearance.canvas)
        .preferredColorScheme(.light).tint(ReckonAppearance.accent)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: appLock.isUnlocked) { if !appLock.isUnlocked { searchFocused = false } }
        .onChange(of: navigation.searchRequest) { searchFocused = true }
        .onChange(of: navigation.search) {
            if !navigation.search.isEmpty { navigation.section = .activity; navigation.transactionID = nil }
        }
        .onChange(of: store.dashboard?.accounts.map(\.id)) {
            let accounts = store.dashboard?.accounts ?? []
            if let id = navigation.accountID, !accounts.contains(where: { $0.id == id }) { navigation.accountID = nil }
            if let id = navigation.bankID, !BankAccountGroup.groupAccounts(accounts).contains(where: { $0.id == id }) { navigation.bankID = nil }
        }
        .onAppear { if navigation.section == .activity { searchFocused = true } }
    }

    /// A quiet footer wordmark matches the web brand without adding another navigation control.
    private var desktopBrand: some View {
        Text("reckon.").font(ReckonBrandTypography.wordmark).tracking(-0.8)
            .foregroundStyle(.secondary).opacity(0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(spacing: 4) {
                ForEach(ReckonDashboardSection.allCases) { section in
                    sidebarButton(section.shortLabel, image: section.systemImage,
                                  selected: navigation.section == section && navigation.bankID == nil) { navigation.selectSection(section) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if let dashboard = store.dashboard, !dashboard.accounts.isEmpty {
                        Text("CONNECTED BANKS").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 7)
                        ForEach(Array(BankAccountGroup.groupAccounts(dashboard.accounts).enumerated()), id: \.element.id) { index, bank in
                            if index < 9 {
                                bankSidebarButton(bank, shortcut: index + 1)
                                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                            } else {
                                bankSidebarButton(bank, shortcut: nil)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                sidebarButton("Settings", image: "gearshape", selected: false, action: openSettings)
                sidebarButton("Lock Reckon", image: "lock", selected: false, action: lock)
                desktopBrand.padding(.horizontal, 12).padding(.top, 12)
            }
        }
        .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 20)
        .frame(width: 204).frame(maxHeight: .infinity)
        .background(ReckonDesktopAppearance.sidebar.opacity(0.85))
    }

    private func bankSidebarButton(_ bank: BankAccountGroup, shortcut: Int?) -> some View {
        Button { navigation.selectBank(bank.id) } label: {
            HStack(spacing: 8) {
                if let account = bank.logoAccount { BankLogoView(account: account).scaleEffect(0.8).frame(width: 26, height: 26) }
                Text(bank.name).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut {
                    Text("⌘\(shortcut)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text(bank.accounts.count.formatted()).font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2).background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(navigation.bankID == bank.id ? ReckonDesktopAppearance.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .help(shortcut.map { "\(bank.name) · ⌘\($0)" } ?? bank.name)
        .accessibilityLabel("\(bank.name), \(bank.accounts.count) \(bank.accounts.count == 1 ? "account" : "accounts")")
    }

    private func sidebarButton(_ title: String, image: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: image).font(.system(size: 13, weight: selected ? .medium : .regular))
                .labelStyle(.titleAndIcon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).frame(height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(selected ? ReckonAppearance.accent : Color.primary)
        .background(selected ? ReckonDesktopAppearance.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(navigation.section.shortLabel).font(.system(size: 26, weight: .semibold))
            if store.isDemo {
                Text("Sample data").font(.system(size: 11, weight: .medium)).foregroundStyle(ReckonAppearance.accent)
                    .padding(.horizontal, 7).padding(.vertical, 4).background(ReckonDesktopAppearance.selection, in: RoundedRectangle(cornerRadius: 5))
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search activity", text: $navigation.search).textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search desktop activity")
                if !navigation.search.isEmpty {
                    Button { navigation.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Clear activity search")
                } else { Text("⌘ F").font(.caption2).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12)).padding(8).frame(width: 218)
            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)))
            if store.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Reading bank data") }
            else {
                Button { store.reloadDashboard() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.isDemo || !store.isConfigured).help("Reload stats").accessibilityLabel("Reload stats")
            }
            if softwareUpdates.checkState.isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking for updates") }
            else if let notice = softwareUpdates.updateNotice {
                ReckonUpdateBadge(notice: notice, canOpenUpdate: softwareUpdates.canCheckForUpdates, openUpdate: openSoftwareUpdate)
            }
        }
        .frame(height: 36)
        .padding(.horizontal, 28).padding(.top, 44).padding(.bottom, 24)
    }

    @ViewBuilder private var content: some View {
        if let dashboard = store.dashboard {
            if navigation.section == .activity {
                BankDesktopActivityView(store: store, navigation: navigation).padding(.horizontal, 28)
            } else {
                ScrollView {
                    Group {
                        switch navigation.section {
                        case .overview: BankDesktopOverviewView(store: store, navigation: navigation)
                        case .accounts: BankDesktopAccountsView(store: store, navigation: navigation)
                        case .forecast: BankDesktopForecastPage(store: store)
                        case .spending: BankDesktopSpendingView(store: store, dashboard: dashboard)
                        case .standingOrders: BankDesktopBillsView(dashboard: dashboard, forecast: store.adjustedForecast)
                        case .activity: EmptyView()
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 28).padding(.bottom, 20)
                }.id(navigation.section)
            }
        } else if navigation.section == .accounts {
            ScrollView { BankDesktopAccountsView(store: store, navigation: navigation).padding(28) }
        } else if navigation.section == .overview && !store.manualAccounts.isEmpty {
            ScrollView { VStack(alignment: .leading, spacing: 24) { NetWorthView(store: store); Divider(); SavingsGoalsView(store: store) }.frame(maxWidth: .infinity, alignment: .leading).padding(28) }
        } else {
            VStack(spacing: 16) {
                if store.isLoading { ProgressView(); Text("Reading your accounts…").font(.headline) }
                else {
                    Image(systemName: "link").font(.system(size: 40, weight: .light)).foregroundStyle(ReckonAppearance.accent)
                    Text(store.hasWarning ? "Could not read your accounts" : "Your accounts, connected.").font(.title2.weight(.semibold))
                    Text(store.connectionError ?? store.loadError ?? "Connect your Akahu personal app to see balances, activity, and your forecast.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    Button("Connection settings", action: openSettings).buttonStyle(.borderedProminent)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if let dashboard = store.dashboard {
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Label("Last read \(dashboard.fetchedAt.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }.padding(.horizontal, 28).padding(.vertical, 12)
    }
}

/// Partial source failures remain visible alongside successfully fetched data.
struct BankDesktopSectionError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}
