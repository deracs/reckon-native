A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

Source builds, tests, and releases now use Rust tools. Node and PNPM are no longer required.

- Rust replaces the JavaScript build, benchmark, credential import, privacy, and release tools.
- Rust replaces the integration tests and the backend fixtures for Swift checks.
- Rustfmt and Clippy check both Rust packages. Cargo lockfiles pin their dependencies.

The app includes the Rust backend and shared bank and transaction logo cache from v0.7.7. Cached logos appear immediately when you change tabs.

Authentication uses the same macOS policy as v0.7.5. Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock was manually verified on Apple silicon for v0.7.5. Authentication is unchanged in this release. No new physical-device authentication checks were performed. Apple Watch approval has not been tested with a physical watch.

Download the ZIP for your Mac: `arm64` for Apple silicon, `x86_64` for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app. Touch ID is optional. Apple Watch requires setup in macOS System Settings.

SHA-256 checksum files accompany each archive. GitHub release access follows the repository's visibility.
