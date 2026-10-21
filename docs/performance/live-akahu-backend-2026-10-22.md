# Real Akahu comparison — 22 October 2026

Rust reduces refresh time and memory use with the saved Akahu connection. Across five live trials per backend, median startup plus dashboard time falls from 13.12 seconds to 10.80 seconds. This is a reduction of 17.7%. Loaded backend RSS falls from 84.7 MiB to 13.7 MiB, a reduction of 83.9%.

All eight dashboard sections match exactly across all five live pairs. Twenty additional pairs also match against one identical real-data snapshot in memory.

## Measurements

The table shows medians. Live trials include direct Akahu requests over HTTPS. Same-data replay uses captured Akahu pages over loopback and excludes external latency and TLS.

| Mode | Measurement | TypeScript / Node | Rust | Reduction |
| --- | --- | ---: | ---: | ---: |
| Live Akahu | Startup | 203.4 ms | 9.6 ms | 95.3% |
| Live Akahu | Dashboard | 12998.5 ms | 10789.9 ms | 17.0% |
| Live Akahu | Startup + dashboard | 13119.1 ms | 10802.8 ms | 17.7% |
| Live Akahu | Loaded backend RSS | 84.7 MiB | 13.7 MiB | 83.9% |
| Same-data replay | Startup | 74.0 ms | 6.3 ms | 91.5% |
| Same-data replay | Dashboard | 63.2 ms | 12.8 ms | 79.7% |
| Same-data replay | Startup + dashboard | 136.7 ms | 19.2 ms | 86.0% |
| Same-data replay | Loaded backend RSS | 95.5 MiB | 10.4 MiB | 89.1% |

Live refresh times range from 12.37–14.25 seconds for TypeScript and 10.26–10.91 seconds for Rust. Each Rust live trial completes faster than every TypeScript live trial in this session. Five live samples per backend provide a local comparison, not a stable latency guarantee.

## Method

The host uses an Apple M3 Pro, arm64, and Darwin 25.5.0. The backends match the binaries from the [fictional-data comparison](rust-backend-2026-10-22.md). TypeScript uses Node v24.21.0 with `--max-semi-space-size=2`. Rust uses the release executable from the experiment branch.

Each sample starts a fresh backend process and requests the same eight dashboard sections with a new snapshot UUID. Both backends use credentials from the saved Reckon Keychain item, passed through stdin. The trials alternate their order within each pair to reduce ordering bias.

The live phase performs five pairs against Akahu directly. It uses read-only GET operations and does not request a bank refresh. The replay phase captures one dashboard's source pages in memory, then performs twenty pairs against those exact pages. The replay server cannot contact Akahu after capture. Capture time is excluded from the measurements.

Startup ends at the stdout ready message. Dashboard time includes all responses and JSON decode in the harness. Combined time adds these phases and excludes RSS sampling. `ps` supplies backend RSS immediately after readiness and after the dashboard.

The harness compares the decoded JSON for accounts, cashflow, current spending, previous spending, recurring charges, freshness, transactions, and forecast. Every comparison succeeds. It saves only timings, RSS, binary metadata, and equality counts in the [raw measurements](live-akahu-backend-2026-10-22.json).

## Privacy and limits

Credentials, source pages, and decoded dashboard records remain in process memory. They do not enter logs, command arguments, or result files. The capture is discarded after replay. The saved report contains no balances, account IDs, account names, merchants, categories, or transactions.

These measurements cover backend RSS after the dashboard, not peak memory or the full Swift app. The parent harness and its source snapshot are excluded from backend RSS. Keychain access, Swift decoding, the interface, and authentication are outside the timed phases.

Network conditions, Akahu response times, background Mac activity, and source updates can change live results. The same-data replay confirms a backend improvement under this workload, while the live phase measures its end-to-end effect. Intel performance remains unmeasured.

## Repeat the comparison

The local TypeScript baseline bundle must exist before this command. The script reads the saved connection from Keychain and can cause a normal macOS Keychain access prompt.

```sh
node scripts/compare-live-backends.mjs --runs 5 --replay-runs 20 --output .build/live-backend-comparison.json
```

Use `--baseline-bundle` and `--rust-bundle` to select other app bundles. Both run counts accept 1–30 trials. The default output stays in the ignored `.build` directory. Source data never enters that output.
