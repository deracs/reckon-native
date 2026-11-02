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
                .font(.caption2.weight(.semibold)).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .disabled(!canOpenUpdate)
        .help(canOpenUpdate ? notice.help : "Reckon \(notice.version) is downloading or being prepared. Please wait.")
        .accessibilityLabel("\(notice.title): Reckon \(notice.version)")
        .accessibilityHint("Opens the software update window")
    }
}
