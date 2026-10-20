// Akahu HTTP client (`Akahu` service) + the BankData implementation
// that adapts Akahu's responses through the pure helpers from
// @reckon/domain. Wire-format schemas live in ./wire.ts.

import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve as resolvePath } from "node:path";
import { NodeHttpClient } from "@effect/platform-node";
import nzfccBundle from "./nzfcc-categories.json" with { type: "json" };
import {
  AccountId as DomainAccountId,
  addMonths,
  BankData,
  type BankDataService,
  BudgetConfig,
  type BudgetStatusOptions,
  type CashflowOptions,
  computeBudgetStatus,
  computeRoundUps,
  detectRecurringCharges,
  filterTransfers,
  findUnusualTransactions,
  forecastCashflow,
  type ForecastCashflowOptions,
  type RecurringChargeOptions,
  type RoundUpOptions,
  type SearchTransactionsOptions,
  summarizeMonthlyCashflow,
  summarizeSpendingByCategory,
  type SummarizeSpendingOptions,
  summarizeTopMerchants,
  type TopMerchantsOptions,
  Transaction,
  type UnusualTransactionOptions,
} from "@reckon/domain";
import {
  BigDecimal,
  Context,
  DateTime,
  Effect,
  Layer,
  Option,
  Redacted,
  Schedule,
  Schema,
  Stream,
} from "effect";
import * as Config from "effect/Config";
import { flow, identity } from "effect/Function";
import * as HttpClient from "effect/unstable/http/HttpClient";
import * as HttpClientRequest from "effect/unstable/http/HttpClientRequest";
import * as HttpClientResponse from "effect/unstable/http/HttpClientResponse";
import {
  AccountId,
  AkahuAccount,
  AkahuCategoryDoc,
  AkahuPendingTransaction,
  AkahuTransaction,
  PaginatedResponse,
  toBankAccountType,
} from "./wire.js";

const ZERO = BigDecimal.fromNumberUnsafe(0);

interface AkahuService {
  readonly listAccounts: () => Effect.Effect<ReadonlyArray<AkahuAccount>>;
  readonly listCategories: () => Effect.Effect<ReadonlyArray<AkahuCategoryDoc>>;
  readonly searchTransactions: (
    options: AkahuSearchTransactionsOptions,
  ) => Effect.Effect<ReadonlyArray<AkahuTransaction | AkahuPendingTransaction>>;
  readonly refresh: () => Effect.Effect<void>;
}

interface AkahuSearchTransactionsOptions {
  readonly accountId?: string | undefined;
  readonly from?: string | null | undefined;
  readonly to?: string | undefined;
  readonly includePending?: boolean | undefined;
}

