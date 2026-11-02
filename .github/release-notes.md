A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

This release reduces backend memory use and fixes child process cleanup after an input error.

- Dashboard calculations borrow shared transaction records and avoid deep copies.
- Safe Rust APIs replace direct unsafe calls for parent checks and retry jitter.
- Rust tools terminate and reap child processes when input delivery fails. A regression test covers this error path.
- Named query and forecast fields, consistent imports, and explicit invariant messages improve code clarity.
- The developer guide and AGENTS.md now reference the Google Rust Style Guide and explain its scope for Reckon.

In local checks with 3,000 fictional transactions, median loaded backend memory fell from 13.1 to 10.7 MiB with no source delay. That is about 19% less. Startup and dashboard time improved by about 3–4% across two source-delay scenarios. Each scenario used ten fresh processes per version. These figures exclude the Swift interface and live Akahu latency.

The Rust backend and shared bank and transaction logo cache remain included. Cached logos appear immediately when you change tabs. Source builds, tests, and releases require no Node or PNPM.

Authentication uses the same macOS policy as v0.7.5. Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock was manually verified on Apple silicon for v0.7.5. Authentication is unchanged in this release. No new physical-device authentication checks were performed. Apple Watch approval has not been tested with a physical watch.

Download the ZIP for your Mac: `arm64` for Apple silicon, `x86_64` for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app. Touch ID is optional. Apple Watch requires setup in macOS System Settings.

SHA-256 checksum files accompany each archive. GitHub release access follows the repository's visibility.
