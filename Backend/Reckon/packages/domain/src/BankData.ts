// Bank-data domain — value types (Schema), options, and the BankData
// service interface + Context tag. No runtime, no I/O. Pure helpers that
// operate over these types live in ./derivations.ts; the only known
// implementation of BankDataService lives in @reckon/akahu.

import { BigDecimal, Context, Effect, Schema, Stream } from "effect";
import type { FlagInbox, FlagKey, FlagState, Ledger } from "./flags.js";
import type { Fortnight } from "./fortnight.js";

export const AccountId = Schema.String.pipe(Schema.brand("AccountId"));
export type AccountId = typeof AccountId.Type;

export const TransactionId = Schema.String.pipe(Schema.brand("TransactionId"));
export type TransactionId = typeof TransactionId.Type;

export const Account = Schema.Struct({
  id: AccountId.annotate({
    description: "Unique identifier for the account.",
  }),
  name: Schema.String.annotate({
    description: "Human-readable name for the account.",
  }),
  type: Schema.Literals([
    "checking",
    "savings",
    "credit",
    "loan",
    "investment",
  ]).annotate({
    description:
      "Type of account (e.g. 'checking', 'savings', 'credit', 'loan', 'investment').",
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
});

export type Account = typeof Account.Type;

export const Transaction = Schema.Struct({
  id: TransactionId.annotate({
    description: "Unique identifier for the transaction.",
  }),
  accountId: AccountId.annotate({
    description:
      "Unique identifier for the account the transaction belongs to.",
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
    description:
      "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Amount of the transaction.",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
});

export type Transaction = typeof Transaction.Type;

export const SpendingByCategory = Schema.Struct({
  category: Schema.String.annotate({
    description:
      "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  spent: Schema.BigDecimalFromString.annotate({
    description: "Total spent in the category over the trailing 3 months.",
  }),
  transactionCount: Schema.Number.annotate({
    description:
      "Number of transactions in the category over the trailing 3 months.",
  }),
});

export type SpendingByCategory = typeof SpendingByCategory.Type;

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
  transactionCount: Schema.Number.annotate({
    description: "Number of transactions for the month.",
  }),
});

export type MonthlyCashflow = typeof MonthlyCashflow.Type;

export const RecurringCharge = Schema.Struct({
  merchant: Schema.String.annotate({
    description: "Normalised counterparty name (e.g. 'PAK'nSAVE').",
  }),
  category: Schema.optional(
    Schema.String.annotate({
      description:
        "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
    }),
  ),
  cadence: Schema.Literals([
    "weekly",
    "fortnightly",
    "monthly",
    "quarterly",
  ]).annotate({
    description:
      "Cadence of the recurring charge (weekly, fortnightly, monthly, quarterly).",
  }),
  occurrences: Schema.Number.annotate({
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
      description:
        "Amount of the most recent charge in the cluster — feeds hike detection.",
    }),
  ),
});

export type RecurringCharge = typeof RecurringCharge.Type;

export const UnusualTransaction = Schema.Struct({
  transaction: Transaction,
  category: Schema.String.annotate({
    description:
      "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  baselineMedian: Schema.BigDecimalFromString.annotate({
    description: "Baseline median of the category.",
  }),
  ratio: Schema.Number.annotate({
    description: "Ratio of the unusual transaction to the baseline median.",
  }),
});

export type UnusualTransaction = typeof UnusualTransaction.Type;

export const MerchantSummary = Schema.Struct({
  merchant: Schema.String.annotate({
    description: "Normalised counterparty name (e.g. 'PAK'nSAVE').",
  }),
  category: Schema.optional(
    Schema.String.annotate({
      description:
        "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
    }),
  ),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Amount of the merchant summary.",
  }),
  transactionCount: Schema.Number.annotate({
    description: "Number of transactions for the merchant summary.",
  }),
  averageAmount: Schema.BigDecimalFromString.annotate({
    description: "Average amount of the merchant summary.",
  }),
});

export type MerchantSummary = typeof MerchantSummary.Type;

export const RoundUpUnit = Schema.Literals([1, 2, 5]).annotate({
  description:
    "Round-up granularity in dollars. Each outgoing transaction rounds up to the next multiple of this unit; the difference is the simulated saving.",
});

export type RoundUpUnit = typeof RoundUpUnit.Type;

export const RoundUpMonthBucket = Schema.Struct({
  month: Schema.String.annotate({
    description: "Month of the round-up bucket (YYYY-MM).",
  }),
  saved: Schema.BigDecimalFromString.annotate({
    description: "Simulated savings for the month.",
  }),
  transactionCount: Schema.Number.annotate({
    description: "Number of transactions contributing to the month's savings.",
  }),
});

export type RoundUpMonthBucket = typeof RoundUpMonthBucket.Type;

