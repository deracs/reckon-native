import ReckonCore
import SwiftUI

struct BankLogoView: View {
    let account: BankAccount

    var body: some View {
        AsyncImage(url: account.bankLogoURL) { phase in
            if let logo = phase.image {
                logo.resizable().scaledToFit()
            } else {
                Image(systemName: "building.columns")
                    .resizable().scaledToFit().padding(7).foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
