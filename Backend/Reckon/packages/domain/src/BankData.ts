import { Context, Effect, Schema } from "effect"

/** Bank account identity shared by source records and calculations. */
export const AccountId = Schema.String.pipe(Schema.brand("AccountId"))
/** Decoded AccountId values retain the schema’s domain representation. */
export type AccountId = typeof AccountId.Type

/** Posted or pending transaction identity used by activity and transfer detection. */
export const TransactionId = Schema.String.pipe(Schema.brand("TransactionId"))
/** Decoded TransactionId values retain the schema’s domain representation. */
export type TransactionId = typeof TransactionId.Type

/** Account balances retain their own currency; currencies are never converted. */
export const Account = Schema.Struct({
  id: AccountId.annotate({
    description: "Unique identifier for the account.",
  }),
  name: Schema.String.annotate({
    description: "Human-readable name for the account.",
  }),
  type: Schema.Literals(["checking", "savings", "credit", "loan", "investment"]).annotate({
    description: "Type of account (e.g. 'checking', 'savings', 'credit', 'loan', 'investment').",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
  balance: Schema.BigDecimalFromString.annotate({
    description: "Current balance of the account.",
  }),
  availableBalance: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "Available balance of the account.",
    }),
  ),
  creditLimit: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "Credit limit of the account.",
    }),
  ),
  accountNumber: Schema.optional(
    Schema.String.annotate({
      description: "Account number of the account.",
    }),
  ),
  status: Schema.optional(
    Schema.Literals(["active", "inactive"]).annotate({
      description: "Status of the account (e.g. 'active', 'inactive').",
    }),
  ),
  bankName: Schema.optional(
    Schema.String.annotate({
      description: "Name of the bank the account is with.",
    }),
  ),
  bankLogo: Schema.optional(
    Schema.String.annotate({
      description: "Logo of the bank the account is with.",
    }),
  ),
})

/** Decoded Account values retain the schema’s domain representation. */
export type Account = typeof Account.Type

/** Transaction amounts are signed decimals, with source merchant and category metadata. */
export const Transaction = Schema.Struct({
  id: TransactionId.annotate({
    description: "Unique identifier for the transaction.",
  }),
  accountId: AccountId.annotate({
    description: "Unique identifier for the account the transaction belongs to.",
  }),
  date: Schema.String.annotate({
    description: "Date of the transaction (YYYY-MM-DD).",
  }),
  description: Schema.String.annotate({
    description: "Description of the transaction.",
  }),
  merchant: Schema.optional(
    Schema.String.annotate({
      description: "Normalised counterparty name (e.g. 'PAK'nSAVE').",
    }),
  ),
  merchantLogo: Schema.optional(Schema.String).annotate({
    description: "Source-supplied merchant logo URL, when available.",
  }),
  category: Schema.optional(Schema.String).annotate({
    description: "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Amount of the transaction.",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
})

/** Decoded Transaction values retain the schema’s domain representation. */
export type Transaction = typeof Transaction.Type

/** Category spending contains outflows only, with finite transaction counts. */
export const SpendingByCategory = Schema.Struct({
  category: Schema.String.annotate({
    description: "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  spent: Schema.BigDecimalFromString.annotate({
    description: "Total spent in the category over the trailing 3 months.",
  }),
  transactionCount: Schema.Finite.annotate({
    description: "Number of transactions in the category over the trailing 3 months.",
  }),
})

/** Decoded SpendingByCategory values retain the schema’s domain representation. */
export type SpendingByCategory = typeof SpendingByCategory.Type

/** Monthly cashflow preserves decimal money and finite transaction counts. */
export const MonthlyCashflow = Schema.Struct({
  month: Schema.String.annotate({
    description: "Month of the cashflow (YYYY-MM).",
  }),
  income: Schema.BigDecimalFromString.annotate({
    description: "Income for the month.",
  }),
  spending: Schema.BigDecimalFromString.annotate({
    description: "Spending for the month.",
  }),
  net: Schema.BigDecimalFromString.annotate({
    description: "Net for the month.",
  }),
  transactionCount: Schema.Finite.annotate({
    description: "Number of transactions for the month.",
  }),
})

/** Decoded MonthlyCashflow values retain the schema’s domain representation. */
export type MonthlyCashflow = typeof MonthlyCashflow.Type

/** Detected recurring charges describe historical evidence rather than confirmed future bills. */
export const RecurringCharge = Schema.Struct({
  merchant: Schema.String.annotate({
    description: "Normalised counterparty name (e.g. 'PAK'nSAVE').",
  }),
  category: Schema.optional(
    Schema.String.annotate({
      description: "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
    }),
  ),
  cadence: Schema.Literals(["weekly", "fortnightly", "monthly", "quarterly"]).annotate({
    description: "Cadence of the recurring charge (weekly, fortnightly, monthly, quarterly).",
  }),
  occurrences: Schema.Finite.annotate({
    description: "Number of occurrences of the recurring charge.",
  }),
  averageAmount: Schema.BigDecimalFromString.annotate({
    description: "Average amount of the recurring charge.",
  }),
  minAmount: Schema.BigDecimalFromString.annotate({
    description: "Minimum amount of the recurring charge.",
  }),
  maxAmount: Schema.BigDecimalFromString.annotate({
    description: "Maximum amount of the recurring charge.",
  }),
  totalSpent: Schema.BigDecimalFromString.annotate({
    description: "Total spent for the recurring charge.",
  }),
  firstDate: Schema.String.annotate({
    description: "First date of the recurring charge.",
  }),
  lastDate: Schema.String.annotate({
    description: "Last date of the recurring charge.",
  }),
  lastAmount: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "Amount of the most recent charge in the cluster — feeds hike detection.",
    }),
  ),
})