export const RoundUpDayBucket = Schema.Struct({
  date: Schema.String.annotate({
    description: "Day of the round-up bucket (YYYY-MM-DD).",
  }),
  saved: Schema.BigDecimalFromString.annotate({
    description: "Simulated savings for the day.",
  }),
  transactionCount: Schema.Number.annotate({
    description: "Number of transactions contributing to the day's savings.",
  }),
});

export type RoundUpDayBucket = typeof RoundUpDayBucket.Type;

export const RoundUpMerchantBucket = Schema.Struct({
  merchant: Schema.String.annotate({
    description: "Normalised counterparty name.",
  }),
  saved: Schema.BigDecimalFromString.annotate({
    description: "Simulated savings attributable to this merchant.",
  }),
  transactionCount: Schema.Number.annotate({
    description: "Number of transactions at this merchant.",
  }),
});

export type RoundUpMerchantBucket = typeof RoundUpMerchantBucket.Type;

export const RoundUpSummary = Schema.Struct({
  unit: RoundUpUnit,
  totalSaved: Schema.BigDecimalFromString.annotate({
    description: "Total simulated savings across the range.",
  }),
  transactionCount: Schema.Number.annotate({
    description: "Number of outgoing transactions considered.",
  }),
  byMonth: Schema.Array(RoundUpMonthBucket).annotate({
    description: "Savings broken down by month, ascending.",
  }),
  byDay: Schema.Array(RoundUpDayBucket).annotate({
    description:
      "Savings broken down by day, ascending. Only days with non-zero savings.",
  }),
  byMerchant: Schema.Array(RoundUpMerchantBucket).annotate({
    description: "Top merchants by simulated savings, descending.",
  }),
});

export type RoundUpSummary = typeof RoundUpSummary.Type;

export const BudgetConfig = Schema.Struct({
  category: Schema.String.annotate({
    description:
      "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  monthlyLimit: Schema.BigDecimalFromString.annotate({
    description: "Monthly limit for the category.",
  }),
  currency: Schema.optional(
    Schema.String.annotate({
      description: "Currency code (e.g. 'NZD').",
    }),
  ),
});

export type BudgetConfig = typeof BudgetConfig.Type;

export const BudgetStatus = Schema.Struct({
  category: Schema.String.annotate({
    description:
      "Source-assigned merchant category (e.g. 'Supermarkets and grocery stores').",
  }),
  monthlyLimit: Schema.BigDecimalFromString.annotate({
    description: "Monthly limit for the category.",
  }),
  spent: Schema.BigDecimalFromString.annotate({
    description: "Spent for the category.",
  }),
  remaining: Schema.BigDecimalFromString.annotate({
    description: "Remaining for the category.",
  }),
  pctUsed: Schema.Number.annotate({
    description: "Percentage used for the category.",
  }),
  daysIntoPeriod: Schema.Number.annotate({
    description: "Days into the period for the category.",
  }),
  daysInPeriod: Schema.Number.annotate({
    description: "Days in the period for the category.",
  }),
  pctOfPeriodElapsed: Schema.Number.annotate({
    description: "Percentage of the period elapsed for the category.",
  }),
  projectedSpend: Schema.BigDecimalFromString.annotate({
    description: "Projected spend for the category.",
  }),
  projectedOverage: Schema.BigDecimalFromString.annotate({
    description: "Projected overage for the category.",
  }),
  status: Schema.Literals(["under", "on_pace", "over", "exceeded"]).annotate({
    description:
      "Whether the category is under budget, on pace, over pace, or already exceeded.",
  }),
});

export type BudgetStatus = typeof BudgetStatus.Type;

export const GoalId = Schema.String.pipe(Schema.brand("GoalId"));
export type GoalId = typeof GoalId.Type;

export const ChallengeId = Schema.String.pipe(Schema.brand("ChallengeId"));
export type ChallengeId = typeof ChallengeId.Type;

/** A real calendar date, without a time or timezone, in YYYY-MM-DD format. */
export const BankDate = Schema.String.check(
  Schema.isPattern(/^(?!0000)\d{4}-\d{2}-\d{2}$/),
  Schema.makeFilter((value) => {
    const date = new Date(`${value}T00:00:00.000Z`);
    return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
  }, { description: "Must be a real calendar date in YYYY-MM-DD format." }),
);

