# Developer guide

For installation and everyday use, read the [README](../README.md). Run the commands below from the repository root.

## Build from source

The build requires Swift 6, Rust 1.98.1, the macOS Command Line Tools, PNPM 10.12.1, and Node 24. Xcode is optional.

Reckon uses Rust for the backend and Swift for the interface. `Backend/src` contains the backend source. `Backend/Cargo.lock` pins its dependencies. Node runs development and release scripts only. The app bundle contains no Node runtime or TypeScript backend.

```sh
pnpm install --frozen-lockfile
./scripts/build-app.sh
open dist/Reckon.app
```

The script compiles a release Rust executable and copies it into the app bundle with dependency license notices. It also embeds Sparkle and signs the bundle locally. Rust uses the macOS TLS implementation through `native-tls`.

The completed app has no dependency on source directories or build tools. Personal builds are ad-hoc signed. Distribution with normal Gatekeeper acceptance needs a Developer ID signature and Apple notarization. The workflow does not claim to provide those. A downloaded personal build can need approval under System Settings → Privacy & Security, and managed Macs can block it.

## Import an existing connection

To import tokens from an existing Reckon `.env` after a build:

```sh
node scripts/import-akahu-env.mjs /path/to/reckon/.env /Applications/Reckon.app
```

The importer passes only the two Akahu tokens to the signed app over stdin. The app saves them in its own Keychain entry. It does not copy the `.env` into the app or print token values. Reopen Reckon after the import.

Omit the second argument to import into `dist/Reckon.app`.

**Launch at login** registers this app bundle with macOS. Keep the bundle in a stable location before you enable that option.

The installed app also supports `--launch-at-login-status`, `--enable-launch-at-login`, and `--disable-launch-at-login`. These commands report the bundle path and macOS registration status.

## Checks

```sh
pnpm check
swift run -Xswiftc -warnings-as-errors ReckonChecks
swift run -Xswiftc -warnings-as-errors ReckonImageChecks
pnpm test
```

Build the app before the checks. The Swift checks exercise the bundled process. The integration checks use a local Akahu fixture and run the bundled backend from a temporary directory. They require no real credentials or bank connection.

The Swift checks use an executable runner because the standalone Command Line Tools omit the Swift Testing and XCTest modules.

## Backend checks and tools

`pnpm check` runs Rustfmt, Clippy with warnings as errors, Oxlint, and Oxfmt. `pnpm test` runs Rust calculation checks and the HTTP integration suite. `pnpm fmt` formats Rust and development scripts.

The integration suite uses fictional data on loopback. It checks all seven bank operations, authentication, source errors, retries, pagination, cancellation, and shared dashboard reads. Rust checks cover decimal arithmetic, transfer detection, recurring charges, and calendar boundaries. Generated date windows cover all four projection cadences.

All source money amounts and numeric query parameters must be finite. Invalid source data produces a generic HTTP 502 response. The backend does not print credentials or bank records.

For UI checks with sample data:

```sh
open -n dist/Reckon.app --args --demo --preview
```

Demo mode displays a sample-data label and skips authentication for UI checks. It does not read the saved credentials or start a backend. Only these fixtures are available in demo mode. The `--preview` option also opens the dropdown in a window.

## Data and calculations

The dropdown has one row of six icon tabs with hover labels: **Overview**, **Accounts**, **Activity**, **Dead reckoning**, **The bleed**, and **Standing orders**. Each icon has an accessibility label.

Small info icons beside headings hold longer explanations: hover for a tooltip or click for a readable popover. Currency and estimate warnings remain visible. A tab change returns that list to the top.

