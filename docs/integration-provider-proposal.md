# Proposal: a boundary for banking integrations

Status: exploration for review; no implementation is proposed in this PR.

## Problem

Reckon reads bank data through Akahu. The backend has reusable bank models and
calculations, but its request handling accepts `AkahuBankData` directly. The
backend startup handshake, credentials, connection settings, and error messages
also assume Akahu. A second banking provider would therefore require changes
throughout the app, even if it supplied the same basic data.

## Proposed direction

Introduce a small banking data provider boundary around the reads Reckon needs:
accounts, account freshness, and transaction history. A provider translates its
source data into Reckon's bank models. The shared backend uses those models for
filtering, summaries, recurring transactions, and forecasting.

```text
Swift interface and connection management
        ↓ credentials over the existing private startup channel
Backend startup selects and constructs the configured provider
        ↓ supplies the provider to request handling
Request handling → banking data provider → Akahu adapter → Akahu API
        ↓                   ↓
Shared bank calculations   accounts, freshness, transactions
        ↓
Existing local API → Swift dashboard
```

The arrows describe responsibilities, not a new public API. Preserve the
existing loopback authentication, process lifetime, cancellation, source URL
validation, and credential handling. The local API remains private and read-only.

### Where dependency injection fits

Backend startup already constructs the Akahu client and passes it into request
handling. That is dependency injection with a concrete dependency. The proposed
change would have request handling depend on a provider contract and receive an
implementation at startup. This gives the handlers a seam for a future provider
and for a fixture implementation. Rust generics, a trait object, or an enum are
possible ways to express it; choose the simplest option after checking async
lifetimes, ownership, and the existing runtime. A container, dynamic plugin
loader, and third-party extension API are not required.

The contract must expose provider-neutral records, rather than Akahu wire types.
It should preserve shared snapshot storage and borrowed transaction reads where
practical, and should define date range, pending transaction, cancellation, and
error semantics explicitly. Avoid a forwarding abstraction that merely renames
Akahu methods without removing the coupling.

## Suggested stages

1. **Characterize the current behavior.** Use the existing fictional HTTP
   fixtures to establish the current local API responses, errors, pagination,
   retries, cancellation, caching, and dashboard snapshot behavior.
2. **Extract the provider boundary with Akahu as its first implementation.**
   Move source-specific conversion behind it and supply the provider at backend
   startup. Keep the existing Akahu authentication, UI, output, and calculations
   unchanged. Add a focused fixture provider test showing shared request handling
   consumes provider-neutral data, alongside the existing Akahu integration tests.
3. **Design a real second provider.** Check its authentication, data, quotas,
   licensing, refresh, and error behavior before extending the contract. Add its
   adapter and tests for its actual responses. Avoid assuming all providers can
   supply categories, pending transactions, complete history, or freshness.
4. **Add multiple connections if needed.** Give each connection independent
   credentials and status, namespace account and transaction identities by
   connection, define duplicate-account handling, and show partial failures and
   data coverage. Adapt settings and the startup protocol to the chosen auth
   flows. Preserve existing Akahu credentials through any migration.

Stages 3 and 4 may overlap if the second provider must operate alongside Akahu.
A provider boundary alone does not add a second connection, authentication
flow, UI, or a public extension mechanism.

## Decisions to validate with a second provider

- Which records and capabilities are required, optional, or unavailable? How
  will the UI distinguish missing information from an empty result?
- Are transaction IDs stable, and how are pending and posted entries related?
  How should identity affect transfer detection and user category overrides?
- How should snapshots and caches be scoped and invalidated per connection?
  What should happen when one source times out or is cancelled?
- How should duplicate accounts be identified without silently merging them?
- Does the provider require OAuth, token refresh, user interaction, a persistent
  callback, or background work beyond today's short-lived backend process?
- Which calculations remain meaningful for incomplete history, account types,
  currencies, and source refresh intervals?

Outbound integrations such as accounting exports have different permissions and
write semantics. Design those around a concrete use case rather than forcing
them into a read-only banking provider contract.

## Acceptance for the first implementation stage

- Existing Akahu connections, dashboard results, security boundaries, and local
  API behavior remain compatible, including partial failures and cancellation.
- Shared request handling consumes provider-neutral bank data; Akahu wire records
  stay inside the adapter. A fixture provider exercises that boundary.
- Existing backend and Swift checks pass, including the fictional Akahu HTTP
  integration suite. Verify that snapshot sharing and source request counts do
  not regress, and use the existing performance harness if ownership or caching
  changes could affect memory or refresh time.
- Document the contract and how to test an adapter once its shape is proven.