// Input for creating or updating a savings goal. `id` is optional —
// omit to create; pass an existing id to edit. `accountIds` must be
// non-empty and `targetAmount` must be positive. When `targetDate` is
// provided it must be later than `startDate`.
export const GoalInput = Schema.Struct({
  id: Schema.optional(
    GoalId.annotate({
      description: "Existing goal id — omit to create a new goal.",
    }),
  ),
  name: Schema.String.check(Schema.makeFilter((name) => name.trim().length > 0, {
    description: "Goal name must not be blank.",
  })).annotate({
    description: "Human-readable label for the goal (e.g. 'Emergency fund').",
  }),
  targetAmount: Schema.BigDecimalFromString.check(
    Schema.isGreaterThanBigDecimal(BigDecimal.fromBigInt(0n)),
    Schema.isLessThanBigDecimal(BigDecimal.fromBigInt(1_000_000_000_000_000n)),
    Schema.makeFilter((amount) => BigDecimal.normalize(amount).scale <= 4, { description: "Goal target supports at most four decimal places." }),
  ).annotate({
    description: "The total amount to save. Must be positive, below 10^15, with at most four decimal places.",
  }),
  currency: Schema.optional(
    Schema.String.annotate({
      description: "Currency code (e.g. 'NZD'). Defaults to the primary account currency.",
    }),
  ),
  accountIds: Schema.Array(AccountId.check(Schema.isMinLength(1))).annotate({
    description: "One or more account ids whose balances count toward this goal. Must be non-empty.",
  }),
  startDate: BankDate.annotate({
    description: "Start date of the savings window (YYYY-MM-DD).",
  }),
  targetDate: Schema.optional(
    BankDate.annotate({
      description: "Desired completion date (YYYY-MM-DD). Must be after startDate when provided.",
    }),
  ),
}).check(
  Schema.makeFilter(
    (input) => {
      if (!BigDecimal.isGreaterThan(input.targetAmount, BigDecimal.fromBigInt(0n))) {
        return "targetAmount must be greater than zero";
      }
      if (input.accountIds.length === 0) {
        return "accountIds must be non-empty";
      }
      if (
        input.targetDate !== undefined &&
        input.targetDate <= input.startDate
      ) {
        return "targetDate must be after startDate";
      }
    },
    { description: "Goal input validation: targetAmount > 0, at least one account, targetDate (if set) after startDate." },
  ),
);
export type GoalInput = typeof GoalInput.Type;

