import { BigDecimal, Schema } from "effect"
import { Account, AccountId, BankDate, Forecast, type ScheduledTransaction, type Transaction } from "./BankData.js"
import { addDays, detectRecurringCharges, filterTransfers, forecastCashflow } from "./derivations.js"

const ZERO = BigDecimal.fromBigInt(0n)
const PositiveMoney = Schema.String.check(Schema.makeFilter((value) => /^\d{1,14}(\.\d{1,4})?$/.test(value) && BigDecimal.isGreaterThan(BigDecimal.fromStringUnsafe(value), ZERO)))

/** Selected accounts are an explicit assertion of unrestricted withdrawal access. */
export const CashRunwayInput = Schema.Struct({
  spendableAccountIds: Schema.Array(AccountId).check(Schema.isMinLength(1), Schema.makeFilter((ids) => new Set(ids).size === ids.length || "Select each account once.")),
  confirmUnrestrictedAccounts: Schema.Literal(true).annotate({ description: "Required confirmation that every selected checking/savings account is immediately withdrawable and has no restricted or earmarked funds. Account metadata cannot establish this; obtain user confirmation before calling." }),
  days: Schema.optional(Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 365 }))),
  confirmedNonSalaryIncome: Schema.optional(Schema.Array(Schema.Struct({
    date: BankDate,
    amount: PositiveMoney,
    description: Schema.NonEmptyString.check(Schema.isPattern(/\S/), Schema.isMaxLength(200)),
    confirmation: Schema.NonEmptyString.check(Schema.isPattern(/\S/), Schema.isMaxLength(500)).annotate({ description: "User-confirmed basis for this dated non-salary inflow. Never infer income from a transfer or recurring credit." }),
  })).check(Schema.isMaxLength(100))),
})
export type CashRunwayInput = typeof CashRunwayInput.Type

/** A planning scenario retains actual signed balances and discloses its spending basis. */
export const CashRunway = Schema.Struct({
  scenario: Schema.Literal("no_future_salary"),
  label: Schema.Literal("Cash runway — no future salary"),
  currency: Schema.Literal("NZD"),
  cashAccounts: Schema.Array(Schema.Struct({ accountId: AccountId, actualBalance: Schema.BigDecimalFromString, spendableBalance: Schema.BigDecimalFromString })),
  excludedAccountIds: Schema.Array(AccountId),
  assumptions: Schema.Array(Schema.String),
  history: Schema.Struct({ from: BankDate, to: BankDate, firstObservedDate: Schema.NullOr(BankDate), transactionCount: Schema.Int, coverageVerified: Schema.Literal(false) }),
  dailyNonRecurringSpending: Schema.BigDecimalFromString,
  excludedScheduledInflowCount: Schema.Int,
  confirmedNonSalaryIncome: Schema.Array(Schema.Struct({ date: BankDate, amount: Schema.String, description: Schema.String, confirmation: Schema.String })),
  forecast: Forecast,
  firstNegativeDate: Schema.NullOr(BankDate),
})

