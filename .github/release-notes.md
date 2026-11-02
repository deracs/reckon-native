This release makes update checks visible without adding clutter to the dashboard.

- Reckon quietly checks for updates when you open the dashboard or Settings, at most once a minute. These checks respect the automatic-check preference and leave active downloads and staged installations alone.
- The dashboard shows a spinner while checking, an update icon when a release is available or ready to install, and no indicator otherwise. Click the icon to review or install the update; hover for its version and status.
- Settings → Updates shows the installed and latest versions, last check time, and last result. Completed results survive a restart of the same app build. Failed checks report failure rather than claiming Reckon is up to date.
- Added checks for the cooldown, automatic-check preferences, saved results, and Sparkle completion callbacks. The existing six-hour background schedule and manual Check for Updates remain available.

Requires macOS 15 or later and a Mac login password. Existing installations can update through Settings → Updates → Check for Updates.

Local validation passed 55 core checks, 6 image checks, and the native window lifecycle and update callback checks. The minimized-Settings dropdown assertion was intermittent during local runs and passed on rerun.

Authentication uses the same macOS policy as previous releases. No new physical-device authentication checks were performed for this release: Touch ID, password fallback, Apple Watch approval, cancellation, and lock/sleep during a prompt were not rechecked manually. Apple Watch approval has not been tested with a physical watch. Automated checks cover session expiry, cancellation, rejection, and stale replies.

Download arm64 for Apple silicon or x86_64 for Intel. The archives contain no saved Akahu tokens or personal bank history. SHA-256 checksum files accompany both downloads.

This personal build is ad-hoc signed, not Developer ID signed or notarized. macOS Gatekeeper can require approval in System Settings → Privacy & Security. Managed Macs can block the app.
