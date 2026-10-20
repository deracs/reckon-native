# Developer guide

For installation and everyday use, read the [README](../README.md). Run the commands below from the repository root.

## Build from source

The build requires Swift 6, the macOS Command Line Tools, PNPM 10.12.1, and Node 24. Xcode is optional.

The adapted Reckon backend source lives in `Backend/Reckon`. A source build needs no other checkout or private repository token. `Backend/Reckon/SOURCE.json` records its origin and current file hashes. This copy contains only the native app domain and Akahu adapter.

```sh
pnpm install --frozen-lockfile
./scripts/download-node.sh
export RECKON_NODE_BINARY="$PWD/.build/node-runtime/node-v24.21.0-darwin-$(uname -m | sed 's/x86_64/x64/')/bin/node"
export RECKON_NODE_LICENSE="$(dirname "$(dirname "$RECKON_NODE_BINARY")")/LICENSE"
./scripts/build-app.sh
open dist/Reckon.app
```

The script copies the standalone Node runtime, backend, and license notices into the app bundle, embeds the pinned Sparkle framework, then signs the bundle locally. `RECKON_NODE_BINARY` and `RECKON_NODE_LICENSE` select a standalone Node runtime and its license. `./scripts/download-node.sh` downloads the pinned official runtime for the current Mac architecture and verifies its SHA-256 checksum. On GitHub Actions it exports those paths for the next build step.

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
node --test Tests/backend-integration.test.mjs Tests/software-updates.test.mjs
```

Build the app before the checks. The Swift checks exercise the bundled process. The integration checks use a local Akahu fixture and run the bundled backend from a temporary directory. They require no real credentials or bank connection.

The Swift checks use an executable runner because the standalone Command Line Tools omit the Swift Testing and XCTest modules.

## TypeScript tooling

The backend pins Effect and `@effect/platform-node` to 4.0.5. It uses Effect HTTP modules, the Node server adapter, and the Node runtime. `FetchHttpClient` uses the Fetch API in Node without a separate Undici dependency.

`pnpm check` runs TypeScript, Oxlint with the recommended Effect rules, and the Oxfmt format check. The separate commands are `pnpm typecheck`, `pnpm lint`, and `pnpm fmt:check`. Oxlint warnings and errors fail the check.

`pnpm lint:fix` applies automatic lint corrections. `pnpm fmt` formats JavaScript, TypeScript, configuration, and workflow files. It includes the adapted backend source and excludes Markdown. Update the source hashes after changes to the adapted copy.

The type check includes `Tests/backend-schema-types.test.ts`. This test makes sure that plain records and structurally similar classes cannot replace a decoded schema class.

The project permits Effect v4 APIs that carry the unstable label. The `unstable-api-usage` lint rule is disabled. Exact dependency pins and local HTTP fixture tests cover these integration boundaries.

All numeric wire amounts, numeric query parameters, and numeric domain output fields reject non-finite values. Fixture tests cover rejected `NaN`, infinities, numeric overflow, and valid signed decimal strings.

`pnpm install` runs `effect-tsgo patch --oxlint`, which patches both TypeScript 7 and Oxlint's type-aware engine with `@effect/tsgo`. Their versions are pinned together because the patch supports specific compiler and linter versions. Effect diagnostics run through Oxlint; the language-service plugin retains completions, quick info, and refactors without duplicate diagnostics.

The root `tsconfig.json` supplies the same module aliases and compiler settings to editors, checks, and esbuild. In VS Code-based editors, install the TypeScript 7 extension and the [Oxc extension](https://oxc.rs/docs/guide/usage/linter/editors.html), then select the workspace TypeScript version if prompted. The committed workspace settings select the patched native compiler. For other LSP clients, `pnpm exec effect-tsgo get-exe-path` prints the native server executable; launch it with `--lsp --stdio`.

For UI checks with sample data:

```sh
open -n dist/Reckon.app --args --demo --preview
```

Demo mode displays a sample-data label and skips Touch ID for UI checks. It does not read the saved credentials or start a backend. Only these fixtures are available in demo mode. The `--preview` option also opens the dropdown in a window.

## Data and calculations

The dropdown has one row of six icon tabs with hover labels: **Overview**, **Accounts**, **Activity**, **Dead reckoning**, **The bleed**, and **Standing orders**. Each icon has an accessibility label.

Small info icons beside headings hold longer explanations: hover for a tooltip or click for a readable popover. Currency and estimate warnings remain visible. A tab change returns that list to the top.

- The menu bar always shows only the chart icon. Liquid balance appears in the dropdown after Touch ID authentication.
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

The backend uses Akahu source data. It does not use the web app's database, saved category overrides, or category rules. The summary endpoints combine currencies without conversion. If the accounts include foreign currencies, the app labels those totals and omits the dollar symbol. Account balances retain their currency.

The app reads stats every five minutes. **Reload stats** reads them immediately. Neither action requests a bank refresh. Failed summary endpoints leave account balances visible. A failed account request retains the previous snapshot and displays an error. After a backend crash, the next reload starts a new backend.

## Local history and alerts

**Control–Option–R** opens Reckon from any app. It uses a registered macOS hotkey and does not request Accessibility or Input Monitoring access. Disable it in Settings → Controls. If another app owns the shortcut, Settings shows the conflict.

Reckon records up to 90 daily balance observations per account. It retains the latest observation for each Auckland day. Sparklines appear once two days are available. Missing days are not synthesised.

History, visit baselines, alert limits, and alert state are encrypted with AES-GCM in `~/Library/Application Support/nz.reckon.native/balance-history.enc`. A random 256-bit key stays in Keychain. Unreadable or unauthentic history is left untouched and an error appears in Settings → Controls. A disconnect or a user token change resets local history and alert settings.

Alerts are off initially. Open Settings → Alerts to enable notifications and choose limits. Reckon requests permission only when you enable alerts.

Balance alerts trigger on crossings from at-or-above to below the chosen limit, with no first-fetch or repeated-below alerts. A currency change clears that account’s limit. Standing order alerts compare the NZD recurring estimates used by Dead reckoning. A first observation sets the baseline. Repeats or decreases do not alert. These are changes in detected estimates, not confirmation that a merchant changed its price.

Notifications have no sound and hide account names and amounts. Open Reckon to view details through the normal Touch ID session. The app reads data every five minutes while its interface is locked. Alerts need Reckon to remain open with access to bank data. They do not request an upstream bank refresh.

## Backend ownership

`Sources/ReckonCore/BundledBackend.swift` owns the child process, startup protocol, private API token, cancellation, and shutdown. It passes credentials through stdin. The child watches that pipe and its parent process so it also stops after an app crash. The local API token changes on every launch and stays in memory.

`Backend/backend-main.ts` connects the Akahu adapter, `NodeRuntime`, and the local HTTP boundary in `Backend/native-bank-server.ts`. Effect's `NodeHttpServer` owns the listener and request scope. It listens on `127.0.0.1`. macOS selects the port.

The API permits authenticated GET requests to seven bank routes and `/health`. It rejects browser origins, incorrect Host headers, writes, and unrelated routes. Effect schemas decode queries and encode responses. Logs contain no bank records or credentials.

`akahu-http-client.ts` uses Effect `HttpClient` for authenticated GET requests and JSON codecs. It retries transient failures up to five times with exponential backoff and jitter. It honors `Retry-After`, rejects redirects, and limits each page read to twenty seconds. Source failures become safe `BankDataError` values and generic HTTP 502 responses.

Effect `Stream.paginate` reads each source page. Effect `Cache` shares one history read across a dashboard reload. Swift sends the same `X-Reckon-Snapshot` UUID on all eight requests in that reload. The shared history starts on the first day of the month six months before the current Auckland month. Each section applies its own date range before calculations.

The history cache retains at most four successful reloads for one minute. Each new reload uses a new UUID, so manual reloads read fresh transaction history immediately. The account cache retains one successful account list for five minutes. Failed reads expire immediately. Requests without a snapshot ID read history directly. Requests outside the shared date range also read their full requested range directly.

A failed history read leaves account balances available. Client disconnects and app shutdown interrupt active reads and close source connections. App pipe closure, parent exit, SIGINT, and SIGTERM close the root Effect scope before process exit. The backend contains seven bank operations. It contains no database services, budgets, goals, category rules, taxonomy bundle, or unsupported write methods.

`scripts/build-backend.mjs` creates one JavaScript bundle from the source snapshot in `Backend/Reckon`. `Sources/ReckonApp` owns SwiftUI, the native status item and popover lifecycle, Touch ID, and Keychain access. `ReckonAppLock` rejects authentication replies from cancelled or previous sessions. No database or TypeScript calculation port is needed.

The backend uses strict TypeScript checks with `exactOptionalPropertyTypes` and `noUncheckedIndexedAccess`. Oxlint also applies its recommended Effect diagnostics.

## Backend performance

`scripts/measure-backend.mjs` measures backend startup, dashboard HTTP response time, and backend RSS with a local synthetic fixture. The fixture contains three accounts and 3,000 transactions. It compares zero delay with a 50 ms delay per source response. Each dashboard uses a fresh snapshot UUID. The [21 October 2026 measurements](performance/backend-2026-10-21.md) describe the method and limits.

```sh
node scripts/measure-backend.mjs --runs 20 --output .build/backend-performance.json
```

## GitHub builds and releases

The public repository is [deracs/reckon-native](https://github.com/deracs/reckon-native). Pushes to `main` and pull requests build and check Apple silicon and Intel variants. The workflow uses synthetic bank fixtures, needs no Akahu tokens, and uploads ZIPs, SHA-256 checksums, and public update-signature metadata as Actions artifacts.

A version tag such as `vX.Y.Z` creates a GitHub release after both builds and their checks pass. The release job signs and publishes the architecture-specific Sparkle feeds in `updates/` on `main`. Replace `X.Y.Z` with the version from `CFBundleShortVersionString` in `Resources/Info.plist`. Increment `CFBundleVersion` for each release.

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

Release access follows the repository’s visibility. The ZIP contains only the app and runtime. Each user connects their own Akahu tokens. It does not export a Keychain entry or local history. A Mac without Touch ID cannot unlock the current app.

The app icon uses the existing Reckon monogram as a reference. The built-in imagegen tool generated `Resources/AppIcon-source.png`. The exact prompt is in `Resources/AppIcon-prompt.txt`. The build exports the PNG at macOS icon sizes and creates `Resources/Reckon.icns`. Image transparency stays unchanged.

## Update signatures

Settings → Updates has **Check for Updates**, automatic check and automatic installation controls. Reckon checks GitHub every six hours by default. Sparkle downloads signed updates, installs them when the app quits, and can relaunch it when requested. Bank credentials, encrypted history and launch-at-login settings remain on this Mac.

Updates restart with Reckon locked. The normal Touch ID policy still applies. Demo mode never starts the updater.

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