/** Decoded RecurringCharge values retain the schema’s domain representation. */
export type RecurringCharge = typeof RecurringCharge.Type

/** A projected recurring charge or income event with a signed decimal amount. */
export const ForecastEvent = Schema.Struct({
  date: Schema.String.annotate({
    description: "Projected date of the event (YYYY-MM-DD).",
  }),
  description: Schema.String.annotate({
    description: "Human-readable label (usually the merchant name).",
  }),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Signed amount — negative for outflows, positive for income.",
  }),
  kind: Schema.Literals(["recurring_charge", "expected_income"]),
})

/** Decoded ForecastEvent values retain the schema’s domain representation. */
export type ForecastEvent = typeof ForecastEvent.Type

/** A projected negative balance on a forecast date. */
export const ForecastRisk = Schema.Struct({
  date: Schema.String.annotate({
    description: "Date the projected balance crosses into risk (YYYY-MM-DD).",
  }),
  projectedBalance: Schema.BigDecimalFromString.annotate({
    description: "Projected balance on the risk date (negative = overdrawn).",
  }),
  reason: Schema.String.annotate({
    description: "One-line explanation of why this date is flagged.",
  }),
})

/** Decoded ForecastRisk values retain the schema’s domain representation. */
export type ForecastRisk = typeof ForecastRisk.Type

/** A projected end-of-day balance in the forecast currency. */
export const ForecastPoint = Schema.Struct({
  date: Schema.String.annotate({
    description: "Date of the projected balance point (YYYY-MM-DD).",
  }),
  projectedBalance: Schema.BigDecimalFromString.annotate({
    description: "Projected liquid balance on that date.",
  }),
})

/** Decoded ForecastPoint values retain the schema’s domain representation. */
export type ForecastPoint = typeof ForecastPoint.Type

/** The balance forecast excludes discretionary spending and uses detected recurring activity. */
export const Forecast = Schema.Struct({
  startDate: Schema.String.annotate({
    description: "First day of the forecast window (YYYY-MM-DD).",
  }),
  endDate: Schema.String.annotate({
    description: "Last day of the forecast window (YYYY-MM-DD).",
  }),
  startingBalance: Schema.BigDecimalFromString.annotate({
    description: "Liquid balance at the start of the forecast window.",
  }),
  endingBalance: Schema.BigDecimalFromString.annotate({
    description: "Projected liquid balance at the end of the forecast window.",
  }),
  netChange: Schema.BigDecimalFromString.annotate({
    description: "Projected net change over the window (ending − starting).",
  }),
  totalIncome: Schema.BigDecimalFromString.annotate({
    description: "Projected total income across the window.",
  }),
  totalSpending: Schema.BigDecimalFromString.annotate({
    description: "Projected total spending across the window.",
  }),
  points: Schema.Array(ForecastPoint).annotate({
    description: "Per-day projected balance points, oldest first.",
  }),
  events: Schema.Array(ForecastEvent).annotate({
    description: "Projected events (recurring charges + expected income) that drive the curve.",
  }),
  risks: Schema.Array(ForecastRisk).annotate({
    description: "Dates where the projected balance crosses zero or otherwise warrants attention.",
  }),
})

/** Decoded Forecast values retain the schema’s domain representation. */
export type Forecast = typeof Forecast.Type