export class Akahu extends Context.Service<Akahu, AkahuService>()(
  "personal-bank-mcp/Akahu",
) {
  // HttpClient-agnostic layer. The platform client comes from the
  // composition seam: Node apps use `Akahu.layer` (undici baked in),
  // the Cloudflare worker provides FetchHttpClient.layer itself.
  static readonly layerHttp = Layer.effect(
    Akahu,
    Effect.gen(function* () {
      const appToken = yield* Config.Redacted("AKAHU_APP_TOKEN");
      const userToken = yield* Config.Redacted("AKAHU_USER_TOKEN");
      const baseUrl = yield* Config.String("AKAHU_BASE_URL").pipe(
        Config.withDefault("https://api.akahu.io/v1"),
      );

      const client = (yield* HttpClient.HttpClient).pipe(
        HttpClient.mapRequest(
          flow(
            HttpClientRequest.prependUrl(baseUrl),
            HttpClientRequest.setHeader("X-Akahu-Id", Redacted.value(appToken)),
            HttpClientRequest.bearerToken(Redacted.value(userToken)),
            HttpClientRequest.acceptJson,
          ),
        ),
        HttpClient.filterStatusOk,
        HttpClient.retryTransient({
          schedule: Schedule.exponential(500),
          times: 5,
        }),
        HttpClient.transformResponse(Effect.orDie),
      );

      const listPaginated = <S extends Schema.Top>(schema: S) => {
        const Response = PaginatedResponse(schema);
        return (request: HttpClientRequest.HttpClientRequest) =>
          Effect.gen(function* () {
            const items: Array<S["Type"]> = [];
            let cursor: string | undefined;

            do {
              const response = yield* request.pipe(
                cursor
                  ? HttpClientRequest.setUrlParam("cursor", cursor)
                  : identity,
                client.execute,
                Effect.flatMap(HttpClientResponse.schemaBodyJson(Response)),
                Effect.orDie,
              );
              items.push(...response.items);
              cursor = response.cursor?.next ?? undefined;
            } while (cursor);

            return items;
          });
      };

      // Cached lookups — accounts and categories rarely change within a
      // single request, but BankData fans them out across every operation
      // (search/forecast/freshness all need accounts).
      // Invalidated explicitly on refresh().
      const [cachedAccounts, invalidateAccounts] =
        yield* Effect.cachedInvalidateWithTTL(
          listPaginated(AkahuAccount)(HttpClientRequest.get("/accounts")),
          "5 minutes",
        );
      // Akahu's /v1/categories needs App-Secret Basic auth that
      // personal apps don't get, so we use the NZFCC public taxonomy
      // (same shape as Akahu's category docs) bundled at build time.
      const NzfccCategoriesFile = Schema.Struct({
        categories: Schema.Array(AkahuCategoryDoc),
      });
      const cachedCategories = yield* Effect.cachedWithTTL(
        Schema.decodeUnknownEffect(NzfccCategoriesFile)(nzfccBundle).pipe(
          Effect.map((r) => r.categories as ReadonlyArray<AkahuCategoryDoc>),
          Effect.orDie,
        ),
        "24 hours",
      );

      const listAccounts = Effect.fn("Akahu.listAccounts")(
        () => cachedAccounts,
      );
      const listCategories = Effect.fn("Akahu.listCategories")(
        () => cachedCategories,
      );

      const accountTransactions = listPaginated(AkahuTransaction);
      const pendingAccountTransactions = listPaginated(AkahuPendingTransaction);

      return {
        listAccounts,
        listCategories,

        searchTransactions: Effect.fn("Akahu.searchTransactions")(function* (
          options: AkahuSearchTransactionsOptions,
        ) {
          const accounts = options.accountId
            ? [AccountId.make(options.accountId)]
            : (yield* listAccounts()).map((account) => account._id);
          const from = yield* fromDateOrDefault(options.from);
          const urlParams = {
            ...(from ? { start: from } : {}),
            ...(options.to ? { end: toAkahuDateTime(options.to, "end") } : {}),
            amount_as_number: true,
          };

          const settled = yield* Effect.forEach(
            accounts,
            (accountId) =>
              accountTransactions(
                HttpClientRequest.get(`/accounts/${accountId}/transactions`, {
                  urlParams,
                }),
              ),
            { concurrency: 4 },
          ).pipe(Effect.map((chunks) => chunks.flat()));

          if (options.includePending === false) {
            return settled;
          }

          const pending = yield* Effect.forEach(
            accounts,
            (accountId) =>
              pendingAccountTransactions(
                HttpClientRequest.get(
                  `/accounts/${accountId}/transactions/pending`,
                  {
                    urlParams: {
                      ...(from ? { start: from } : {}),
                      amount_as_number: true,
                    },
                  },
                ),
              ),
            { concurrency: 4 },
          ).pipe(Effect.map((chunks) => chunks.flat()));

          return [...pending, ...settled];
        }),

        refresh: Effect.fn("Akahu.refresh")(() =>
          client.post("/refresh").pipe(
            Effect.asVoid,
            Effect.tap(() => invalidateAccounts),
          ),
        ),
      } as const;
    }),
  );

  static readonly layer = Akahu.layerHttp.pipe(
    Layer.provide(NodeHttpClient.layerUndici),
  );
}