// Persisted goal configuration returned after upsert or list. All
// optional input fields have been resolved to required values.
export const GoalConfig = Schema.Struct({
  id: GoalId.annotate({
    description: "Stable identifier for the goal.",
  }),
  name: Schema.String.annotate({
    description: "Human-readable label for the goal.",
  }),
  targetAmount: Schema.BigDecimalFromString.annotate({
    description: "The total amount to save.",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
  accountIds: Schema.Array(AccountId).annotate({
    description: "Account ids whose balances count toward this goal.",
  }),
  startDate: Schema.String.annotate({
    description: "Start date of the savings window (YYYY-MM-DD).",
  }),
  targetDate: Schema.optional(
    Schema.String.annotate({
      description: "Desired completion date (YYYY-MM-DD).",
    }),
  ),
});
export type GoalConfig = typeof GoalConfig.Type;

// Live status of a savings goal — enriched with progress metrics.
export const GoalStatus = Schema.Struct({
  id: GoalId.annotate({
    description: "Stable identifier for the goal.",
  }),
  name: Schema.String.annotate({
    description: "Human-readable label for the goal.",
  }),
  targetAmount: Schema.BigDecimalFromString.annotate({
    description: "The total amount to save.",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
  saved: Schema.BigDecimalFromString.annotate({
    description: "Amount saved so far (sum of tracked account balances).",
  }),
  pct: Schema.Number.annotate({
    description: "Progress percentage (0–100). Capped at 100 once achieved.",
  }),
  saveRate: Schema.BigDecimalFromString.annotate({
    description: "Average amount saved per month since startDate.",
  }),
  etaDate: Schema.optional(
    Schema.String.annotate({
      description: "Projected completion date (YYYY-MM-DD) at the current save rate.",
    }),
  ),
  requiredMonthly: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "Monthly saving required to hit targetDate on time.",
    }),
  ),
  milestone: Schema.Literals([0, 25, 50, 75, 100]).annotate({
    description: "Nearest milestone crossed (0, 25, 50, 75, or 100 percent).",
  }),
  status: Schema.Literals(["on_track", "behind", "ahead", "stalled", "achieved"]).annotate({
    description:
      "Whether the goal is on track, behind, ahead of schedule, stalled (no recent saves), or already achieved.",
  }),
});
export type GoalStatus = typeof GoalStatus.Type;

export const ChallengeKind = Schema.Literals(["category_cap", "beat_save_rate"]);

// A self-set, time-boxed saving challenge. `kind` discriminates the shape:
// `category_cap` uses `reference` (a spending category) and ignores accounts;
// `beat_save_rate` uses `accountIds` (savings accounts) and ignores reference.
export const ChallengeInput = Schema.Struct({
  id: Schema.optional(
    ChallengeId.annotate({ description: "Existing challenge id — omit to create." }),
  ),
  kind: ChallengeKind.annotate({
    description: "'category_cap' (keep a category under target) or 'beat_save_rate' (put more than target into savings).",
  }),
  name: Schema.String.annotate({ description: "Label, e.g. 'Takeaways under $100'." }),
  target: Schema.BigDecimalFromString.annotate({
    description: "The cap (category_cap) or savings target (beat_save_rate). Positive NZD.",
  }),
  reference: Schema.optional(
    Schema.String.annotate({ description: "Category to cap (category_cap only)." }),
  ),
  accountIds: Schema.optional(
    Schema.Array(AccountId).annotate({
      description: "Savings accounts whose net inflow counts (beat_save_rate only).",
    }),
  ),
  startDate: Schema.String.annotate({ description: "ISO start date (YYYY-MM-DD)." }),
  endDate: Schema.String.annotate({ description: "ISO end date (YYYY-MM-DD); must be after startDate." }),
}).check(
  Schema.makeFilter(
    (input) => {
      if (!BigDecimal.isGreaterThan(input.target, BigDecimal.fromBigInt(0n))) {
        return "target must be greater than zero";
      }
      if (input.endDate <= input.startDate) {
        return "endDate must be after startDate";
      }
      if (
        input.kind === "category_cap" &&
        (input.reference === undefined || input.reference === "")
      ) {
        return "category_cap requires a reference category";
      }
      if (
        input.kind === "beat_save_rate" &&
        (input.accountIds === undefined || input.accountIds.length === 0)
      ) {
        return "beat_save_rate requires at least one account";
      }
    },
    { description: "Challenge input: target > 0, ordered dates, per-kind fields present." },
  ),
);
export type ChallengeInput = typeof ChallengeInput.Type;

export const ChallengeConfig = Schema.Struct({
  id: ChallengeId.annotate({
    description: "Stable identifier for the challenge.",
  }),
  kind: ChallengeKind.annotate({
    description: "'category_cap' (keep a category under target) or 'beat_save_rate' (put more than target into savings).",
  }),
  name: Schema.String.annotate({
    description: "Human-readable label for the challenge.",
  }),
  target: Schema.BigDecimalFromString.annotate({
    description: "The cap (category_cap) or savings target (beat_save_rate). Positive NZD.",
  }),
  reference: Schema.optional(
    Schema.String.annotate({
      description: "Category being capped (category_cap only).",
    }),
  ),
  accountIds: Schema.Array(AccountId).annotate({
    description: "Savings accounts whose net inflow counts (beat_save_rate; empty for category_cap).",
  }),
  startDate: Schema.String.annotate({
    description: "Challenge start date (YYYY-MM-DD).",
  }),
  endDate: Schema.String.annotate({
    description: "Challenge end date (YYYY-MM-DD).",
  }),
});
export type ChallengeConfig = typeof ChallengeConfig.Type;

export const ChallengeStatus = Schema.Struct({
  id: ChallengeId.annotate({
    description: "Stable identifier for the challenge.",
  }),
  kind: ChallengeKind.annotate({
    description: "'category_cap' or 'beat_save_rate'.",
  }),
  name: Schema.String.annotate({
    description: "Human-readable label for the challenge.",
  }),
  target: Schema.BigDecimalFromString.annotate({
    description: "The cap (category_cap) or savings target (beat_save_rate).",
  }),
  reference: Schema.optional(
    Schema.String.annotate({
      description: "Category being capped (category_cap only).",
    }),
  ),
  windowStart: Schema.String.annotate({ description: "Challenge start date." }),
  windowEnd: Schema.String.annotate({ description: "Challenge end date." }),
  actual: Schema.BigDecimalFromString.annotate({
    description: "Spend in the category (category_cap) or net inflow (beat_save_rate) so far.",
  }),
  projected: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "Projected end-of-window value while running; absent once resolved.",
    }),
  ),
  status: Schema.Literals(["on_track", "at_risk", "won", "lost"]).annotate({
    description: "Live pacing while running (on_track/at_risk); won/lost once resolved.",
  }),
  verdict: Schema.optional(
    Schema.String.annotate({ description: "Blunt dated/dollar'd line once resolved; absent while running." }),
  ),
});
export type ChallengeStatus = typeof ChallengeStatus.Type;

export const FoundMoneyBucket = Schema.Struct({
  kind: Schema.Literals(["round_ups", "under_budget", "standing_orders"]).annotate({
    description: "Which reclaimable signal this bucket represents.",
  }),
  label: Schema.String.annotate({ description: "Human label for the bucket." }),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Monthly NZD figure for this bucket.",
  }),
  note: Schema.String.annotate({
    description: "Honest one-line explanation, dollar'd and specific.",
  }),
});
export type FoundMoneyBucket = typeof FoundMoneyBucket.Type;

