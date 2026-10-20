// Akahu implementation of the BankSync port. Pulls accounts and
// transactions from Akahu, projects through the wire-format `toBank*`
// helpers, and hands the domain values to BankWriter. Full sync — the
// upsert provides idempotency. Incremental sync lands later.

import {
  addMonths,
  BankSync,
  BankSyncError,
  BankWriter,
  type PullWindowOptions,
} from "@reckon/domain"
import { DateTime, Effect, Layer } from "effect"
import { Akahu } from "./Akahu.js"
import { AkahuTransaction } from "./wire.js"

const SYNC_LOOKBACK_MONTHS = 3

export const BankSyncLive: Layer.Layer<BankSync, never, Akahu | BankWriter> =
  Layer.effect(
    BankSync,
    Effect.gen(function* () {
      const akahu = yield* Akahu
      const writer = yield* BankWriter

      const writeAccounts = Effect.fn("AkahuBankSync.writeAccounts")(
        function* () {
          const akahuAccounts = yield* akahu.listAccounts()
          const accounts = akahuAccounts.map((account) =>
            account.toBankAccount(),
          )
          yield* writer.upsertAccounts(accounts).pipe(
            Effect.mapError(
              (cause) =>
                new BankSyncError({
                  reason: `BankWriter.upsertAccounts failed: ${cause.reason}`,
                  cause,
                }),
            ),
          )
          return akahuAccounts
        },
      )

      const pull = Effect.fn("AkahuBankSync.pull")(function* () {
        const akahuAccounts = yield* writeAccounts()
        const currencyByAccount = new Map(
          akahuAccounts.map((account) => [
            account._id,
            account.balance?.currency ?? "NZD",
          ]),
        )
        const today = yield* DateTime.now.pipe(
          Effect.map(DateTime.formatIsoDateUtc),
        )
        const from = addMonths(today, -SYNC_LOOKBACK_MONTHS)
        const akahuTxns = yield* akahu.searchTransactions({
          from,
          includePending: false,
        })
        const txns = akahuTxns
          .filter((tx): tx is AkahuTransaction => tx instanceof AkahuTransaction)
          .map((tx) =>
            tx.toBankTransaction(currencyByAccount.get(tx._account) ?? "NZD"),
          )
        yield* writer.upsertTransactions(txns).pipe(
          Effect.mapError(
            (cause) =>
              new BankSyncError({
                reason: `BankWriter.upsertTransactions failed: ${cause.reason}`,
                cause,
              }),
          ),
        )
      })

      // Per-account, per-window read used by the backfill orchestrator.
      // The caller is responsible for stepping through windows; we just
      // do one Akahu fetch and one writer upsert. Idempotent on overlap.
      // Account upsert is deliberately skipped — backfill assumes the
      // account row already exists (a one-shot `pull` happens on app
      // boot through the hybrid layer's preflight).
      const pullWindow = Effect.fn("AkahuBankSync.pullWindow")(function* (
        options: PullWindowOptions,
      ) {
        const akahuAccounts = yield* akahu.listAccounts()
        const account = akahuAccounts.find((a) => a._id === options.accountId)
        const currency = account?.balance?.currency ?? "NZD"

        const akahuTxns = yield* akahu.searchTransactions({
          accountId: options.accountId,
          from: options.from,
          to: options.to,
          includePending: false,
        })
        const txns = akahuTxns
          .filter((tx): tx is AkahuTransaction => tx instanceof AkahuTransaction)
          .map((tx) => tx.toBankTransaction(currency))
        yield* writer.upsertTransactions(txns).pipe(
          Effect.mapError(
            (cause) =>
              new BankSyncError({
                reason: `BankWriter.upsertTransactions failed: ${cause.reason}`,
                cause,
              }),
          ),
        )
        return { count: txns.length }
      })

      return { pull, pullWindow }
    }),
  )
