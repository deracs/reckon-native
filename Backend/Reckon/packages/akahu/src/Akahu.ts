import {
  AccountId as DomainAccountId,
  addMonths,
  BankData,
  BankDataError,
  type BankSnapshotId,
  type DateRangeOptions,
  detectRecurringCharges,
  filterTransfers,
  forecastCashflow,
  summarizeMonthlyCashflow,
  summarizeSpendingByCategory,
} from "@reckon/domain"
import { BigDecimal, Cache, Config, DateTime, Effect, Exit, Layer, Option, Schema, Stream } from "effect"
import * as FetchHttpClient from "effect/http/FetchHttpClient"
import { makeAkahuHttpClient } from "./akahu-http-client.js"
import { AkahuAccount, AkahuPendingTransaction, AkahuTransaction, PaginatedResponse } from "./wire.js"

const ZERO = BigDecimal.fromBigInt(0n)
const bankToday = DateTime.now.pipe(
  Effect.map(DateTime.setZoneNamedUnsafe("Pacific/Auckland")),
  Effect.map(DateTime.formatIsoDate),
)

/** Read-only Akahu banking; one reload shares history, and the backend scope owns all caches. */
export const AkahuBankDataLayer = Layer.effect(
  BankData,
  Effect.gen(function* () {
    const appToken = yield* Config.Redacted("AKAHU_APP_TOKEN")
    const userToken = yield* Config.Redacted("AKAHU_USER_TOKEN")
    const baseUrl = yield* Config.String("AKAHU_BASE_URL").pipe(Config.withDefault("https://api.akahu.io/v1"))
    const baseURL = yield* Effect.try({
      try: () => new URL(baseUrl),
      catch: () => new BankDataError({ operation: "Akahu.configure", reason: "transport", retryable: false }),
    })
    const client = yield* makeAkahuHttpClient({ baseURL, appToken, userToken })

    const listPaginated = <S extends Schema.Decoder<unknown>>(schema: S) => {
      const responseSchema = PaginatedResponse(schema)
      return (path: string, query: Readonly<Record<string, string | number | boolean>> = {}) =>
        Stream.paginate<string | undefined, S["Type"], BankDataError>(undefined, (cursor) =>
          client
            .getJson(path, responseSchema, { ...query, ...(cursor ? { cursor } : {}) })
            .pipe(Effect.map((response) => [response.items, Option.fromNullishOr(response.cursor?.next)] as const)),
        ).pipe(Stream.runCollect)
    }

    const accountCache = yield* Cache.makeWith(() => listPaginated(AkahuAccount)("/accounts"), {
      capacity: 1,
      timeToLive: (exit) => (Exit.isSuccess(exit) ? "5 minutes" : "0 millis"),
    })
    const listSourceAccounts = () => Cache.get(accountCache, undefined)
    const postedPages = listPaginated(AkahuTransaction)
    const pendingPages = listPaginated(AkahuPendingTransaction)

    const readTransactions = Effect.fn("Akahu.readTransactions")(function* (options: DateRangeOptions) {
      const accounts = yield* listSourceAccounts()
      const today = yield* bankToday
      const from =
        options.from === null
          ? undefined
          : (options.from ??
            (yield* DateTime.now.pipe(
              Effect.map(DateTime.subtract({ days: 30 })),
              Effect.map(DateTime.formatIsoDateUtc),
            )))
      const query = {
        ...(from ? { start: `${from}T00:00:00.000Z` } : {}),
        end: `${options.to ?? today}T23:59:59.999Z`,
        amount_as_number: true,
      }
      return yield* Effect.forEach(
        accounts,
        (account) =>
          Effect.gen(function* () {
            const path = `/accounts/${encodeURIComponent(account._id)}/transactions`
            const posted = yield* postedPages(path, query)
            const pending = yield* pendingPages(`${path}/pending`, {
              ...(from ? { start: `${from}T00:00:00.000Z` } : {}),
              amount_as_number: true,
            })
            const currency = account.balance?.currency ?? "NZD"
            return [...pending, ...posted].map((transaction) => transaction.toBankTransaction(currency))
          }),
        { concurrency: 4 },
      ).pipe(Effect.map((chunks) => chunks.flat()))
    })

    // Cover Swift's six-calendar-month window at month-end and timezone boundaries.
    const snapshots = yield* Cache.makeWith(
      (_id: BankSnapshotId) =>
        Effect.gen(function* () {
          const to = yield* bankToday
          const from = addMonths(`${to.slice(0, 7)}-01`, -6)
          const transactions = yield* readTransactions({ from, to })
          return { from, to, transactions }
        }),
      {
        capacity: 4,
        timeToLive: (exit) => (Exit.isSuccess(exit) ? "1 minute" : "0 millis"),
      },
    )

    const fetchTransactions = Effect.fn("Akahu.fetchTransactions")(function* (options: DateRangeOptions) {
      if (options.snapshotId === undefined || options.from === null) return yield* readTransactions(options)
      const snapshot = yield* Cache.get(snapshots, options.snapshotId)
      const from =
        options.from ??
        (yield* DateTime.now.pipe(Effect.map(DateTime.subtract({ days: 30 })), Effect.map(DateTime.formatIsoDateUtc)))
      const to = options.to ?? snapshot.to
      if (from < snapshot.from || to > snapshot.to) return yield* readTransactions(options)
      return snapshot.transactions.filter((transaction) => transaction.date >= from && transaction.date <= to)
    })

    return BankData.of({
      listAccounts: Effect.fn("Akahu.listAccounts")(function* () {
        return (yield* listSourceAccounts()).map((account) => account.toBankAccount())
      }),
      searchTransactions: Effect.fn("Akahu.searchTransactions")(function* (options) {
        const transactions = yield* fetchTransactions(options)
        const query = options.query?.toLowerCase()
        const limit = Math.min(Math.max(options.limit ?? 25, 1), 100)
        return filterTransfers(transactions, options.excludeTransfers)
          .filter(
            (transaction) =>
              (!options.accountId || transaction.accountId === options.accountId) &&
              (!options.category || transaction.category === options.category) &&
              (!options.from || transaction.date >= options.from) &&
              (!options.to || transaction.date <= options.to) &&
              (!query ||
                [transaction.description, transaction.merchant, transaction.category].some((value) =>
                  value?.toLowerCase().includes(query),
                )),
          )
          .sort((a, b) => b.date.localeCompare(a.date) || b.id.localeCompare(a.id))
          .slice(0, limit)
      }),
      summarizeSpending: Effect.fn("Akahu.summarizeSpending")(function* (options) {
        return summarizeSpendingByCategory(
          filterTransfers(yield* fetchTransactions(options), options.excludeTransfers !== false),
        )
      }),
      summarizeCashflow: Effect.fn("Akahu.summarizeCashflow")(function* (options) {
        return summarizeMonthlyCashflow(
          filterTransfers(yield* fetchTransactions(options), options.excludeTransfers !== false),
        )
      }),
      listRecurringCharges: Effect.fn("Akahu.listRecurringCharges")(function* (options) {
        return detectRecurringCharges(filterTransfers(yield* fetchTransactions(options), true), options)
      }),
      getDataFreshness: Effect.fn("Akahu.getDataFreshness")(function* () {
        return (yield* listSourceAccounts()).map((account) => ({
          accountId: DomainAccountId.make(account._id),
          accountName: account.name,
          balanceRefreshedAt: account.refreshed?.balance ? DateTime.formatIso(account.refreshed.balance) : undefined,
          transactionsRefreshedAt: account.refreshed?.transactions
            ? DateTime.formatIso(account.refreshed.transactions)
            : undefined,
          partyRefreshedAt: account.refreshed?.party ? DateTime.formatIso(account.refreshed.party) : undefined,
          metaRefreshedAt: account.refreshed?.meta ? DateTime.formatIso(account.refreshed.meta) : undefined,
        }))
      }),
      forecastCashflow: Effect.fn("Akahu.forecastCashflow")(function* (options) {
        const today = yield* bankToday
        const accounts = (yield* listSourceAccounts())
          .map((account) => account.toBankAccount())
          .filter(
            (account) => account.currency === "NZD" && (account.type === "checking" || account.type === "savings"),
          )
        const liquidIds = new Set(accounts.map((account) => account.id))
        const history = yield* fetchTransactions({
          from: addMonths(today, -6),
          to: today,
          snapshotId: options.snapshotId,
        })
        const cleaned = filterTransfers(history, options.excludeTransfers !== false).filter((transaction) =>
          liquidIds.has(transaction.accountId),
        )
        const incoming = cleaned
          .filter((transaction) => BigDecimal.isGreaterThan(transaction.amount, ZERO))
          .map((transaction) => ({ ...transaction, amount: BigDecimal.negate(transaction.amount) }))
        return forecastCashflow({
          startingBalance: BigDecimal.sumAll(accounts.map((account) => account.balance)),
          today,
          days: options.days ?? 30,
          recurring: detectRecurringCharges(cleaned),
          income: detectRecurringCharges(incoming, { minOccurrences: 2 }),
        })
      }),
    })
  }),
).pipe(
  Layer.provide(FetchHttpClient.layer),
  Layer.provide(Layer.succeed(FetchHttpClient.RequestInit, { redirect: "manual" })),
)