/** Future credits are never inferred; ordinary spending uses a fixed 90-day observation window. */
export function forecastCashRunway(options: {
  readonly input: CashRunwayInput
  readonly today: string
  readonly accounts: ReadonlyArray<Account>
  readonly transactions: ReadonlyArray<Transaction>
  readonly scheduled: ReadonlyArray<ScheduledTransaction>
}): typeof CashRunway.Type {
  const { input, today } = options
  const selected = new Set(options.accounts.filter((account) => input.spendableAccountIds.includes(account.id) && account.currency === "NZD" && (account.type === "checking" || account.type === "savings") && account.status !== "inactive").map((account) => account.id))
  const cashAccounts = options.accounts.filter((account) => selected.has(account.id) && account.currency === "NZD" && (account.type === "checking" || account.type === "savings") && account.status !== "inactive").map((account) => ({
    accountId: account.id,
    actualBalance: account.balance,
    // Available balance can contain an overdraft. Never add borrowing capacity.
    spendableBalance: account.availableBalance === undefined ? account.balance : BigDecimal.min(account.balance, account.availableBalance),
  }))
  const from = addDays(today, -90)
  const history = options.transactions.filter((tx) => selected.has(tx.accountId) && tx.currency === "NZD" && !tx.id.startsWith("pending:") && tx.date >= from && tx.date < today)
  const cleaned = filterTransfers(history, true)
  const recurring = detectRecurringCharges(cleaned)
  const scheduled = options.scheduled.filter((event) => event.enabled && event.currency === "NZD" && (!event.accountId || selected.has(event.accountId)))
  const outflows = scheduled.filter((event) => BigDecimal.isLessThan(event.amount, ZERO))
  const historicalSpending = BigDecimal.abs(BigDecimal.sumAll(cleaned.filter((tx) => BigDecimal.isLessThan(tx.amount, ZERO)).map((tx) => tx.amount)))
  // Subtract detector totals rather than reimplementing its merchant normalization.
  const residual = BigDecimal.max(ZERO, BigDecimal.subtract(historicalSpending, BigDecimal.sumAll(recurring.map((charge) => charge.totalSpent))))
  const dailySpending = BigDecimal.divideUnsafe(residual, BigDecimal.fromBigInt(90n))
  const confirmedIncome = input.confirmedNonSalaryIncome ?? []
  const base = forecastCashflow({
    today, days: input.days ?? 365,
    startingBalance: BigDecimal.sumAll(cashAccounts.map((account) => account.spendableBalance)),
    recurring, income: [], scheduled: outflows,
  })
  let balance = base.startingBalance
  let totalIncome = ZERO
  let totalSpending = ZERO
  const points: Array<typeof Forecast.Type.points[number]> = []
  const risks: Array<typeof Forecast.Type.risks[number]> = []
  const events = [...base.events, ...confirmedIncome.map((income) => ({ date: income.date, description: income.description, amount: BigDecimal.fromStringUnsafe(income.amount), kind: "expected_income" as const }))].sort((a, b) => a.date.localeCompare(b.date))
  let cursor = 0
  for (let i = 0; i < base.points.length; i++) {
    const date = addDays(today, i)
    // Today's reported balance is the starting point; projected spending starts tomorrow.
    if (i > 0) {
      balance = BigDecimal.subtract(balance, dailySpending)
      totalSpending = BigDecimal.sum(totalSpending, dailySpending)
    }
    while (cursor < events.length && events[cursor].date <= date) {
      const event = events[cursor]
      balance = BigDecimal.sum(balance, event.amount)
      if (BigDecimal.isLessThan(event.amount, ZERO)) totalSpending = BigDecimal.subtract(totalSpending, event.amount)
      else totalIncome = BigDecimal.sum(totalIncome, event.amount)
      cursor++
    }
    const projectedBalance = BigDecimal.round(balance, { scale: 2 })
    points.push({ date, projectedBalance })
    if (BigDecimal.isLessThan(balance, ZERO)) risks.push({ date, projectedBalance, reason: "No-future-salary scenario balance is below zero" })
  }
  return {
    scenario: "no_future_salary", label: "Cash runway — no future salary", currency: "NZD",
    cashAccounts, excludedAccountIds: options.accounts.filter((account) => !selected.has(account.id)).map((account) => account.id),
    assumptions: [
      "Selected accounts were explicitly confirmed immediately withdrawable with no restricted or earmarked funds; account metadata cannot verify withdrawal restrictions.",
      "Only selected NZD checking/savings cash is included. Investments, manual assets, credit accounts and credit limits are excluded. Genuine negative selected cash balances remain negative.",
      "Future salary is zero. All detected credits and all scheduled inflows are excluded. Only explicitly dated, user-confirmed non-salary income is added; incoming transfers are not assumed to be income.",
      "Recurring outflows and enabled NZD scheduled outflows are projected. Other historical outflows become a daily allowance using the previous 90 complete UTC days; transfers within selected accounts are excluded heuristically.",
      ...(BigDecimal.isZero(historicalSpending) ? ["No non-transfer historical outflows were observed. The daily allowance is zero because spending evidence is missing; this does not establish a full cash runway."] : []),
      "History coverage is unverified: the first observed transaction does not establish when the account history begins. Missing history, one-off costs and unobserved future bills can materially change runway.",
      "Scheduled bills not detected as recurring may also appear in the historical daily allowance; this conservative overlap is not automatically removed. Bills due today are conservatively treated as unpaid and deducted from the projected point today; this can double-count an already paid bill. The reported starting balance remains the actual cash balance.",
      "Daily allowance is additional to the listed events and is included in points and totalSpending. No inflation, spending changes or new borrowing are assumed. A non-negative endpoint is not a guarantee beyond the requested horizon.",
    ],
    history: { from, to: addDays(today, -1), firstObservedDate: history.map((tx) => tx.date).sort()[0] ?? null, transactionCount: history.length, coverageVerified: false },
    dailyNonRecurringSpending: dailySpending,
    excludedScheduledInflowCount: scheduled.filter((event) => BigDecimal.isGreaterThan(event.amount, ZERO)).length,
    confirmedNonSalaryIncome: confirmedIncome,
    forecast: { ...base, endingBalance: BigDecimal.round(balance, { scale: 2 }), netChange: BigDecimal.round(BigDecimal.subtract(balance, base.startingBalance), { scale: 2 }), totalIncome: BigDecimal.round(totalIncome, { scale: 2 }), totalSpending: BigDecimal.round(totalSpending, { scale: 2 }), points, risks, events },
    firstNegativeDate: risks[0]?.date ?? null,
  }
}
