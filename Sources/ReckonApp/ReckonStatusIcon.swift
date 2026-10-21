import AppKit

/// Template menu bar images keep the lock badge legible across macOS appearances.
@MainActor
enum ReckonStatusIcon {
    static let unlocked = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)

    static let locked: NSImage? = {
        guard let chart = unlocked,
              let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) else { return unlocked }
        let badgeHeight: CGFloat = 9
        let badgeWidth = badgeHeight * lock.size.width / lock.size.height
        let badgeRect = NSRect(x: chart.size.width - badgeWidth, y: 0, width: badgeWidth, height: badgeHeight)
        let image = NSImage(size: chart.size, flipped: false) { bounds in
            chart.draw(in: bounds)

            // Cut out a halo so the chart cannot show through the lock's shackle.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badgeRect.insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.restoreGraphicsState()

            lock.draw(in: badgeRect)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
