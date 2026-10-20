# Reckon Native

Your NZ bank accounts, balances, and recent activity in the macOS menu bar.
Reckon connects to Akahu and runs as a standalone app. You do not need a terminal or a separate server.

**[Download the latest release](https://github.com/deracs/reckon-native/releases/latest)**

## What you need

- **macOS 15 or later.** Apple silicon and Intel Macs are supported.
- **Touch ID** with a fingerprint set up on your Mac. Reckon has no password or Apple Watch fallback.
- **An Akahu personal app** with access to your accounts. You need its App ID token and User Access token.

## Install Reckon

1. Open the [latest release](https://github.com/deracs/reckon-native/releases/latest).
2. Under **Assets**, download the ZIP for your Mac:
   - **Apple silicon** (M1 or later): choose the file that ends in `arm64.zip`.
   - **Intel**: choose the file that ends in `x86_64.zip`.
3. Open the ZIP file.
4. Drag **Reckon.app** into **Applications**.
5. Open Reckon from Applications.

To check your Mac type, open **Apple menu → About This Mac**. Look for **Chip** or **Processor**.

This personal build has no Apple Developer ID signature or notarization.
If macOS blocks the first launch, review the app in **System Settings → Privacy & Security**.
A work-managed Mac can block the app entirely.

## Connect your accounts

For your first Akahu connection, use [Akahu’s personal app guide](https://developers.akahu.nz/docs/personal-apps).

1. Open the [**Developers** page in Akahu](https://my.akahu.nz/developers).
2. Get the **App ID token** and **User Access token** for your Akahu personal app.
3. Click the **chart icon** in the macOS menu bar.
4. Unlock Reckon with Touch ID.
5. Click **Connect Akahu**.
6. Enter each token in its named field.
7. Click **Save and connect**.

Reckon saves the tokens in your Mac’s Keychain. Later launches use the saved connection.
Reckon reads account data. It cannot move money or make payments.

## Find your way around

Hover over a tab icon to see its name. Hover over a small **info icon** for an explanation, or click it.

| Tab | What it shows |
| --- | --- |
| **Overview** | Liquid balance, this month’s income and spending, estimated payday, and data freshness. |
| **Accounts** | Accounts grouped by bank, with bank logos and totals for each currency. Click the whole bank row to expand it. |
| **Activity** | Recent transactions, search, and a filter for transactions first seen since your previous visit. |
| **Dead reckoning** | A 30-day balance estimate from regular income and bills. Everyday discretionary spending is not included. |
| **The bleed** | The five largest spending categories this month, compared with the previous three months’ average. |
| **Standing orders** | Detected regular charges and estimated bills due in the next seven days. |

The menu bar shows only the chart icon. Your balances appear inside the dropdown after you unlock it.

## Everyday use

- **Open from any app:** press **Control–Option–R**. Change the shortcut option in **Settings → Controls**.
- **Open Settings:** click the **gear icon** in the dropdown.
- **Start with your Mac:** enable **Launch at login** in **Settings → Connection**. Keep Reckon in Applications.
- **Read the latest data:** click **Reload stats**. Reckon also reads data every five minutes.
- **Enable alerts:** open **Settings → Alerts**. Alerts are off by default. Notification banners hide account names and amounts.
- **Lock immediately:** click the **lock icon**. Reckon otherwise locks ten minutes after you unlock it.

Sleep or a macOS session switch also locks Reckon. The app can continue to read data while its interface is locked.

## Updates

Reckon checks GitHub every six hours. Automatic downloads and installation are on by default.
Updates install when Reckon quits, or you can choose to install and relaunch immediately.

For a manual check, open **Settings → Updates → Check for Updates**.
Updates keep your saved connection, local history, and login preference. Touch ID still applies after the app restarts.

For version 0.7.1 or earlier, install the latest release manually once. Later updates use the current update feed.

## Your data

- Akahu tokens stay in **macOS Keychain**.
- Balance history stays **encrypted on this Mac**, with up to 90 daily observations per account.
- Update checks send **no bank data or Akahu tokens** to GitHub. GitHub receives normal connection metadata, such as your IP address.
- The public source and release downloads contain **no saved bank connection or personal bank history**.

**Disconnect & clear local history** in Settings → Connection removes the saved tokens and resets local history and alert settings.

## A few things to know

**Liquid balance** includes NZD checking and savings accounts only. Investments and foreign currencies do not contribute to that number.

**Currencies stay separate in Accounts.** Some income and spending totals combine currencies without conversion. Reckon labels those totals as mixed currencies.

**Dead reckoning and payday dates are estimates.** The balance estimate excludes discretionary spending. Detected bills and deposits can change.

## Common questions

### Why does Keychain ask for access again?

Reckon reads two protected items: your Akahu connection and the key for local history.
The current app signature changes between releases, so macOS can ask for permission again after an update.
This prompt is separate from the ten-minute Touch ID session. API requests reuse the credentials already in memory.

### Why can I not unlock Reckon?

Touch ID must be available on your Mac. If Touch ID locks out, unlock your Mac with its password before you try Reckon again.

### Why do bank figures look old?

Check **Bank refresh times** in Overview. Akahu’s source refresh time can differ from Reckon’s latest data read.

### Does this use my Reckon web app settings?

Reckon Native reads Akahu directly. It does not use the web app’s database, category overrides, or category rules.

## For developers

See the [developer guide](docs/DEVELOPMENT.md) for source builds, demo mode, checks, backend details, and release instructions.
See the [publication audit](docs/PUBLICATION-AUDIT.md) for the privacy checks and their limits.