- The menu bar always shows only the chart icon. Liquid balance appears in the dropdown after macOS authentication.
- Liquid balance includes NZD checking and savings accounts only.
- Accounts are grouped into collapsible bank sections, initially closed. Each bank header shows Akahu's logo, its account count, and current combined balances, with a separate total for each currency. Totals include negative balances. Currencies are never converted or added together. Click anywhere in the header row to expand or collapse it. Expanded accounts retain their own currencies. Missing or unavailable logos use a bank symbol.
- This month shows income, spending, and net cashflow through today.
- Activity shows the latest 100 non-transfer transactions in the last six months, with search, merchant logos, and a newly-seen filter. Comparison uses transaction IDs, so late bank imports can count as newly seen. When the list reaches 100 transactions, its label states that the count covers only that page. Received totals retain their currencies. The first visit sets a baseline.
- Dead reckoning shows a 30-day estimate for NZD checking and savings. It uses detected regular income and bills, excludes inter-account transfers, and does not include everyday discretionary spending. Hover or drag across the chart to inspect a day. The first projected negative day is flagged.
- Estimated payday uses recurring deposits of at least NZ$200, without descriptions that contain interest, dividends, refunds, cashback or rental payments. It is a conservative heuristic, not a confirmed salary payment. Smaller pay deposits can be absent. Interest still contributes to the balance curve.
- Standing orders starts with the estimated bills due in the next seven days for NZD checking and savings.
- The bleed shows the five largest categories this month, with comparison to the previous three full months' average.
- Standing orders show detected charges over six months, with their cadence and average amount.
- Data freshness shows the last API fetch and each account's source refresh times.

Report dates use Pacific/Auckland time. Cashflow and spending exclude inter-account transfers through the Reckon calculations.

