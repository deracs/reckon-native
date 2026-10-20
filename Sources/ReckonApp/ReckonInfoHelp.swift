import SwiftUI

/// Offers the same explanation through hover, keyboard activation, and VoiceOver.
struct ReckonInfoHelp: View {
    let subject: String
    let explanation: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(explanation)
        .accessibilityLabel("About \(subject)")
        .accessibilityHint(explanation)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(explanation).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14).frame(width: 280, alignment: .leading)
        }
    }
}
