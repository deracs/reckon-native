import SwiftUI

/// Window-local navigation retains selection while reusing the shared financial store.
@MainActor
final class ReckonDesktopNavigation: ObservableObject {
    @Published var section = ReckonDashboardSection.overview
    @Published var bankID: String?
    @Published var accountID: String?
    @Published var search = ""
    @Published var onlyNew = false
    @Published var transactionID: String?
    @Published private(set) var searchRequest = 0

    func selectSection(_ section: ReckonDashboardSection) {
        self.section = section
        transactionID = nil
        bankID = nil
        accountID = nil
        if section != .activity { search = "" }
    }

    func selectBank(_ bankID: String) {
        self.bankID = bankID
        accountID = nil
        transactionID = nil
        search = ""
        section = .accounts
    }

    func selectAccount(_ accountID: String) {
        self.accountID = accountID
        transactionID = nil
        section = .activity
    }

    func focusActivitySearch() {
        section = .activity
        searchRequest += 1
    }

    func clearPrivateSelection() {
        section = .overview
        bankID = nil
        accountID = nil
        search = ""
        onlyNew = false
        transactionID = nil
    }
}
