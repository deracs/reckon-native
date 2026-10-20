# Reckon Native

A personal macOS menu bar app with its own Reckon backend. Requires macOS 15 or later. The app includes Node and the JavaScript backend. You do not need a terminal, a separate server, Node, or Postgres to run it.

## Open and connect

Open `dist/Reckon.app`, click the chart icon in the menu bar, and unlock with Touch ID. On a new connection, choose **Connect Akahu** and enter your Akahu App ID token and User Access token. Get these tokens from the Developers page at <https://my.akahu.nz>.

The installed copy is `/Applications/Reckon.app`. Its launch-at-login registration points to that location.

Reckon saves both tokens in your Mac's Keychain. It starts its backend on launch and stops it on quit. Later launches use the saved tokens. **Disconnect** stops the backend and deletes the saved Akahu tokens.

To import tokens from an existing Reckon `.env` after a build:

```sh
node scripts/import-akahu-env.mjs /path/to/reckon/.env
```

The importer passes only the two Akahu tokens to the signed app over stdin. The app saves them in its own Keychain entry. It does not copy the `.env` into the app or print token values. Reopen Reckon after the import.

Add `/Applications/Reckon.app` as a second argument to import into the installed copy.

**Launch at login** registers this app bundle with macOS. Keep the bundle in a stable location before you enable that option.

The installed app also supports `--launch-at-login-status`, `--enable-launch-at-login`, and `--disable-launch-at-login`. These commands report the bundle path and macOS registration status.

## Touch ID

Click the chart icon in the menu bar to authenticate with Touch ID before opening the dashboard. Reckon stays unlocked for ten minutes after successful authentication. Closing and reopening the dropdown or switching apps within that time does not prompt again or extend the session. After ten minutes, open dashboard and settings views close and Touch ID is required again. Clicking **Lock Reckon**, sleeping the display or Mac, or switching away from the macOS session locks it immediately. Dashboard content stays hidden while locked.

Touch ID must be available and have a fingerprint enrolled. There is no password or Apple Watch fallback. If Touch ID locks out, unlock your Mac with its password before trying Reckon again. Cancelling or failing authentication leaves the app locked. No biometric data enters Reckon; macOS handles the prompt.

This is a lock on Reckon's interface. Saved tokens remain in the Mac's Keychain, and the bundled backend can continue fetching data while the interface is locked.

## Stats

The dropdown has one row of six icon tabs with hover labels: **Overview**, **Accounts**, **Activity**, **Dead reckoning**, **The bleed**, and **Standing orders**. Each icon has an accessibility label. Small info icons beside headings hold longer explanations: hover for a tooltip or click for a readable popover. Currency and estimate warnings remain visible. A tab change returns that list to the top.

- The menu bar always shows only the chart icon. Liquid balance appears in the dropdown after Touch ID authentication.
- Liquid balance includes NZD checking and savings accounts only.
- Accounts are grouped into collapsible bank sections, initially closed. Each bank header shows Akahu's logo, its account count, and current combined balances, with a separate total for each currency. Negative balances are included; currencies are never converted or added together. Click anywhere in the header row to expand or collapse it. Expanded accounts retain their own currencies. Missing or unavailable logos use a bank symbol.
- This month shows income, spending, and net cashflow through today.
- Activity shows the latest 100 non-transfer transactions in the last six months, with search, merchant logos, and a newly-seen filter. Comparison uses transaction IDs, so late bank imports can count as newly seen. A full page labels the count as applying to the latest 100 transactions. Received totals retain their currencies. The first visit sets a baseline.
- Dead reckoning shows a 30-day estimate for NZD checking and savings. It uses detected regular income and bills, excludes inter-account transfers, and does not include everyday discretionary spending. Hover or drag across the chart to inspect a day. The first projected negative day is flagged.
- Estimated payday uses recurring deposits of at least NZ$200, excluding descriptions containing interest, dividends, refunds, cashback or rental payments. It is a conservative heuristic, not a confirmed salary payment; smaller pay deposits may not appear. Interest still contributes to the balance curve.
- Standing orders starts with the estimated bills due in the next seven days for NZD checking and savings.
- The bleed shows the five largest categories this month, with comparison to the previous three full months' average.
- Standing orders show detected charges over six months, with their cadence and average amount.
- Data freshness shows the last API fetch and each account's source refresh times.

Reporting dates use Pacific/Auckland time. Cashflow and spending exclude inter-account transfers through the existing Reckon calculations.

