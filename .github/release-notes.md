A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

This release reduces backend memory use and repeated dashboard requests:

- The bundled backend now exits after each refresh. Swift keeps the displayed dashboard available between refreshes.
- Dashboard sections share one transaction-history fetch per account and source page.
- The backend uses Effect’s native Node HTTP transport and a smaller V8 young generation.

Loaded backend RSS fell from about 135 MiB to 99 MiB in the synthetic 3,000-transaction benchmark. This measures the backend process, rather than the whole macOS app. See the [measurement details](https://github.com/deracs/reckon-native/blob/v0.7.6/docs/performance/backend-memory-2026-10-21.md).

Authentication uses the same macOS policy as v0.7.5. Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock was manually verified on Apple silicon for v0.7.5. Authentication is unchanged in this release; no new physical-device authentication checks were performed. Apple Watch approval has not been tested with a physical watch.

Download the ZIP for your Mac: `arm64` for Apple silicon, `x86_64` for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper may require approval in System Settings → Privacy & Security. On managed Macs it may be blocked. Touch ID is optional. Apple Watch requires setup in macOS System Settings.

SHA-256 checksum files accompany each archive. GitHub release access follows the repository's visibility.