// BankData implementation that needs an `Akahu` layer provided
// alongside it. Production wiring uses `AkahuBankDataLayer` (this +
// the real Akahu HTTP layer). Tests can provide their own stub Akahu
// against this inner layer.
export const AkahuBankDataLive = Layer.effect(
  BankData,
  Effect.gen(function* () {
    const akahu = yield* Akahu;
    const budgetConfigs = yield* loadBudgetConfigs;

    const fetchTransactions = (options: {
      accountId?: string | undefined;
      from?: string | null | undefined;
      to?: string | undefined;
    }) =>
      Effect.gen(function* () {
        const accounts = yield* akahu.listAccounts();
        const currencyByAccount = new Map(
          accounts.map((account) => [
            account._id,
            account.balance?.currency ?? "NZD",
          ]),
        );
        const transactions = yield* akahu.searchTransactions({
          accountId: options.accountId,
          from: options.from,
          to: options.to,
        });
        return transactions.map((transaction) =>
          transaction.toBankTransaction(
            currencyByAccount.get(getTransactionAccountId(transaction)) ??
              "NZD",
          ),
        );
      });

    const listAccounts = Effect.fn("AkahuBankData.listAccounts")(function* () {
      const accounts = yield* akahu.listAccounts();
      return accounts.map((account) => account.toBankAccount());
    });

    const searchTransactions = Effect.fn("AkahuBankData.searchTransactions")(
      function* (options: SearchTransactionsOptions) {
        const fetchAccountId = options.excludeTransfers
          ? undefined
          : options.accountId;
        const transactions = yield* fetchTransactions({
          accountId: fetchAccountId,
          from: options.from,
          to: options.to,
        });
        const withoutTransfers = filterTransfers(
          transactions,
          options.excludeTransfers,
        );
        const query = options.query?.toLowerCase();
        const limit = options.limit === null ? undefined : Math.min(Math.max(options.limit ?? 25, 1), 100);
        return withoutTransfers
          .filter((tx) => {
            if (options.accountId && tx.accountId !== options.accountId)
              return false;
            if (options.category && tx.category !== options.category)
              return false;
            if (options.from && tx.date < options.from) return false;
            if (options.to && tx.date > options.to) return false;
            if (!query) return true;
            return [tx.description, tx.merchant, tx.category].some((value) =>
              value?.toLowerCase().includes(query),
            );
          })
          .sort((a, b) => b.date.localeCompare(a.date) || b.id.localeCompare(a.id))
          .slice(0, limit);
      },
    );

    const summarizeSpending = Effect.fn("AkahuBankData.summarizeSpending")(
      function* (options: SummarizeSpendingOptions) {
        const transactions = yield* fetchTransactions({
          from: options.from,
          to: options.to,
        });
        const exclude = options.excludeTransfers !== false;
        return summarizeSpendingByCategory(
          filterTransfers(transactions, exclude),
        );
      },
    );

    const summarizeCashflow = Effect.fn("AkahuBankData.summarizeCashflow")(
      function* (options: CashflowOptions) {
        const transactions = yield* fetchTransactions({
          from: options.from,
          to: options.to,
        });
        const exclude = options.excludeTransfers !== false;
        return summarizeMonthlyCashflow(filterTransfers(transactions, exclude));
      },
    );

    const summarizeRoundUps = Effect.fn("AkahuBankData.summarizeRoundUps")(
      function* (options: RoundUpOptions) {
        const transactions = yield* fetchTransactions({
          from: options.from,
          to: options.to,
        });
        const exclude = options.excludeTransfers !== false;
        return computeRoundUps(filterTransfers(transactions, exclude), {
          unit: options.unit,
          merchantLimit: options.merchantLimit,
        });
      },
    );

    const listRecurringCharges = Effect.fn(
      "AkahuBankData.listRecurringCharges",
    )(function* (options: RecurringChargeOptions) {
      const transactions = yield* fetchTransactions({
        from: options.from,
        to: options.to,
      });
      return detectRecurringCharges(filterTransfers(transactions, true), {
        minOccurrences: options.minOccurrences,
      });
    });

    const unusualTransactions = Effect.fn(
      "AkahuBankData.findUnusualTransactions",
    )(function* (options: UnusualTransactionOptions) {
      const transactions = yield* fetchTransactions({
        from: options.from,
        to: options.to,
      });
      return findUnusualTransactions(filterTransfers(transactions, true), {
        threshold: options.threshold,
        minBaseline: options.minBaseline,
      });
    });

    const topMerchants = Effect.fn("AkahuBankData.topMerchants")(function* (
      options: TopMerchantsOptions,
    ) {
      const transactions = yield* fetchTransactions({
        from: options.from,
        to: options.to,
      });
      const exclude = options.excludeTransfers !== false;
      return summarizeTopMerchants(filterTransfers(transactions, exclude), {
        limit: options.limit,
        direction: options.direction,
      });
    });

    const listCategories = Effect.fn("AkahuBankData.listCategories")(
      function* () {
        const categories = yield* akahu.listCategories();
        return categories.map((category) => category.toBankCategory());
      },
    );

    const budgetStatus = Effect.fn("AkahuBankData.budgetStatus")(function* (
      options: BudgetStatusOptions,
    ) {
      const today = yield* DateTime.now.pipe(
        Effect.map(DateTime.formatIsoDateUtc),
      );
      const month = options.month ?? today.slice(0, 7);
      const filtered = options.categories?.length
        ? budgetConfigs.filter((c) => options.categories!.includes(c.category))
        : budgetConfigs;
      if (filtered.length === 0) return [];
      const transactions = yield* fetchTransactions({
        from: `${month}-01`,
        to: month <= today.slice(0, 7) ? today : `${month}-31`,
      });
      return computeBudgetStatus(
        filterTransfers(transactions, true),
        filtered,
        today,
        month,
      );
    });

    const forecastCashflowImpl = Effect.fn("AkahuBankData.forecastCashflow")(
      function* (options: ForecastCashflowOptions) {
        const today = yield* DateTime.now.pipe(
          Effect.map(DateTime.setZoneNamedUnsafe("Pacific/Auckland")),
          Effect.map(DateTime.formatIsoDate),
        );
        const days = options.days ?? 30;
        const accounts = yield* akahu.listAccounts();
        const startingBalance = accounts.reduce((acc, a) => {
          if (a.balance?.currency !== "NZD") return acc;
          const liquid =
            toBankAccountType(a.type) === "checking" ||
            toBankAccountType(a.type) === "savings";
          return liquid
            ? BigDecimal.sum(
                acc,
                BigDecimal.fromNumberUnsafe(a.balance.current ?? 0),
              )
            : acc;
        }, ZERO);
        const lookbackFrom = addMonths(today, -6);
        const transactions = yield* fetchTransactions({
          from: lookbackFrom,
          to: today,
        });
        const exclude = options.excludeTransfers !== false;
        const liquidAccountIds = new Set(accounts.filter((a) =>
          a.balance?.currency === "NZD" &&
          (toBankAccountType(a.type) === "checking" || toBankAccountType(a.type) === "savings"),
        ).map((a) => DomainAccountId.make(a._id)));
        const cleaned = filterTransfers(transactions, exclude).filter((tx) => liquidAccountIds.has(tx.accountId));
        const recurring = detectRecurringCharges(cleaned);
        const incoming = cleaned.filter((tx) =>
          BigDecimal.isGreaterThan(tx.amount, ZERO),
        );
        const incomeRecurring = detectRecurringChargesFromIncome(incoming);
        return forecastCashflow({
          startingBalance,
          today,
          days,
          recurring,
          income: incomeRecurring,
        });
      },
    );

    const getDataFreshness = Effect.fn("AkahuBankData.getDataFreshness")(
      function* () {
        const accounts = yield* akahu.listAccounts();
        return accounts.map((account) => ({
          accountId: DomainAccountId.make(account._id),
          accountName: account.name,
          balanceRefreshedAt: account.refreshed?.balance
            ? DateTime.formatIso(account.refreshed.balance)
            : undefined,
          transactionsRefreshedAt: account.refreshed?.transactions
            ? DateTime.formatIso(account.refreshed.transactions)
            : undefined,
          partyRefreshedAt: account.refreshed?.party
            ? DateTime.formatIso(account.refreshed.party)
            : undefined,
          metaRefreshedAt: account.refreshed?.meta
            ? DateTime.formatIso(account.refreshed.meta)
            : undefined,
        }));
      },
    );

    // Without a Postgres mirror there's nowhere to put older history,
    // so backfill emits an empty stream on the Akahu-only path. The
    // hybrid composition wires the Postgres implementation instead.
    const backfill = (_: unknown) => Stream.empty;

    return {
      listAccounts,
      searchTransactions,
      summarizeSpending,
      summarizeCashflow,
      summarizeRoundUps,
      listRecurringCharges,
      findUnusualTransactions: unusualTransactions,
      topMerchants,
      // Transfer detection is a derivation that needs a full window of
      // transactions across accounts. The Akahu-only path doesn't keep
      // that lying around, so it returns []; the Postgres mirror serves
      // the real implementation via HybridBankData.
      listTransferPairs: () => Effect.succeed([]),
      // Category rules are user-defined and persisted in Postgres;
      // Akahu has no concept of them. HybridBankData routes the real
      // impl through the Postgres adapter.
      listCategoryRules: () => Effect.succeed([]),
      upsertCategoryRule: () =>
        Effect.die("AkahuBankData: upsertCategoryRule requires Postgres"),
      deleteCategoryRule: () =>
        Effect.die("AkahuBankData: deleteCategoryRule requires Postgres"),
      // Budgets are likewise Postgres-only; the Akahu-only path serves
      // the existing JSON-file-backed budgets via budgetStatus only.
      listBudgets: () => Effect.succeed([]),
      upsertBudget: () =>
        Effect.die("AkahuBankData: upsertBudget requires Postgres"),
      deleteBudget: () =>
        Effect.die("AkahuBankData: deleteBudget requires Postgres"),
      // Savings goals are likewise Postgres-only; progress is derived
      // from the transaction mirror so goals have no meaning without it.
      listGoals: () => Effect.succeed([]),
      upsertGoal: () =>
        Effect.die("AkahuBankData: upsertGoal requires Postgres"),
      deleteGoal: () =>
        Effect.die("AkahuBankData: deleteGoal requires Postgres"),
      goalStatus: () => Effect.succeed([]),
      // Challenges are Postgres-only; scored from the transaction mirror.
      listChallenges: () => Effect.succeed([]),
      upsertChallenge: () =>
        Effect.die("AkahuBankData: upsertChallenge requires Postgres"),
      deleteChallenge: () =>
        Effect.die("AkahuBankData: deleteChallenge requires Postgres"),
      challengeStatus: () => Effect.succeed([]),
      foundMoney: () =>
        Effect.succeed({ buckets: [], reclaimable: BigDecimal.fromNumberUnsafe(0) }),
      // Flags persist human actions (snooze/act/dismiss) in a Postgres
      // sidecar, so the Akahu-only path stays empty / unsupported.
      flagInbox: () => Effect.succeed({ pinned: undefined, queue: [] }),
      snoozeFlag: () =>
        Effect.die("AkahuBankData: snoozeFlag requires Postgres"),
      actFlag: () => Effect.die("AkahuBankData: actFlag requires Postgres"),
      dismissFlag: () =>
        Effect.die("AkahuBankData: dismissFlag requires Postgres"),
      clearFlag: () =>
        Effect.die("AkahuBankData: clearFlag requires Postgres"),
      listFlagStates: () => Effect.succeed([]),
      fortnight: () => Effect.succeed(null),
      ledger: () =>
        DateTime.now.pipe(
          Effect.map((now) => ({
            totalVerified: BigDecimal.fromNumberUnsafe(0),
            asOf: DateTime.formatIsoDateUtc(now),
            entries: [],
          })),
        ),
      // Per-transaction overrides are user state, Postgres-only.
      listTransactionOverrides: () => Effect.succeed([]),
      setTransactionCategoryOverride: () =>
        Effect.die(
          "AkahuBankData: setTransactionCategoryOverride requires Postgres",
        ),
      clearTransactionCategoryOverride: () =>
        Effect.die(
          "AkahuBankData: clearTransactionCategoryOverride requires Postgres",
        ),
      // Scheduled transactions are user-defined and persisted in
      // Postgres; the Akahu-only path stays empty.
      listScheduledTransactions: () => Effect.succeed([]),
      upsertScheduledTransaction: () =>
        Effect.die("AkahuBankData: upsertScheduledTransaction requires Postgres"),
      deleteScheduledTransaction: () =>
        Effect.die("AkahuBankData: deleteScheduledTransaction requires Postgres"),
      // Manual asset/liability accounts are user-defined and persisted
      // in Postgres; the Akahu-only path stays empty.
      listManualAccounts: () => Effect.succeed([]),
      upsertManualAccount: () =>
        Effect.die("AkahuBankData: upsertManualAccount requires Postgres"),
      deleteManualAccount: () =>
        Effect.die("AkahuBankData: deleteManualAccount requires Postgres"),
      listCategories,
      getDataFreshness,
      refresh: akahu.refresh,
      budgetStatus,
      forecastCashflow: forecastCashflowImpl,
      backfill,
    } satisfies BankDataService;
  }),
);