/** Source refresh timestamps are independent of the latest dashboard fetch. */
export const AccountFreshness = Schema.Struct({
  accountId: AccountId.annotate({
    description: "Unique identifier for the account.",
  }),
  accountName: Schema.String.annotate({
    description: "Human-readable name for the account.",
  }),
  balanceRefreshedAt: Schema.optional(
    Schema.String.annotate({
      description: "ISO timestamp of the last balance refresh.",
    }),
  ),
  transactionsRefreshedAt: Schema.optional(
    Schema.String.annotate({
      description: "ISO timestamp of the last transactions refresh.",
    }),
  ),
  partyRefreshedAt: Schema.optional(
    Schema.String.annotate({
      description: "ISO timestamp of the last party (account-holder) refresh.",
    }),
  ),
  metaRefreshedAt: Schema.optional(
    Schema.String.annotate({
      description: "ISO timestamp of the last account-meta refresh.",
    }),
  ),
})

/** Decoded AccountFreshness values retain the schema’s domain representation. */
export type AccountFreshness = typeof AccountFreshness.Type

/** A real calendar date without time or timezone, in YYYY-MM-DD format. */
export const BankDate = Schema.String.check(
  Schema.isPattern(/^(?!0000)\d{4}-\d{2}-\d{2}$/),
  Schema.makeFilter(
    (value) => {
      const date = new Date(`${value}T00:00:00.000Z`)
      return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value
    },
    { description: "Must be a real calendar date in YYYY-MM-DD format." },
  ),
)

/** One dashboard reload ID shares history without reusing data on the next reload. */
export const BankSnapshotId = Schema.String.check(Schema.isUUID()).pipe(Schema.brand("BankSnapshotId"))
/** A validated dashboard reload identity. */
export type BankSnapshotId = typeof BankSnapshotId.Type

/** Inclusive source date range; omitted start uses the latest thirty days. */
export const DateRange = {
  from: Schema.optionalKey(Schema.NullOr(BankDate)),
  to: Schema.optionalKey(BankDate),
}

/** History reads may share a snapshot while retaining their individual date filters. */
export interface DateRangeOptions {
  readonly from?: string | null | undefined
  readonly to?: string | undefined
  readonly snapshotId?: BankSnapshotId | undefined
}

/** Activity search applies transfer exclusion before account filtering and limiting. */
export interface SearchTransactionsOptions extends DateRangeOptions {
  readonly query?: string | undefined
  readonly accountId?: string | undefined
  readonly category?: string | undefined
  readonly limit?: number | undefined
  readonly excludeTransfers?: boolean | undefined
}

/** Spending is grouped by source category, excluding transfers by default. */
export interface SummarizeSpendingOptions extends DateRangeOptions {
  readonly excludeTransfers?: boolean | undefined
}

/** Monthly cashflow excludes transfers by default. */
export interface CashflowOptions extends DateRangeOptions {
  readonly excludeTransfers?: boolean | undefined
}

/** Recurring detection uses at least two historical occurrences. */
export interface RecurringChargeOptions extends DateRangeOptions {
  readonly minOccurrences?: number | undefined
}

/** Forecasts use six months of NZD liquid-account history and at most 365 days. */
export interface ForecastCashflowOptions {
  readonly days?: number | undefined
  readonly excludeTransfers?: boolean | undefined
  readonly snapshotId?: BankSnapshotId | undefined
}

/** Source failures expose safe classifications without credentials, URLs, or bank records. */
export class BankDataError extends Schema.TaggedError<BankDataError, { readonly brand: unique symbol }>()(
  "BankDataError",
  {
    operation: Schema.String,
    reason: Schema.Literals(["transport", "http", "decode"]),
    retryable: Schema.Boolean,
    status: Schema.optionalKey(Schema.Int),
  },
) {
  /** Source failures intentionally omit private request and response details. */
  override get message(): string {
    return "Could not read bank source data."
  }
}

/** The native app’s read-only banking capability; all source failures stay typed. */
export interface BankDataService {
  readonly listAccounts: () => Effect.Effect<ReadonlyArray<Account>, BankDataError>
  readonly searchTransactions: (
    options: SearchTransactionsOptions,
  ) => Effect.Effect<ReadonlyArray<Transaction>, BankDataError>
  readonly summarizeSpending: (
    options: SummarizeSpendingOptions,
  ) => Effect.Effect<ReadonlyArray<SpendingByCategory>, BankDataError>
  readonly summarizeCashflow: (options: CashflowOptions) => Effect.Effect<ReadonlyArray<MonthlyCashflow>, BankDataError>
  readonly listRecurringCharges: (
    options: RecurringChargeOptions,
  ) => Effect.Effect<ReadonlyArray<RecurringCharge>, BankDataError>
  readonly getDataFreshness: () => Effect.Effect<ReadonlyArray<AccountFreshness>, BankDataError>
  readonly forecastCashflow: (options: ForecastCashflowOptions) => Effect.Effect<Forecast, BankDataError>
}

/** Bank data lifetime and credentials belong to the app’s backend scope. */
export class BankData extends Context.Service<BankData, BankDataService>()("reckon/BankData") {}
