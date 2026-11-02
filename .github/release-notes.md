This release makes alert settings easier to identify and fixes reopening Reckon’s menu-bar dropdown while Settings is open.

- Balance limits and balance targets now group accounts under bank names and logos, with account counts and separators between banks. Repeated names such as Savings are easier to distinguish. Unavailable bank logos use a bank icon.
- Alert input accessibility labels include the bank name as well as the account name and currency.
- Clicking the menu-bar icon now opens the normal dropdown even when Settings is open or behind another app. It no longer redirects the click to Settings.
- Added native window lifecycle regression checks covering Settings while visible, inactive, hidden, minimized, or closed; restoring the same Settings window; and repeated menu-bar clicks. These checks use sample data and the app’s actual menu-bar button.

Requires macOS 15 or later and a Mac login password. Existing installations can update through Settings → Updates → Check for Updates.

Authentication uses the same macOS policy as previous releases. No new physical-device authentication checks were performed for this release: Touch ID, password fallback, Apple Watch approval, cancellation, and lock/sleep during a prompt were not rechecked manually. Apple Watch approval has not been tested with a physical watch. Automated checks cover session expiry, cancellation, rejection, and stale replies. The window lifecycle check was reproduced failing before the fix and passing afterward on a logged-in Mac desktop.

Download arm64 for Apple silicon or x86_64 for Intel. The archives contain no saved Akahu tokens or personal bank history. SHA-256 checksum files accompany both downloads.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app.
