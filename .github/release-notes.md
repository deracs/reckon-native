A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

Reckon now uses a standalone Rust backend. The app no longer bundles Node or a TypeScript backend.

- Bank and transaction logos stay in a shared memory cache. Cached logos appear immediately when you change tabs.
- The backend exits after each refresh. Swift keeps the displayed dashboard available between refreshes.
- Dashboard sections share one transaction-history fetch per account and source page.
- The menu bar icon shows a lock badge while Reckon is locked.

In five live Akahu trials per backend, median refresh time fell from 13.12 seconds to 10.80 seconds. Loaded backend RSS fell from 84.7 MiB to 13.7 MiB. All dashboard sections matched. These measurements cover the backend process, not the full app. See the [measurement details](https://github.com/deracs/reckon-native/blob/v0.7.7/docs/performance/live-akahu-backend-2026-10-22.md).

Authentication uses the same macOS policy as v0.7.5. Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock was manually verified on Apple silicon for v0.7.5. Authentication is unchanged in this release. No new physical-device authentication checks were performed. Apple Watch approval has not been tested with a physical watch.

Download the ZIP for your Mac: `arm64` for Apple silicon, `x86_64` for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app. Touch ID is optional. Apple Watch requires setup in macOS System Settings.

SHA-256 checksum files accompany each archive. GitHub release access follows the repository's visibility.
