# Rust backend experiment — 22 October 2026

The Rust backend reduces process startup time, dashboard time, and memory use in this local benchmark. With zero source delay, the median refresh takes 19.9 ms instead of 161.3 ms. Loaded backend RSS falls from 99.0 MiB to 13.2 MiB, a reduction of 86.6%.

With 50 ms per source response, the median refresh takes 237.4 ms instead of 379.7 ms, a reduction of 37.5%. Source latency still dominates this scenario.

## Results

Each value is the median of 20 fresh processes. A lower value is better.

| Source delay per response | Measurement | TypeScript / Node | Rust | Reduction |
| --- | --- | ---: | ---: | ---: |
| 0 ms | Startup | 83.8 ms | 6.0 ms | 92.8% |
| 0 ms | First dashboard | 76.2 ms | 14.0 ms | 81.6% |
| 0 ms | Startup + dashboard | 161.3 ms | 19.9 ms | 87.7% |
| 0 ms | Loaded backend RSS | 99.0 MiB | 13.2 MiB | 86.6% |
| 0 ms | Warm fresh reload | 43.4 ms | 11.0 ms | 74.7% |
| 50 ms | Startup | 90.3 ms | 9.7 ms | 89.3% |
| 50 ms | First dashboard | 289.3 ms | 228.1 ms | 21.1% |
| 50 ms | Startup + dashboard | 379.7 ms | 237.4 ms | 37.5% |
| 50 ms | Loaded backend RSS | 98.7 MiB | 13.5 MiB | 86.3% |
| 50 ms | Warm fresh reload | 202.1 ms | 171.4 ms | 15.2% |

The first dashboard makes ten upstream requests in both implementations. A warm fresh reload makes nine requests in both implementations. Both versions fetch each history page once per dashboard.

## Method and evidence

The host uses an Apple M3 Pro, arm64, and macOS Darwin 25.5.0. The TypeScript process uses Node v24.21.0 with `--max-semi-space-size=2`. The Rust build uses rustc 1.98.1, release optimization, LTO, one codegen unit, and stripped symbols.

The baseline is the bundled TypeScript backend captured before changes on `main` at `83ca945`. Its JavaScript SHA-256 is `e766630c3ae9392198b41b283e558c7ba687d22e34788bc8eb0bb02a246c6575`. The experiment branch is `codex/rust-backend`.

The same harness runs both implementations against three fictional accounts and 3,000 posted transactions. Each dashboard has eight concurrent authenticated requests. The final measurements ran TypeScript first, then Rust, after all builds and checks completed. OS caches remain warm.

Startup time ends at the ready message on stdout. Dashboard time includes HTTP responses and JSON decode in the harness. RSS comes from `ps` after the first dashboard, outside the timed intervals. The combined metric adds startup and dashboard time. It excludes the RSS measurement interval.

Raw results include every sample, medians, p95 values, ranges, workload details, and backend hashes:

- [TypeScript results](typescript-backend-2026-10-22.json)
- [Rust results](rust-backend-2026-10-22.json)

Use the commands in the [developer guide](../DEVELOPMENT.md#backend-performance) to repeat the comparison. The harness can select a retained TypeScript bundle without a second backend in the app.

## Implementation and checks

The branch replaces the TypeScript backend with a standalone Rust executable. It removes the Effect dependencies, TypeScript tools, source snapshot, and Node runtime from the app bundle. Node remains a development tool for fixtures and release scripts. Swift still owns the interface, Keychain, history, authentication, and refresh lifecycle.

The Rust modules replace the previous domain, Akahu adapter, and HTTP boundary. Decimal arithmetic remains exact after the same finite-number conversion at the source boundary. Separate modules own calculations, source parsers, source reads, HTTP requests, and process startup. A second service interface adds no useful behavior.

The branch passes these checks:

- Eight Rust tests, with generated projection windows across leap days and all four cadences.
- Thirty-eight HTTP and update checks, with a direct JSON comparison with the original backend across all seven routes.
- Fifty Swift checks, with startup, authentication, restart, cancellation, and child-process cleanup.
- Rustfmt, Clippy with warnings as errors, Oxlint, Oxfmt, app signature verification, and the release privacy check.

The direct comparison includes pending transactions, missing metadata, decimal rounding, transfer filters, pagination, and shared snapshots. Source failure checks cover retries, redirects, invalid money, cancellation, and immediate recovery.

## Limits

These results measure the backend process. They do not measure the full Swift app, peak RSS, energy use, or the macOS authentication prompt. The app stops its backend after each refresh, so warm reload time is a supplemental metric.

The fixture has local HTTP responses and fixed delays. It does not reproduce live Akahu latency, TLS traffic, rate limits, or account volumes. No real bank credentials enter the benchmark. Intel execution remains untested locally. The CI workflow retains both Mac architectures.

The release app is available at `dist/Reckon.app`. This experiment does not publish a release or replace the installed app.
