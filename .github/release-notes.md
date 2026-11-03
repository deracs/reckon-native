# Reckon 0.8.1

## Bills and spending

- Read upcoming bill estimates in a compact panel with dates, a seven-day total, merchant artwork, and source bank/account names.
- See each recurring payment’s bank, account, currency, frequency, and average charge in aligned columns.
- Choose bar or pie charts in desktop Spending. Reckon saves the choice. The pie includes all categories and groups smaller categories under Other categories.
- See the current-month date range and guidance when source transactions have no categories. Activity includes older transactions and can show categories absent from this month’s expenses.
- Keep recurring detection and charge-increase baselines separate by account, currency, and merchant. This can change estimates that previously pooled payments across accounts. The first account-specific observation sets a new alert baseline without a notification.

## Validation

- Rust formatting/Clippy, 60 Swift core checks, backend/integration tests, native window lifecycle checks, release build, signature verification, and privacy checks passed locally. Release checks also exercise the image cache and update signatures. GitHub checks Apple silicon and Intel before publication.
- Native sample-data checks covered chart switching, category inspection, saved chart preferences, account identities, long names, mixed currencies, and empty/error states. Documentation screenshots contain fictional data.
- Real Touch ID, Mac-password, Apple Watch, authentication cancellation during sleep, and macOS session-switch hardware checks were not performed for this release. Automated session expiry/cancellation/stale-reply checks pass. Personal builds remain ad-hoc signed, without Developer ID notarization.
