import SwiftUI

/// Update readiness comes from Sparkle; discovery alone does not mean installation is ready.
enum ReckonUpdateNotice: Equatable {
    case available(version: String)
    case ready(version: String)

    var version: String {
        switch self {
        case .available(let version), .ready(let version): version
        }
    }

    var title: String {
        switch self {
        case .available: "Update available"
        case .ready: "Update ready"
        }
    }

    var help: String {
        switch self {
        case .available: "Reckon \(version) is available. Open the update window to review or install it."
        case .ready: "Reckon \(version) is ready to install. Open the update window to restart and update."
        }
    }
}

/// The dashboard update button opens Sparkle's existing review and installation window.
struct ReckonUpdateBadge: View {
    let notice: ReckonUpdateNotice
    let canOpenUpdate: Bool
    let openUpdate: () -> Void

    var body: some View {
        Button(action: openUpdate) {
            Label(notice.title, systemImage: "arrow.down.circle.fill")
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .background(ReckonAppearance.accent.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain).foregroundStyle(ReckonAppearance.accent)
        .disabled(!canOpenUpdate)
        .help(canOpenUpdate ? notice.help : "Reckon \(notice.version) is downloading or being prepared. Please wait.")
        .accessibilityLabel("\(notice.title): Reckon \(notice.version)")
        .accessibilityHint("Opens the software update window")
    }
}