export const FoundMoneySummary = Schema.Struct({
  buckets: Schema.Array(FoundMoneyBucket),
  reclaimable: Schema.BigDecimalFromString.annotate({
    description:
      "Monthly NZD you could bank now without a behaviour change (round-ups + under-budget headroom). Excludes standing-orders burn, which is an audit target, not found money.",
  }),
});
export type FoundMoneySummary = typeof FoundMoneySummary.Type;

export const ForecastEventKind = Schema.Literals([
  "recurring_charge",
  "expected_income",
]).annotate({
  description:
    "Kind of forecast event — either a detected recurring outflow or expected recurring income.",
});

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
  kind: ForecastEventKind,
});

export type ForecastEvent = typeof ForecastEvent.Type;

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
});

export type ForecastRisk = typeof ForecastRisk.Type;

export const ForecastPoint = Schema.Struct({
  date: Schema.String.annotate({
    description: "Date of the projected balance point (YYYY-MM-DD).",
  }),
  projectedBalance: Schema.BigDecimalFromString.annotate({
    description: "Projected liquid balance on that date.",
  }),
});

export type ForecastPoint = typeof ForecastPoint.Type;

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
    description:
      "Projected events (recurring charges + expected income) that drive the curve.",
  }),
  risks: Schema.Array(ForecastRisk).annotate({
    description:
      "Dates where the projected balance crosses zero or otherwise warrants attention.",
  }),
});

export type Forecast = typeof Forecast.Type;

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
});

export type AccountFreshness = typeof AccountFreshness.Type;

export const CategoryRuleId = Schema.String.pipe(Schema.brand("CategoryRuleId"));
export type CategoryRuleId = typeof CategoryRuleId.Type;

export const ScheduledTransactionId = Schema.String.pipe(
  Schema.brand("ScheduledTransactionId"),
);
export type ScheduledTransactionId = typeof ScheduledTransactionId.Type;

export const ManualAccountId = Schema.String.pipe(
  Schema.brand("ManualAccountId"),
);
export type ManualAccountId = typeof ManualAccountId.Type;

export const ManualAccountKind = Schema.Literals([
  "property",
  "vehicle",
  "investment",
  "cash",
  "mortgage",
  "loan",
]).annotate({
  description:
    "What the account represents. property/vehicle/investment/cash are assets; mortgage/loan are liabilities.",
});
export type ManualAccountKind = typeof ManualAccountKind.Type;

// User-defined account Akahu can't see — held outside the bank-feed
// mirror so re-syncs don't touch it. `balance` is a positive magnitude;
// `kind` determines whether it adds to assets or liabilities.
export const ManualAccount = Schema.Struct({
  id: ManualAccountId,
  name: Schema.String,
  kind: ManualAccountKind,
  balance: Schema.BigDecimalFromString.annotate({
    description:
      "Current value (positive magnitude). Liability accounts are still stored as positive numbers.",
  }),
  currency: Schema.String,
  notes: Schema.optional(Schema.String),
});
export type ManualAccount = typeof ManualAccount.Type;

export const ManualAccountInput = Schema.Struct({
  id: Schema.optional(ManualAccountId),
  name: Schema.String,
  kind: ManualAccountKind,
  balance: Schema.BigDecimalFromString,
  currency: Schema.optional(Schema.String),
  notes: Schema.optional(Schema.String),
});
export type ManualAccountInput = typeof ManualAccountInput.Type;

export const isManualLiability = (kind: ManualAccountKind): boolean =>
  kind === "mortgage" || kind === "loan";

export const ScheduleCadence = Schema.Literals([
  "weekly",
  "fortnightly",
  "monthly",
  "quarterly",
  "yearly",
]);
export type ScheduleCadence = typeof ScheduleCadence.Type;

// User-defined recurring event (rent, salary, subscription).
// Signed `amount` — negative for outflows, positive for inflows. The
// forecast expands these forward from `nextDate` using `cadence`.
// `accountId` is optional: when present, this event belongs to that
// account; otherwise it applies to the aggregated liquid balance.
export const ScheduledTransaction = Schema.Struct({
  id: ScheduledTransactionId,
  description: Schema.String.annotate({
    description: "Human-readable label (e.g. 'Rent', 'Salary').",
  }),
  amount: Schema.BigDecimalFromString.annotate({
    description: "Signed amount — negative for outflows, positive for income.",
  }),
  currency: Schema.String,
  cadence: ScheduleCadence,
  nextDate: Schema.String.annotate({
    description: "Next occurrence (YYYY-MM-DD). Expanded forward by cadence.",
  }),
  accountId: Schema.optional(AccountId).annotate({
    description: "Account this event posts to. Omit for liquid-balance level.",
  }),
  category: Schema.optional(Schema.String),
  enabled: Schema.Boolean,
});