Merchant logos use Akahu’s optional [transaction metadata](https://developers.akahu.nz/docs/the-transaction-model). Unavailable logos fall back to merchant initials. No extra enrichment service is called.

Bank and merchant logos share the memory cache in `Sources/ReckonImages`. A tab can recreate its views without a placeholder flash or another download. Concurrent rows share one request per URL. Reads continue when a tab disappears, so another tab can reuse the result.

The decoded cache has an 8 MiB budget and a limit of 256 entries. Images have at most 128 pixels on their longest side. The HTTP cache has a 2 MiB memory budget, and source downloads have a 2 MiB size limit. Failed logos retain their fallback and wait one minute before another attempt. Logo images and URLs do not enter a disk cache.

`ReckonImageChecks` renders fictional logos in an offscreen window. It checks the first frame after twenty tab recreations, shared requests, mid-request tab changes, changed URLs, error fallbacks, and thumbnail dimensions.

The backend uses Akahu source data. It does not use the web app's database, saved category overrides, or category rules. The summary endpoints combine currencies without conversion. If the accounts include foreign currencies, the app labels those totals and omits the dollar symbol. Account balances retain their currency.

The app reads stats every five minutes. **Reload stats** reads them immediately. Neither action requests a bank refresh. Failed summary endpoints leave account balances visible. A failed account request retains the previous snapshot and displays an error.

Each refresh starts a backend and stops it after the dashboard response. Swift retains the displayed data between refreshes.

## Local history and alerts

**Control–Option–R** opens Reckon from any app. It uses a registered macOS hotkey and does not request Accessibility or Input Monitoring access. Disable it in Settings → Controls. If another app owns the shortcut, Settings shows the conflict.

Reckon records up to 90 daily balance observations per account. It retains the latest observation for each Auckland day. Sparklines appear once two days are available. Missing days are not synthesised.

History, visit baselines, alert limits, and alert state are encrypted with AES-GCM in `~/Library/Application Support/nz.reckon.native/balance-history.enc`. A random 256-bit key stays in Keychain. Unreadable or unauthentic history is left untouched and an error appears in Settings → Controls. A disconnect or a user token change resets local history and alert settings.

Alerts are off initially. Open Settings → Alerts to enable notifications and choose limits. Reckon requests permission only when you enable alerts.

Balance alerts trigger on crossings from at-or-above to below the chosen limit, with no first-fetch or repeated-below alerts. A currency change clears that account’s limit. Standing order alerts compare the NZD recurring estimates used by Dead reckoning. A first observation sets the baseline. Repeats or decreases do not alert. These are changes in detected estimates, not confirmation that a merchant changed its price.

Notifications have no sound and hide account names and amounts. Open Reckon to view details through the normal unlocked session. The app reads data every five minutes while its interface is locked. Alerts need Reckon to remain open with access to bank data. They do not request an upstream bank refresh.

## App authentication

`Sources/ReckonApp/ReckonLocalAuthentication.swift` uses `LAPolicy.deviceOwnerAuthentication` for both the availability check and authentication.
This policy permits Touch ID, Apple Watch, or the Mac login password. macOS controls which methods are available.
The app leaves the fallback button at its system default. It does not collect the Mac login password.

`ReckonAppLock` starts a ten-minute session after successful authentication. Lock, sleep, and macOS session switches cancel authentication in progress.
Replies from canceled or previous attempts cannot unlock a new session.

The automated checks cover session expiry, cancellation, rejection, and stale replies. They do not exercise the macOS authentication prompt.
Before a release, do these manual checks with a normal app build and the available hardware.
Record any checks that you cannot complete in the release notes:

1. Unlock Reckon with Touch ID on a Mac with a registered fingerprint.
2. Lock Reckon, then unlock it with the Mac login password through the macOS prompt.
3. Confirm that password authentication works on a Mac without Touch ID.
4. Unlock Reckon with an Apple Watch that meets [Apple’s setup requirements](https://support.apple.com/en-us/102442).
5. Cancel the macOS prompt. Confirm that Reckon stays locked.
6. Lock Reckon or put the Mac to sleep while a prompt is open. Confirm that it stays locked after cancellation.

## Backend ownership

`Sources/ReckonCore/BundledBackend.swift` owns the child process, startup protocol, private API token, cancellation, and shutdown. Its `fetchDashboard` operation starts a child for one refresh and stops it on success, failure, or cancellation. There is no idle backend process between refreshes. It passes credentials through stdin. The child watches that pipe and its parent process so it also stops after an app crash. The local API token changes on every launch and stays in memory.

`Backend/src/main.rs` owns the stdin protocol, process signals, parent monitor, and loopback listener. A single-thread Tokio runtime owns HTTP work. A separate thread watches the app pipe. Pipe closure, parent exit, SIGINT, and SIGTERM stop the process and close active source connections.

`native_bank_server.rs` permits authenticated GET requests to seven bank routes and `/health`. It rejects browser origins, incorrect Host headers, writes, and unrelated routes. It parses queries before any source request. `backend_handshake.rs` accepts the production Akahu URL or a local fixture URL only.

`akahu_bank_data.rs` owns the Akahu client, pagination, transient retries, and caches. Each page has a twenty-second budget that includes retries. The client rejects redirects. It permits five retries after the initial request and honors `Retry-After`. `akahu_wire.rs` parses source records and converts them to bank models.

Swift sends the same `X-Reckon-Snapshot` UUID on all eight requests in a dashboard refresh. The first history read starts on the first day six months before the current Auckland month. Each section applies its own date range. Requests outside this range read their full range directly.

The account cache retains one successful result for five minutes. The snapshot cache retains at most four dashboard results for one minute. A new UUID reads fresh history. Failed and cancelled reads do not enter either cache. A mutex shares each active read. If its owner disconnects, another caller can retry.

The caches disappear after each native refresh.

`bank_derivations.rs` owns pure bank calculations. It uses decimal arithmetic and the existing fixed 7/14/30/91-day intervals for recurring estimates. `bank_calendar.rs` owns calendar operations. `bank_models.rs` owns bank identities and decimal JSON output. These modules preserve the native API contract without a second service interface that only forwards calls.

`Sources/ReckonApp` owns SwiftUI, the status item, authentication, and Keychain access. The backend contains no database, budgets, goals, category rules, or write operations.

## Backend performance

`scripts/measure-backend.mjs` measures backend startup, dashboard response time, and process RSS with three fictional accounts and 3,000 transactions. Each scenario uses 20 fresh processes. Source responses have either zero delay or a 50 ms delay. Each dashboard uses a fresh snapshot UUID.

```sh
node scripts/measure-backend.mjs --runs 20 --output .build/rust-backend-performance.json
```

For the original TypeScript version, retain a baseline bundle and select it explicitly:

```sh
node scripts/measure-backend.mjs --implementation typescript --bundle .build/typescript-baseline --runs 20 --output .build/typescript-backend-performance.json
RECKON_BASELINE_BUNDLE="$PWD/.build/typescript-baseline" node --test Tests/backend-integration.test.mjs
```

The optional baseline check compares JSON responses from both implementations against the same fixture. A baseline bundle needs `Contents/Helpers/node` and `Contents/Resources/Backend/backend.cjs`. The baseline process uses the original `--max-semi-space-size=2` setting.

`startupAndDashboardMs` covers the production refresh lifecycle. RSS samples cover the backend process after its first dashboard. These measurements exclude Swift, Keychain, interface work, peak memory, and live Akahu latency. The warm reload metric permits comparison with earlier measurements. It does not represent the current app lifecycle.

See the [Rust comparison](performance/rust-backend-2026-10-22.md) for results and limits. The older reports retain their original TypeScript measurements.

For a read-only comparison with the saved Akahu connection, use:

```sh
node scripts/compare-live-backends.mjs --runs 5 --replay-runs 20
```

This command compares direct live requests, then replays one real-data snapshot held only in memory. It reads credentials from Keychain and keeps all bank records out of its output. The default report path is `.build/live-backend-comparison.json`. See the [real Akahu comparison](performance/live-akahu-backend-2026-10-22.md) for results and limits.

## GitHub builds and releases

The public repository is [deracs/reckon-native](https://github.com/deracs/reckon-native). Pushes to `main` and pull requests build and check Apple silicon and Intel variants. The workflow uses synthetic bank fixtures, needs no Akahu tokens, and uploads ZIPs, SHA-256 checksums, and public update-signature metadata as Actions artifacts.

A version tag such as `vX.Y.Z` creates a GitHub release after both builds and their checks pass. The release job signs and publishes the architecture-specific Sparkle feeds in `updates/` on `main`. Replace `X.Y.Z` with the version from `CFBundleShortVersionString` in `Resources/Info.plist`. Increment `CFBundleVersion` for each release.

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

Release access follows the repository’s visibility. The ZIP contains only the app and runtime. Each user connects their own Akahu tokens. It does not export a Keychain entry or local history.

The app icon uses the existing Reckon monogram as a reference. The built-in imagegen tool generated `Resources/AppIcon-source.png`. The exact prompt is in `Resources/AppIcon-prompt.txt`. The build exports the PNG at macOS icon sizes and creates `Resources/Reckon.icns`. Image transparency stays unchanged.

## Update signatures

Settings → Updates has **Check for Updates**, automatic check and automatic installation controls. Reckon checks GitHub every six hours by default. Sparkle downloads signed updates, installs them when the app quits, and can relaunch it when requested. Bank credentials, encrypted history and launch-at-login settings remain on this Mac.

Updates restart with Reckon locked. The normal macOS authentication policy still applies. Demo mode never starts the updater.

Updates come from the public `deracs/reckon-native` repository. No GitHub token or sign-in is required, and the updater never reads or sends Akahu credentials. The original Reckon monorepo is separate and stays private.

Feeds and archives use Ed25519 signatures with `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` enabled. The verification key is in the app. The dedicated signing key is in the maintainer's Keychain and the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Do not rotate or lose it casually: installed apps trust that key.

The local Sparkle tools use Keychain account `nz.reckon.native.update-signing`. The release-signing script verifies the public key matches before it publishes a signature. A separate test signs synthetic updates and confirms that wrong keys and tampered archives or feeds are rejected.

The update-signing key is not an Apple Developer ID certificate. Personal builds remain ad-hoc signed. macOS can request Keychain access after an app update. Developer ID signing and notarization are still needed for normal public distribution. Sparkle does not send a system profile. GitHub still receives ordinary request metadata, such as an IP address and app-version user agent, when an installation checks for updates.

After a release, run `git pull --ff-only origin main`. This imports the automated feed commit before the next change. This preserves the published feed files.

Update feeds use GitHub’s raw-file host because Sparkle requests RSS, and the GitHub Contents API returns JSON under that Accept header. Initial builds through 0.7.1 require a one-time manual installation of 0.7.2 to switch feed hosts. Later updates use Sparkle.

## Privacy before publication

The repository starts with fresh history and synthetic fixtures. `.env`, Keychain entries, local history, build caches, Node dependencies, app bundles, logs, archives, and signing credentials are excluded from Git. Commits use a GitHub noreply email rather than a personal address.

Run the privacy check before a push or a build upload:

```sh
node scripts/check-release-privacy.mjs --app dist/Reckon.app
node scripts/check-release-privacy.mjs --env-file /path/to/reckon/.env --app dist/Reckon.app
```

The optional second command compares tracked files and the app directly against saved secret values without disclosure of those values. Checks also reject credential patterns, live Akahu account or transaction IDs, personal home paths, and private or generated file types. CI runs these checks before upload. No real `.env` enters CI. Enable the local pre-commit check with `git config core.hooksPath .githooks` after you clone the repository.

See [the publication audit](PUBLICATION-AUDIT.md) for the checked scope and limits. Recheck future changes, screenshots, logs, and release attachments before you make the repository public. The original Reckon monorepo and its Git history are a separate audit scope.