export const AkahuBankDataLayer = AkahuBankDataLive.pipe(
  Layer.provide(Akahu.layer),
);

const detectRecurringChargesFromIncome = (
  incoming: ReadonlyArray<Transaction>,
) => {
  const flipped = incoming.map((tx) => ({
    ...tx,
    amount: BigDecimal.negate(tx.amount),
  }));
  return detectRecurringCharges(flipped, { minOccurrences: 2 });
};

class BudgetConfigReadError extends Schema.TaggedError<BudgetConfigReadError>()(
  "BudgetConfigReadError",
  { cause: Schema.Defect() },
) {}

const BudgetConfigFileFromJson = Schema.fromJsonString(
  Schema.Struct({ budgets: Schema.Array(BudgetConfig) }),
);

const loadBudgetConfigs: Effect.Effect<ReadonlyArray<BudgetConfig>> =
  Effect.gen(function* () {
    const configured = yield* Config.option(
      Config.String("PERSONAL_BANK_BUDGETS_PATH"),
    );
    // Path resolution stays inside the try: on runtimes without a home
    // directory or filesystem (workerd), any node API failure falls into
    // the same "no budgets configured" branch as a missing file.
    const raw = yield* Effect.try({
      try: () => {
        const path = Option.isSome(configured)
          ? configured.value
          : resolvePath(homedir(), ".personal-bank-budgets.json");
        return readFileSync(path, "utf8");
      },
      catch: (cause) => new BudgetConfigReadError({ cause }),
    });
    const file = yield* Schema.decodeUnknownEffect(BudgetConfigFileFromJson)(
      raw,
    );
    return file.budgets;
    // Optional file — missing, malformed JSON, or schema-mismatched all
    // fall back to "no budgets configured".
  }).pipe(Effect.catch(() => Effect.succeed<ReadonlyArray<BudgetConfig>>([])));

const getTransactionAccountId = (
  transaction: AkahuTransaction | AkahuPendingTransaction,
): AccountId =>
  transaction instanceof AkahuTransaction
    ? transaction._account
    : transaction.accountId;

const fromDateOrDefault = (from: string | null | undefined): Effect.Effect<string | undefined> =>
  from === null ? Effect.succeed(undefined) : from
    ? Effect.succeed(toAkahuDateTime(from, "start"))
    : DateTime.now.pipe(
        Effect.map((now) =>
          DateTime.formatIso(now.pipe(DateTime.subtract({ days: 30 }))),
        ),
      );

const toAkahuDateTime = (date: string, boundary: "start" | "end"): string =>
  date.includes("T")
    ? date
    : boundary === "start"
      ? `${date}T00:00:00.000Z`
      : `${date}T23:59:59.999Z`;