export type ScheduledTransaction = typeof ScheduledTransaction.Type;

// Input for upserting. `id` optional — omit to create; pass an existing
// id to edit. Same shape as ScheduledTransaction with id/enabled/currency
// optional and sensible defaults applied by the adapter.
export const ScheduledTransactionInput = Schema.Struct({
  id: Schema.optional(ScheduledTransactionId),
  description: Schema.String,
  amount: Schema.BigDecimalFromString,
  currency: Schema.optional(Schema.String),
  cadence: ScheduleCadence,
  nextDate: Schema.String,
  accountId: Schema.optional(AccountId),
  category: Schema.optional(Schema.String),
  enabled: Schema.optional(Schema.Boolean),
});

export type ScheduledTransactionInput = typeof ScheduledTransactionInput.Type;

// Per-transaction override — "just this one" from the inspector. Set
// alongside a rule when the user wants to recategorize a single row
// without learning a pattern, or to override what a rule would assign.
export const TransactionOverride = Schema.Struct({
  transactionId: TransactionId,
  category: Schema.String,
});

export type TransactionOverride = typeof TransactionOverride.Type;

// A user-defined override: when a transaction's description or
// merchant contains `pattern` (case-insensitive), display it under
// `category`. Higher `priority` wins on conflict. Applied at query
// time — the source row is never mutated, so an Akahu re-sync can't
// undo it.
export const CategoryRule = Schema.Struct({
  id: CategoryRuleId,
  pattern: Schema.String.annotate({
    description: "Case-insensitive substring matched against merchant + description.",
  }),
  category: Schema.String.annotate({
    description: "Category name to apply when the pattern matches.",
  }),
  priority: Schema.Int.annotate({
    description: "Higher priority wins on conflict. Default 0.",
  }),
  enabled: Schema.Boolean,
  matchPatterns: Schema.optional(Schema.Array(Schema.String)),
  excludedTransactionIds: Schema.optional(Schema.Array(TransactionId)),
  matchKind: Schema.optional(Schema.Literals(["substring", "merchant", "description"])),
  direction: Schema.optional(Schema.Literals(["any", "debit", "credit"])),
  currency: Schema.optional(Schema.String),
  missingOnly: Schema.optional(Schema.Boolean),
  excludeTransfers: Schema.optional(Schema.Boolean),
});

export type CategoryRule = typeof CategoryRule.Type;

// Input for upserting a rule. `id` is optional — omit to create, pass
// an existing id to edit. The adapter assigns ids for new rules.
export const CategoryRuleInput = Schema.Struct({
  id: Schema.optional(CategoryRuleId),
  pattern: Schema.String,
  category: Schema.String,
  priority: Schema.optional(Schema.Int),
  enabled: Schema.optional(Schema.Boolean),
  matchPatterns: Schema.optional(Schema.Array(Schema.String)),
  excludedTransactionIds: Schema.optional(Schema.Array(TransactionId)),
  matchKind: Schema.optional(Schema.Literals(["substring", "merchant", "description"])),
  direction: Schema.optional(Schema.Literals(["any", "debit", "credit"])),
  currency: Schema.optional(Schema.String),
  missingOnly: Schema.optional(Schema.Boolean),
  excludeTransfers: Schema.optional(Schema.Boolean),
});

export type CategoryRuleInput = typeof CategoryRuleInput.Type;

// A detected interbank transfer — two transactions on different
// accounts, equal |amount|, opposite signs, within a few days.
// Detection lives in `derivations.ts` (`detectTransferPairs`).
export const TransferPair = Schema.Struct({
  fromId: TransactionId.annotate({
    description: "Id of the outgoing leg (negative amount).",
  }),
  toId: TransactionId.annotate({
    description: "Id of the incoming leg (positive amount).",
  }),
  fromAccountId: AccountId,
  toAccountId: AccountId,
  amount: Schema.BigDecimalFromString.annotate({
    description: "Absolute amount transferred.",
  }),
  date: Schema.String.annotate({
    description: "Earlier of the two transaction dates (YYYY-MM-DD).",
  }),
});

export type TransferPair = typeof TransferPair.Type;

export const BankCategory = Schema.Struct({
  id: Schema.String.annotate({
    description: "Stable category identifier from the source.",
  }),
  name: Schema.String.annotate({
    description:
      "Category name (e.g. 'Supermarkets and grocery stores').",
  }),
  group: Schema.optional(
    Schema.String.annotate({
      description:
        "Higher-level category grouping (e.g. 'Household', 'Lifestyle').",
    }),
  ),
});

export type BankCategory = typeof BankCategory.Type;

export interface DateRangeOptions {
  readonly from?: string | null | undefined;
  readonly to?: string | undefined;
}

