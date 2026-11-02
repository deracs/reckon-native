A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

This release refreshes Reckon’s interface and adds more ways to receive quiet account alerts.

- Softer backgrounds, rounded content cards, clearer typography, and restrained indigo accents across the dashboard and settings.
- A seamless settings title bar with native Mac window controls and a labelled General, Connection, Alerts, and Updates sidebar.
- Saved Akahu connections show a compact status card. Token fields open through Change tokens, startup and shortcut options live under General, and disconnecting asks for confirmation before clearing local history and alert settings.
- Dashboard tabs now have short visible labels. Activity includes a cleaner search field and grouped transaction rows.
- Optional balance-target alerts and minimum-deposit alerts join the existing balance-limit and standing-order alerts. Notifications hide account names and amounts and have no sound.
- Maintainers can prepare, validate, publish, and resume releases with the new release command.

Deposit alerts cover newly seen NZD deposits in the latest 100 non-transfer activity records. The first successful activity fetch after changing the minimum sets a baseline. Late bank imports can count as new, and deposits outside that page can be missed. Balance targets alert on crossings from below the target and can alert again after the balance falls below it.

Authentication uses the same macOS policy as previous releases. Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock was manually verified on Apple silicon for v0.7.5. No new physical-device authentication checks were performed for this release: Touch ID, password fallback, Apple Watch approval, cancellation, and lock/sleep during a prompt were not rechecked manually. Apple Watch approval has not been tested with a physical watch. Automated checks cover session expiry, cancellation, rejection, and stale replies. The refreshed interface was checked with sample data.

Download the ZIP for your Mac: arm64 for Apple silicon, x86_64 for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included. Existing installations can use Check for Updates in Settings → Updates.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app. SHA-256 checksum files accompany each archive.