Merchant logos use Akahu’s optional [transaction metadata](https://developers.akahu.nz/docs/the-transaction-model). Unavailable logos fall back to merchant initials. No extra enrichment service is called.

The backend uses Akahu source data. It does not use the web app's database, saved category overrides, or category rules. The summary endpoints combine currencies without conversion. If the accounts include foreign currencies, the app labels those totals and omits the dollar symbol. Account balances retain their currency.

The app reads stats every five minutes. **Reload stats** reads them immediately. Neither action requests a bank refresh. Failed summary endpoints leave account balances visible. A failed account request retains the previous snapshot and displays an error. After a backend crash, the next reload starts a new backend.

## History, shortcut, and alerts

**Control–Option–R** opens Reckon from any app. It uses a registered macOS hotkey and does not request Accessibility or Input Monitoring access. Disable it in Settings → Controls. If another app owns the shortcut, Settings shows the conflict.

Reckon records up to 90 daily balance observations per account, retaining the latest observation for each Auckland day. Sparklines appear once two days are available. Missing days are not synthesised. History, visit baselines, alert limits, and alert state are encrypted with AES-GCM in `~/Library/Application Support/nz.reckon.native/balance-history.enc`. A random 256-bit key stays in Keychain. Unreadable or unauthentic history is left untouched and an error appears in Settings → Controls. Disconnecting or changing the user token resets local history and alert settings.

Alerts are off initially. Open Settings → Alerts to enable notifications and choose limits. Permission is requested only when enabled. Balance alerts trigger on crossings from at-or-above to below the chosen limit, with no first-fetch or repeated-below alerts. A currency change clears that account’s limit. Standing order alerts compare the NZD recurring estimates used by Dead reckoning; a first observation sets the baseline, and repeats or decreases do not alert. These are changes in detected estimates, not confirmation that a merchant changed its price.

Notifications have no sound and hide account names and amounts. Open Reckon to view details through the normal Touch ID session. The app continues polling while its interface is locked. Alerts need Reckon running and access to the bank data; they do not request an upstream bank refresh.

## Build

The build requires Swift 6, the macOS Command Line Tools, PNPM 10.12.1, and Node 24. Xcode is optional. The required Reckon backend source snapshot lives in `Backend/Reckon`; no other checkout or private-repository token is needed. `Backend/Reckon/SOURCE.json` records its origin and source hashes. This snapshot includes the native app’s merchant-logo and NZD forecast fixes. Update it deliberately when pulling in backend changes.

```sh
pnpm install --frozen-lockfile
./scripts/build-app.sh
open dist/Reckon.app
```

The script copies the standalone Node runtime, backend, and license notices into the app bundle, embeds the pinned Sparkle framework, then signs the bundle locally. `RECKON_NODE_BINARY` and `RECKON_NODE_LICENSE` select a standalone Node runtime and its license. `./scripts/download-node.sh` downloads the pinned official runtime for the current Mac architecture and verifies its SHA-256 checksum. On GitHub Actions it exports those paths for the following build step.

The completed app has no dependency on source directories or build tools. Personal builds are ad-hoc signed. Distribution with normal Gatekeeper acceptance needs a Developer ID signature and Apple notarization; the workflow does not claim to provide those. A downloaded personal build may need approval under System Settings → Privacy & Security, and managed Macs may block it.

## GitHub builds and releases

The public repository is [deracs/reckon-native](https://github.com/deracs/reckon-native). Pushes to `main` and pull requests build and check Apple silicon and Intel variants. The workflow uses synthetic bank fixtures, needs no Akahu tokens, and uploads ZIPs, SHA-256 checksums, and public update-signature metadata as Actions artifacts. A version tag such as `v0.7.3` creates a GitHub release after both builds and their checks pass. The release job signs and publishes the architecture-specific Sparkle feeds in `updates/` on `main`. The tag must match `CFBundleShortVersionString` in `Resources/Info.plist`.

```sh
git tag v0.7.3
git push origin v0.7.3
```

Release access follows the repository’s visibility. The ZIP contains only the app and runtime; each user connects their own Akahu tokens. It does not export a Keychain entry or local history. A Mac without Touch ID cannot unlock the current app.

The app icon uses the existing Reckon monogram as a reference. The built-in imagegen tool generated `Resources/AppIcon-source.png`. The exact prompt is in `Resources/AppIcon-prompt.txt`. The build exports the PNG at macOS icon sizes and creates `Resources/Reckon.icns`, preserving the generated transparency.

## Checks

```sh
node scripts/build-backend.mjs --check
swift run -Xswiftc -warnings-as-errors ReckonChecks
node --test Tests/backend-integration.test.mjs Tests/software-updates.test.mjs
```

Build the app before the checks. The Swift checks exercise the bundled process. The integration checks use a local Akahu fixture and run the bundled backend from a temporary directory. They require no real credentials or bank connection.

The Swift checks use an executable runner because the standalone Command Line Tools omit the Swift Testing and XCTest modules.

For UI checks with sample data:

```sh
open -n dist/Reckon.app --args --demo --preview
```

Demo mode displays a sample-data label and skips Touch ID for UI checks. It does not read the saved credentials or start a backend. Only these fixtures are available in demo mode. The `--preview` option also opens the dropdown in a window.

## Backend ownership

`Sources/ReckonCore/BundledBackend.swift` owns the child process, startup protocol, private API token, cancellation, and shutdown. It passes credentials through stdin. The child watches that pipe and its parent process so it also stops after an app crash. The local API token changes on every launch and stays in memory.

`Backend/backend-main.ts` wires the existing Reckon API contract, handlers, Akahu adapter, and domain calculations. It listens on `127.0.0.1` with an OS-selected port. It permits authenticated GET requests to accounts, cashflow, spending, recurring charges, freshness, transactions, forecast, and health only. Requests from browser origins, incorrect Host headers, writes, and unrelated API routes are rejected. Logs contain no bank records or credentials.

`scripts/build-backend.mjs` creates one JavaScript bundle from the source snapshot in `Backend/Reckon`. `Sources/ReckonApp` owns SwiftUI, the native status item and popover lifecycle, Touch ID, and Keychain access. `ReckonAppLock` rejects authentication replies from cancelled or previous sessions. No database or TypeScript calculation port is needed.

The backend typecheck retains the Reckon snapshot’s existing optional-property and array-index rules. Enabling `exactOptionalPropertyTypes` and `noUncheckedIndexedAccess` produces errors in imported Reckon source, including `Akahu.ts`, `CashRunway.ts`, and `derivations.ts`. The source snapshot preserves those rules. All other configured strict checks and Effect diagnostics apply.

## Privacy before publication

The repository starts with fresh history and synthetic fixtures. `.env`, Keychain entries, local history, build caches, Node dependencies, app bundles, logs, archives, and signing credentials are excluded from Git. Commits use a GitHub noreply email rather than a personal address.

Run the privacy check before pushing or attaching a build:

```sh
node scripts/check-release-privacy.mjs --app dist/Reckon.app
node scripts/check-release-privacy.mjs --env-file /path/to/reckon/.env --app dist/Reckon.app
```

The optional second command compares tracked files and the app directly against saved secret values without printing them. Checks also reject credential patterns, live Akahu account or transaction IDs, personal home paths, and private or generated file types. CI runs these checks before upload; no real `.env` is sent to CI. Enable the local pre-commit check after cloning with `git config core.hooksPath .githooks`.

See [the publication audit](docs/PUBLICATION-AUDIT.md) for the checked scope and limits. Recheck future changes, screenshots, logs, and release attachments before making the repository public. The original Reckon monorepo and its Git history are a separate audit scope.

## Software updates

Settings → Updates has **Check for Updates**, automatic check and automatic installation controls. Reckon checks GitHub every six hours by default. Sparkle downloads signed updates, installs them when the app quits, and can relaunch it when requested. Bank credentials, encrypted history and launch-at-login settings remain on this Mac. Updates restart with Reckon locked; the normal Touch ID policy still applies. Demo mode never starts the updater.

Updates come from the public `deracs/reckon-native` repository. No GitHub token or sign-in is required, and the updater never reads or sends Akahu credentials. The original Reckon monorepo is separate and stays private.

Feeds and archives use Ed25519 signatures with `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` enabled. The verification key is in the app; the dedicated signing key is in the maintainer's Keychain and the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Do not rotate or lose it casually: installed apps trust that key. The local Sparkle tools use Keychain account `nz.reckon.native.update-signing`. The release-signing script verifies the public key matches before publishing a signature. A separate test signs synthetic updates and confirms that wrong keys and tampered archives or feeds are rejected.

The update-signing key is not an Apple Developer ID certificate. Personal builds remain ad-hoc signed; macOS may request Keychain access after a changed binary. Developer ID signing and notarization are still needed for normal public distribution. Sparkle disables system profiling here. GitHub still receives ordinary request metadata, such as an IP address and app-version user agent, when an installation checks for updates.

After a release publishes its signed feeds, fast-forward the local checkout to include the automated feed commit before the next change. This preserves the published feed files.

Update feeds use GitHub’s raw-file host because Sparkle requests RSS, and the GitHub Contents API returns JSON under that Accept header. Initial builds through 0.7.1 require a one-time manual installation of 0.7.2 to switch feed hosts. Later updates use Sparkle.