// Shared schema fragment for an inclusive date-range filter. Spread into a
// payload/query/parameters struct (`{ ...DateRange, ... }`) so the RPC, REST,
// and MCP surfaces share one definition and the shape/docs can't drift.
export const DateRange = {
  from: Schema.optional(Schema.NullOr(Schema.String)).annotate({
    description: "Inclusive start date in YYYY-MM-DD format. Null includes all available history; omitted uses the source default.",
  }),
  to: Schema.optional(Schema.String).annotate({
    description: "Inclusive end date in YYYY-MM-DD format.",
  }),
};

export interface SearchTransactionsOptions extends DateRangeOptions {
  readonly query?: string | undefined;
  readonly accountId?: string | undefined;
  readonly category?: string | undefined;
  readonly limit?: number | null | undefined;
  readonly excludeTransfers?: boolean | undefined;
}

export interface SummarizeSpendingOptions extends DateRangeOptions {
  readonly excludeTransfers?: boolean | undefined;
}

export interface CashflowOptions extends DateRangeOptions {
  readonly excludeTransfers?: boolean | undefined;
}

export interface RecurringChargeOptions extends DateRangeOptions {
  readonly minOccurrences?: number | undefined;
}

export interface UnusualTransactionOptions extends DateRangeOptions {
  readonly threshold?: number | undefined;
  readonly minBaseline?: number | undefined;
}

export interface TopMerchantsOptions extends DateRangeOptions {
  readonly limit?: number | undefined;
  readonly direction?: "spending" | "income" | undefined;
  readonly excludeTransfers?: boolean | undefined;
}

export interface RoundUpOptions extends DateRangeOptions {
  readonly unit: RoundUpUnit;
  readonly excludeTransfers?: boolean | undefined;
  readonly merchantLimit?: number | undefined;
}

export interface BudgetStatusOptions {
  readonly month?: string | undefined;
  readonly categories?: ReadonlyArray<string> | undefined;
}

export interface ForecastCashflowOptions {
  readonly days?: number | undefined;
  readonly excludeTransfers?: boolean | undefined;
}

export interface BackfillOptions {
  readonly accountId?: string | undefined;
  readonly stepMonths?: number | undefined;
  readonly pauseMs?: number | undefined;
  readonly maxMonths?: number | undefined;
}

// One event per (account, window) the backfill walks. `done` flips to
// true on the last event for an account — either because Akahu returned
// zero transactions for the window or because we hit the lookback floor.
// The UI accumulates events keyed by accountId to render per-account
// progress; `BackfillStarted` (oldestBefore) and the final state can be
// derived from the event stream alone.
export const BackfillEvent = Schema.Struct({
  accountId: AccountId,
  accountName: Schema.String,
  oldestBefore: Schema.NullOr(Schema.String),
  from: Schema.String,
  to: Schema.String,
  count: Schema.Int,
  done: Schema.Boolean,
});

export type BackfillEvent = typeof BackfillEvent.Type;

