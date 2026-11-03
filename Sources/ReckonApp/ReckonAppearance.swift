import AppKit
import SwiftUI

/// Shared surfaces keep the dashboard and settings legible in both Mac appearances.
enum ReckonAppearance {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.42, green: 0.70, blue: 1, alpha: 1)
            : NSColor(red: 0.15, green: 0.44, blue: 0.76, alpha: 1)
    })
    static let background = Color(nsColor: canvasColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let canvasColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.105, alpha: 1)
            : NSColor(calibratedWhite: 0.965, alpha: 1)
    }
}

private struct ReckonCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ReckonAppearance.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.035))
            }
    }
}

extension View {
    /// Groups related settings or bank figures on one adaptive card surface.
    func reckonCard() -> some View { modifier(ReckonCardModifier()) }
}

/// Quiet circular controls for secondary dashboard actions.
struct ReckonIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.primary.opacity(configuration.isPressed ? 0.10 : 0.045), in: Circle())
            .contentShape(Circle())
    }
}

/// The approved desktop direction uses a light canvas and restrained sky-blue selections.
enum ReckonDesktopAppearance {
    static let canvas = Color(red: 0.985, green: 0.985, blue: 0.98)
    static let sidebar = Color(red: 0.94, green: 0.955, blue: 0.97)
    static let selection = Color(red: 0.88, green: 0.94, blue: 1)
    static let income = Color(red: 0.08, green: 0.48, blue: 0.23)
    static let expense = Color(red: 0.77, green: 0.32, blue: 0.22)
}
