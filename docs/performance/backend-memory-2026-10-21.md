# Backend memory reduction — 21 October 2026

Reckon now starts a backend for each dashboard refresh and stops it after the eight responses arrive. Swift retains the dashboard, journal, and alert state. There is no backend process between refreshes. Success, failure, and task cancellation all release the child and its HTTP session. The five-minute polling interval and manual reload remain available.

While running, the backend also uses less memory. Effect’s `NodeHttpClient.layerNodeHttp` replaces the Fetch transport, and the native launcher passes `--max-semi-space-size=2` to Node. The HTTP layer still owns connections, retries, cancellation, and JSON decoding. Redirect rejection remains covered by the integration tests.

## Measured comparison

Both reports use Apple M3 Pro arm64, bundled Node v24.21.0, Effect 4.0.5, three synthetic accounts, and 3,000 posted transactions. Each latency scenario has 20 fresh processes. The baseline is the [earlier report](backend-2026-10-21.md) from commit `7ec582c`; it was reproduced at 135.7 MiB in five additional local runs before making changes.

| Median measurement | Baseline, local source | Current, local source | Baseline, 50 ms per response | Current, 50 ms per response |
| --- | ---: | ---: | ---: | ---: |
| Backend RSS at readiness | 76.7 MiB | 77.1 MiB | 76.7 MiB | 77.1 MiB |
| Backend RSS after first dashboard | 134.6 MiB | 99.0 MiB | 132.6 MiB | 98.7 MiB |
| Backend startup | 77.4 ms | 84.5 ms | 85.5 ms | 89.1 ms |
| First dashboard, after readiness | 84.8 ms | 73.6 ms | 291.8 ms | 294.1 ms |
| Startup plus first dashboard | 166.0 ms | 159.4 ms | 378.7 ms | 385.3 ms |
| Supplemental warm-process reload | 34.3 ms | 43.6 ms | 194.9 ms | 209.1 ms |

Loaded RSS fell by 35.6 MiB (26.5%) in the local-source scenario. The current loaded-RSS p95 was 99.5 MiB locally and 98.9 MiB with source latency. Startup plus dashboard p95 was 204.0 ms locally and 399.7 ms with source latency.

A production refresh now pays startup each time. Compared with the baseline’s immediate warm reload, a new-process refresh takes approximately 125 ms longer locally or 190 ms longer with the simulated source latency. It also re-reads the account list: ten upstream requests per refresh rather than nine for a warm process whose account cache has not expired. Transaction history is still fetched once per account and page, shared across all dashboard sections.

These are backend and harness measurements. Startup plus dashboard is the sum of the two timed phases, excluding the RSS sampling between them. It excludes Swift decoding, SwiftUI rendering, Keychain access, and live Akahu. Medians of combined phases are calculated from each run’s sum, rather than by adding their separate medians.

The RSS readings count shared resident pages. They are neither peak allocations nor the whole Swift app’s memory. “No idle backend” means the child process has exited; Swift still retains the displayed dashboard and local history. The Swift checks verify process disappearance after a successful refresh, failed accounts request, and cancelled refresh.

## Diagnosis and runtime choice

The initial 3,000-transaction workload reproduced about 136 MiB. Reducing it to 30 transactions still used about 112 MiB, which pointed to fixed runtime/transport costs as well as data allocations.

Changing only the Effect transport reduced loaded RSS to 111.7 MiB in five local runs. Adding a 2 MiB semi-space setting reduced it to 99.2 MiB in five runs. The 1 MiB and 4 MiB candidates used approximately 100.3 and 102.6 MiB respectively. The final 20-run measurement uses 2 MiB. The snapshot cache’s existing capacity and expiry rules were retained.

The setting limits the young generation, not the total heap. Node documents the memory/throughput tradeoff and recommends workload benchmarks for [semi-space tuning](https://github.com/nodejs/node/blob/main/doc/api/cli.md#--max-semi-space-sizesize-in-mib). No forced garbage collection or hard old-generation cap is used.

As a capacity check, the same fixture was increased to 30,000 transactions and run twice per latency scenario. All dashboard responses decoded successfully, with the expected 64 initial source requests and 63 warm reload requests. Loaded RSS was approximately 179 MiB locally and 163 MiB with source latency. This demonstrates that 99 MiB is specific to the 3,000-transaction fixture, not a memory ceiling. The production process still exits after receiving that larger dashboard. These two-run figures are sanity checks, not reliable latency percentiles.

## Reproduce

Build the app, then run:

```sh
node scripts/measure-backend.mjs --runs 20 --output .build/backend-performance.json --max-loaded-rss-mib 110
```

The optional limit asserts that the median loaded RSS in each scenario stays at or below 110 MiB for the default fixture. It is a local regression budget and should be re-evaluated for other architectures or Node versions. The script uses the same runtime flag as the native launcher. Its warm-process reload remains a comparison tool; the native app stops its backend after each refresh.

[Raw samples, environment, bundle hash, and larger-history check](backend-memory-2026-10-21.json) identify the measured backend (983,199 bytes, SHA-256 `b0b0cc3b64787c2d20531ba216b2fb48f4630700f146d8d8296b25694c4d4b73`). All inputs are synthetic; no saved credentials or bank data were used.
