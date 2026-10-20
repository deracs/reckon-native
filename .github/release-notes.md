A standalone macOS menu bar app for your Akahu accounts. Requires macOS 15 or later and a Mac login password. Unlock with Touch ID, Apple Watch, or your Mac login password.

This release adds Mac login password fallback and enables Apple Watch approval through the standard macOS authentication policy. The ten-minute unlocked session stays the same.

Password fallback works without Touch ID. For Apple Watch approval, enable your watch in System Settings → Touch ID & Password (or Login Password). See [Apple’s setup requirements](https://support.apple.com/en-us/102442).

Mac login password unlock passed a manual check on Apple silicon. Apple Watch approval has no physical-device test for this release because no watch was available.

Download the ZIP for your Mac: `arm64` for Apple silicon, `x86_64` for Intel. Extract Reckon.app, move it to Applications, open it, and connect your own Akahu tokens. Tokens and bank history are not included.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper may require approval in System Settings → Privacy & Security. On managed Macs it may be blocked. Touch ID is optional. Apple Watch requires setup in macOS System Settings.

SHA-256 checksum files accompany each archive. GitHub release access follows the repository's visibility.
