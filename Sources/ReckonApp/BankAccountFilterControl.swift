import AppKit
import ReckonCore
import SwiftUI

/// One native pop-up button owns the whole account selector, including its keyboard and accessibility behavior.
struct BankAccountFilterControl: NSViewRepresentable {
    let accounts: [BankAccount]
    let bankID: String?
    let accountID: String?
    let select: (String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeNSView(context: Context) -> BankAccountFilterButton {
        BankAccountFilterButton(frame: .zero, pullsDown: false)
    }

    static func dismantleNSView(_ button: BankAccountFilterButton, coordinator: Coordinator) {
        // Lock removes this private view; dismiss any bank names still displayed in its menu.
        button.menu?.cancelTrackingWithoutAnimation()
    }

    func updateNSView(_ button: BankAccountFilterButton, context: Context) {
        context.coordinator.select = select
        let banks = BankAccountGroup.groupAccounts(accounts)
        let account = accounts.first { $0.id == accountID }
        let bank = banks.first { group in
            account.map { selected in group.accounts.contains { $0.id == selected.id } } ?? (group.id == bankID)
        }
        let title = account.map { "\($0.name) · \($0.currency)" } ?? "All accounts"
        button.label.rootView = BankAccountFilterLabel(title: title, bankName: bank?.name ?? "All banks", logoAccount: bank?.logoAccount)
        button.setAccessibilityLabel("Filter activity accounts")
        button.setAccessibilityValue("\(bank?.name ?? "All banks"), \(account?.name ?? "All accounts")")
        button.toolTip = "Choose a bank or account to filter activity"

        let menu = NSMenu()
        menu.autoenablesItems = false
        var selection: NSMenuItem?
        func addChoice(_ title: String, bank: String?, account: String?) {
            let item = NSMenuItem(title: title, action: #selector(Coordinator.chooseAccount(_:)), keyEquivalent: "")
            item.target = context.coordinator
            item.representedObject = AccountChoice(bankID: bank, accountID: account)
            menu.addItem(item)
            if bank == bankID && account == accountID { selection = item }
        }
        addChoice("All banks · all accounts", bank: nil, account: nil)
        for bank in banks {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: bank.name))
            addChoice("All \(bank.name) accounts", bank: bank.id, account: nil)
            for account in bank.accounts {
                addChoice("\(account.name) · \(account.currency)", bank: bank.id, account: account.id)
                // Account-card navigation may set only the account scope.
                if account.id == accountID { selection = menu.items.last }
            }
        }
        button.menu?.cancelTrackingWithoutAnimation()
        button.menu = menu
        if let selection { button.select(selection) }
    }

    final class Coordinator: NSObject {
        var select: (String?, String?) -> Void
        init(select: @escaping (String?, String?) -> Void) { self.select = select }

        @objc func chooseAccount(_ item: NSMenuItem) {
            guard let choice = item.representedObject as? AccountChoice else { return }
            select(choice.bankID, choice.accountID)
        }
    }

    private final class AccountChoice: NSObject {
        let bankID: String?
        let accountID: String?
        init(bankID: String?, accountID: String?) { self.bankID = bankID; self.accountID = accountID }
    }
}

/// Decorative hosted content never intercepts clicks intended for the native menu control.
final class BankAccountFilterLabelHost: NSHostingView<BankAccountFilterLabel> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Custom drawing preserves native menu tracking while giving the whole field a hover and focus affordance.
final class BankAccountFilterButton: NSPopUpButton {
    let label = BankAccountFilterLabelHost(rootView: BankAccountFilterLabel(title: "All accounts", bankName: "All banks", logoAccount: nil))
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false
        focusRingType = .exterior
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7)
        ])
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 46) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        (isHighlighted ? NSColor.controlAccentColor.withAlphaComponent(0.09) : NSColor.white.withAlphaComponent(hovered ? 1 : 0.6)).setFill()
        outline.fill()
        NSColor.labelColor.withAlphaComponent(hovered ? 0.22 : 0.12).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
}

/// Text aligns independently of native menu-button insets; the chevron stays at the trailing edge.
struct BankAccountFilterLabel: View {
    let title: String
    let bankName: String
    let logoAccount: BankAccount?

    var body: some View {
        HStack(spacing: 10) {
            if let account = logoAccount { BankLogoView(account: account) }
            else {
                Image(systemName: "building.2").font(.system(size: 17)).foregroundStyle(ReckonAppearance.accent)
                    .frame(width: 32, height: 32).background(ReckonDesktopAppearance.selection, in: RoundedRectangle(cornerRadius: 7))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Text(bankName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }
}
