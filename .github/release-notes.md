# Reckon 0.8.0

## Desktop app

- Open a full desktop dashboard alongside the menu-bar dropdown, with a light canvas, blue navigation, bank shortcuts, an integrated forecast, and a muted Newsreader wordmark.
- Browse accounts by bank and currency. Search and sort the fetched activity page, filter by bank/account, and open transaction details. The entire account selector is clickable, with aligned labels, a right-aligned chevron, and keyboard support.
- Use Command–0 to open the desktop, Command–1 through Command–6 to switch sections, Command–F to search activity, and Command–Comma for Settings.
- Close, minimize, and restore the desktop through normal Mac controls and the Dock. Window size and position are saved, and the menu-bar dropdown remains available.

The desktop opens locked at launch. To keep menu-bar-only startup, turn off **Settings → General → Open desktop window at launch**. Launch at login remains separate.

Desktop and dropdown share the same data, ten-minute unlock session, comparison visit, and update checker. Locking clears desktop searches/selections and removes private content, including any open account menu. Credentials, encrypted history, and currency rules are unchanged. Font files and their SIL Open Font License ship with the app; no font installation is required.

## Validation

- Swift core and image checks, native window lifecycle/account-selector checks, release build, signature verification, and privacy checks passed locally. GitHub builds and checks both Apple silicon and Intel before publication.
- Manual sample-data checks covered all six desktop sections, search, filtering, sorting, transaction details, keyboard menu selection, Settings, lock/unlock, resizing, and window reopening.
- Real Touch ID, Mac-password, Apple Watch, authentication cancellation during sleep, and macOS session-switch hardware checks were not performed for this release. Automated session expiry/cancellation/stale-reply checks pass. Personal builds remain ad-hoc signed, without Developer ID notarization.