export interface BankDataService {
  readonly listAccounts: () => Effect.Effect<ReadonlyArray<Account>>;
  readonly searchTransactions: (
    options: SearchTransactionsOptions,
  ) => Effect.Effect<ReadonlyArray<Transaction>>;
  readonly summarizeSpending: (
    options: SummarizeSpendingOptions,
  ) => Effect.Effect<ReadonlyArray<SpendingByCategory>>;
  readonly summarizeCashflow: (
    options: CashflowOptions,
  ) => Effect.Effect<ReadonlyArray<MonthlyCashflow>>;
  readonly listRecurringCharges: (
    options: RecurringChargeOptions,
  ) => Effect.Effect<ReadonlyArray<RecurringCharge>>;
  readonly findUnusualTransactions: (
    options: UnusualTransactionOptions,
  ) => Effect.Effect<ReadonlyArray<UnusualTransaction>>;
  readonly topMerchants: (
    options: TopMerchantsOptions,
  ) => Effect.Effect<ReadonlyArray<MerchantSummary>>;
  readonly summarizeRoundUps: (
    options: RoundUpOptions,
  ) => Effect.Effect<RoundUpSummary>;
  readonly listTransferPairs: (
    options: DateRangeOptions,
  ) => Effect.Effect<ReadonlyArray<TransferPair>>;
  readonly listBudgets: () => Effect.Effect<ReadonlyArray<BudgetConfig>>;
  readonly upsertBudget: (
    input: BudgetConfig,
  ) => Effect.Effect<BudgetConfig>;
  readonly deleteBudget: (
    input: { readonly category: string },
  ) => Effect.Effect<void>;
  readonly listGoals: () => Effect.Effect<ReadonlyArray<GoalConfig>>;
  readonly upsertGoal: (input: GoalInput) => Effect.Effect<GoalConfig>;
  readonly deleteGoal: (
    input: { readonly id: GoalId },
  ) => Effect.Effect<void>;
  readonly goalStatus: () => Effect.Effect<ReadonlyArray<GoalStatus>>;
  readonly listChallenges: () => Effect.Effect<ReadonlyArray<ChallengeConfig>>;
  readonly upsertChallenge: (
    input: ChallengeInput,
  ) => Effect.Effect<ChallengeConfig>;
  readonly deleteChallenge: (
    input: { readonly id: ChallengeId },
  ) => Effect.Effect<void>;
  readonly challengeStatus: () => Effect.Effect<ReadonlyArray<ChallengeStatus>>;
  readonly foundMoney: () => Effect.Effect<FoundMoneySummary>;
  // Flags — the "Reckon as Linear" actionable-inbox pipeline. Detection is
  // derive-on-read; human actions (snooze/act/dismiss) persist in a sidecar
  // and are overlaid by flagInbox. Resolution is implicit: a flag that no
  // longer triggers stops appearing.
  readonly flagInbox: () => Effect.Effect<FlagInbox>;
  readonly snoozeFlag: (
    input: { readonly key: FlagKey; readonly until: string },
  ) => Effect.Effect<FlagState>;
  readonly actFlag: (
    input: {
      readonly key: FlagKey;
      readonly note?: string | undefined;
      readonly expectedImpact?: BigDecimal.BigDecimal | undefined;
    },
  ) => Effect.Effect<FlagState>;
  readonly dismissFlag: (
    input: {
      readonly key: FlagKey;
      readonly note?: string | undefined;
      readonly expiresAt?: string | undefined;
    },
  ) => Effect.Effect<FlagState>;
  readonly clearFlag: (
    input: { readonly key: FlagKey },
  ) => Effect.Effect<void>;
  // Every persisted lifecycle state — what the inbox is currently blind to
  // (dismissed/snoozed) or committed on (acting). Feeds the Settings
  // suppression review so dismissals are never silent.
  readonly listFlagStates: () => Effect.Effect<ReadonlyArray<FlagState>>;
  // The banked ledger — cumulative verified savings from acted-on flags,
  // accrued by elapsed days (never the full projection).
  readonly ledger: () => Effect.Effect<Ledger>;
  // The Fortnight — ambient pay-cycle lens. Derived live from the dominant
  // fortnightly income cluster; null when no cycle can be derived. offset 0 is
  // the current cycle, negative scrubs back.
  readonly fortnight: (
    options: { readonly offset?: number | undefined },
  ) => Effect.Effect<Fortnight | null>;
  readonly listCategoryRules: () => Effect.Effect<
    ReadonlyArray<CategoryRule>
  >;
  readonly upsertCategoryRule: (
    input: CategoryRuleInput,
  ) => Effect.Effect<CategoryRule>;
  readonly deleteCategoryRule: (
    input: { readonly id: CategoryRuleId },
  ) => Effect.Effect<void>;
  readonly listTransactionOverrides: () => Effect.Effect<
    ReadonlyArray<TransactionOverride>
  >;
  readonly setTransactionCategoryOverride: (
    input: TransactionOverride,
  ) => Effect.Effect<TransactionOverride>;
  readonly clearTransactionCategoryOverride: (
    input: { readonly transactionId: TransactionId },
  ) => Effect.Effect<void>;
  readonly listScheduledTransactions: () => Effect.Effect<
    ReadonlyArray<ScheduledTransaction>
  >;
  readonly upsertScheduledTransaction: (
    input: ScheduledTransactionInput,
  ) => Effect.Effect<ScheduledTransaction>;
  readonly deleteScheduledTransaction: (
    input: { readonly id: ScheduledTransactionId },
  ) => Effect.Effect<void>;
  readonly listManualAccounts: () => Effect.Effect<
    ReadonlyArray<ManualAccount>
  >;
  readonly upsertManualAccount: (
    input: ManualAccountInput,
  ) => Effect.Effect<ManualAccount>;
  readonly deleteManualAccount: (
    input: { readonly id: ManualAccountId },
  ) => Effect.Effect<void>;
  readonly listCategories: () => Effect.Effect<ReadonlyArray<BankCategory>>;
  readonly getDataFreshness: () => Effect.Effect<
    ReadonlyArray<AccountFreshness>
  >;
  readonly refresh: () => Effect.Effect<void>;
  readonly budgetStatus: (
    options: BudgetStatusOptions,
  ) => Effect.Effect<ReadonlyArray<BudgetStatus>>;
  readonly forecastCashflow: (
    options: ForecastCashflowOptions,
  ) => Effect.Effect<Forecast>;
  readonly backfill: (
    options: BackfillOptions,
  ) => Stream.Stream<BackfillEvent>;
}

export class BankData extends Context.Service<BankData, BankDataService>()(
  "personal-bank-mcp/BankData",
) {}
