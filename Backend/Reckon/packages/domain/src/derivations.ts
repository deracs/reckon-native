// Pure calculations over already-fetched bank transactions. No I/O or runtime state.
import { BigDecimal } from "effect"
import { RecurringCharge } from "./BankData.js"
import { addDays } from "./bank-calendar.js"
import type {
  Forecast,
  ForecastEvent,
  ForecastPoint,
  ForecastRisk,
  MonthlyCashflow,
  SpendingByCategory,
  Transaction,
  TransactionId,
} from "./BankData.js"

const ZERO = BigDecimal.fromNumberUnsafe(0)

const toNum = BigDecimal.toNumberUnsafe
const round2 = (n: BigDecimal.BigDecimal): BigDecimal.BigDecimal =>
  BigDecimal.round(n, { scale: 2, mode: "half-from-zero" })

/** Match opposite amounts across accounts within three days, keeping currencies separate. */
export const detectTransferIds = (transactions: ReadonlyArray<Transaction>): ReadonlySet<TransactionId> => {
  const transferIds = new Set<TransactionId>()
  const byAmount = new Map<string, Array<Transaction>>()
  for (const tx of transactions) {
    if (BigDecimal.isZero(tx.amount)) continue
    const key = `${tx.currency}:${BigDecimal.format(BigDecimal.abs(tx.amount))}`
    let bucket = byAmount.get(key)
    if (!bucket) {
      bucket = []
      byAmount.set(key, bucket)
    }
    bucket.push(tx)
  }
  for (const bucket of byAmount.values()) {
    if (bucket.length < 2) continue
    const sorted = [...bucket].sort((a, b) => a.date.localeCompare(b.date))
    for (const [i, a] of sorted.entries()) {
      if (transferIds.has(a.id)) continue
      for (let j = i + 1; j < sorted.length; j++) {
        const b = sorted[j]
        if (b === undefined) continue
        if (transferIds.has(b.id)) continue
        if (Math.abs(daysBetween(a.date, b.date)) > 3) break
        if (a.accountId === b.accountId) continue
        if (BigDecimal.sign(a.amount) === BigDecimal.sign(b.amount)) continue
        transferIds.add(a.id)
        transferIds.add(b.id)
        break
      }
    }
  }
  return transferIds
}

/** Exclude detected internal transfers only when requested. */
export const filterTransfers = (
  transactions: ReadonlyArray<Transaction>,
  excludeTransfers: boolean | undefined,
): ReadonlyArray<Transaction> => {
  if (!excludeTransfers) return transactions
  const ids = detectTransferIds(transactions)
  return transactions.filter((tx) => !ids.has(tx.id))
}

/** Sum outflows by source category without converting currencies. */
export const summarizeSpendingByCategory = (
  transactions: ReadonlyArray<Transaction>,
): ReadonlyArray<SpendingByCategory> => {
  const byCategory = new Map<string, { spent: BigDecimal.BigDecimal; count: number }>()
  for (const tx of transactions) {
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) continue
    const category = tx.category ?? "uncategorized"
    const current = byCategory.get(category) ?? { spent: ZERO, count: 0 }
    current.spent = BigDecimal.sum(current.spent, BigDecimal.abs(tx.amount))
    current.count += 1
    byCategory.set(category, current)
  }
  return Array.from(byCategory.entries())
    .map(([category, m]) => ({
      category,
      spent: round2(m.spent),
      transactionCount: m.count,
    }))
    .sort((a, b) => toNum(BigDecimal.subtract(b.spent, a.spent)))
}

/** Group signed income and spending by calendar month. */
export const summarizeMonthlyCashflow = (transactions: ReadonlyArray<Transaction>): ReadonlyArray<MonthlyCashflow> => {
  const byMonth = new Map<string, { income: BigDecimal.BigDecimal; spending: BigDecimal.BigDecimal; count: number }>()
  for (const tx of transactions) {
    const month = tx.date.slice(0, 7)
    const current = byMonth.get(month) ?? {
      income: ZERO,
      spending: ZERO,
      count: 0,
    }
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) {
      current.income = BigDecimal.sum(current.income, tx.amount)
    } else {
      current.spending = BigDecimal.sum(current.spending, BigDecimal.abs(tx.amount))
    }
    current.count += 1
    byMonth.set(month, current)
  }
  return Array.from(byMonth.entries())
    .map(([month, m]) => ({
      month,
      income: round2(m.income),
      spending: round2(m.spending),
      net: round2(BigDecimal.subtract(m.income, m.spending)),
      transactionCount: m.count,
    }))
    .sort((a, b) => a.month.localeCompare(b.month))
}

/** Detect stable merchant amounts and weekly, fortnightly, monthly, or quarterly cadence. */
export const detectRecurringCharges = (
  transactions: ReadonlyArray<Transaction>,
  options: { readonly minOccurrences?: number | undefined } = {},
): ReadonlyArray<RecurringCharge> => {
  const minOccurrences = Math.max(options.minOccurrences ?? 3, 2)
  const groups = new Map<string, Array<Transaction>>()
  for (const tx of transactions) {
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) continue
    const key = (tx.merchant ?? normalizeDescription(tx.description)).toLowerCase()
    if (!key) continue
    let bucket = groups.get(key)
    if (!bucket) {
      bucket = []
      groups.set(key, bucket)
    }
    bucket.push(tx)
  }
  const results: Array<RecurringCharge> = []
  for (const bucket of groups.values()) {
    if (bucket.length < minOccurrences) continue
    const amounts = bucket.map((tx) => BigDecimal.abs(tx.amount))
    const total = BigDecimal.sumAll(amounts)
    const count = BigDecimal.fromNumberUnsafe(amounts.length)
    const average = BigDecimal.divideUnsafe(total, count)
    if (BigDecimal.isZero(average)) continue
    const avgNum = toNum(average)
    const amountsNum = amounts.map(toNum)
    const variance = amountsNum.reduce((acc, x) => acc + (x - avgNum) ** 2, 0) / amountsNum.length
    const stddev = Math.sqrt(variance)
    if (stddev / avgNum > 0.25) continue
    const sorted = [...bucket].sort((a, b) => a.date.localeCompare(b.date))
    const intervals: Array<number> = []
    for (const [i, current] of sorted.entries()) {
      const previous = sorted[i - 1]
      if (previous !== undefined) intervals.push(daysBetween(previous.date, current.date))
    }
    const first = sorted[0]
    const last = sorted.at(-1)
    if (first === undefined || last === undefined) continue
    const cadence = classifyCadence(median(intervals))
    if (cadence === undefined) continue
    results.push(
      new RecurringCharge({
        merchant: first.merchant ?? first.description,
        category: first.category,
        cadence,
        occurrences: sorted.length,
        averageAmount: round2(average),
        minAmount: round2(amounts.reduce((a, b) => BigDecimal.min(a, b))),
        maxAmount: round2(amounts.reduce((a, b) => BigDecimal.max(a, b))),
        totalSpent: round2(total),
        firstDate: first.date,
        lastDate: last.date,
        lastAmount: round2(BigDecimal.abs(last.amount)),
      }),
    )
  }
  return results.sort((a, b) => toNum(BigDecimal.subtract(b.totalSpent, a.totalSpent)))
}

/** Project detected bills and income without adding discretionary spending. */
export const forecastCashflow = (options: {
  startingBalance: BigDecimal.BigDecimal
  today: string
  days: number
  recurring: ReadonlyArray<RecurringCharge>
  income: ReadonlyArray<RecurringCharge>
}): Forecast => {
  const horizon = Math.max(1, Math.min(options.days, 365))
  const endDate = addDays(options.today, horizon)
  const events: Array<ForecastEvent> = []

  for (const charge of options.recurring) {
    const dates = charge.projectDates(options.today, endDate)
    for (const date of dates) {
      events.push({
        date,
        description: charge.merchant,
        amount: BigDecimal.negate(charge.averageAmount),
        kind: "recurring_charge",
      })
    }
  }
  for (const inflow of options.income) {
    const dates = inflow.projectDates(options.today, endDate)
    for (const date of dates) {
      events.push({
        date,
        description: inflow.merchant,
        amount: inflow.averageAmount,
        kind: "expected_income",
      })
    }
  }
  events.sort((a, b) => a.date.localeCompare(b.date))

  const points: Array<ForecastPoint> = []
  const risks: Array<ForecastRisk> = []
  let balance = options.startingBalance
  let totalIncome = ZERO
  let totalSpending = ZERO
  let pointer = 0
  for (let i = 0; i <= horizon; i++) {
    const date = addDays(options.today, i)
    while (pointer < events.length) {
      const event = events[pointer]
      if (event === undefined || event.date > date) break
      balance = BigDecimal.sum(balance, event.amount)
      if (BigDecimal.isGreaterThanOrEqualTo(event.amount, ZERO)) {
        totalIncome = BigDecimal.sum(totalIncome, event.amount)
      } else {
        totalSpending = BigDecimal.sum(totalSpending, BigDecimal.abs(event.amount))
      }
      pointer++
    }
    points.push({ date, projectedBalance: round2(balance) })
    if (BigDecimal.isLessThan(balance, ZERO) && risks.at(-1)?.date !== date) {
      risks.push({
        date,
        projectedBalance: round2(balance),
        reason: "Projected balance crosses zero",
      })
    }
  }

  return {
    startDate: options.today,
    endDate,
    startingBalance: round2(options.startingBalance),
    endingBalance: round2(balance),
    netChange: round2(BigDecimal.subtract(balance, options.startingBalance)),
    totalIncome: round2(totalIncome),
    totalSpending: round2(totalSpending),
    points,
    events,
    risks,
  }
}

const daysBetween = (a: string, b: string): number => {
  const da = Date.UTC(Number(a.slice(0, 4)), Number(a.slice(5, 7)) - 1, Number(a.slice(8, 10)))
  const db = Date.UTC(Number(b.slice(0, 4)), Number(b.slice(5, 7)) - 1, Number(b.slice(8, 10)))
  return Math.round((db - da) / 86400000)
}

const median = (values: ReadonlyArray<number>): number => {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  const middle = sorted[mid]
  const previous = sorted[mid - 1]
  if (middle === undefined) return 0
  return sorted.length % 2 === 1 || previous === undefined ? middle : (previous + middle) / 2
}

const classifyCadence = (medianInterval: number): RecurringCharge["cadence"] | undefined => {
  if (medianInterval >= 5 && medianInterval <= 9) return "weekly"
  if (medianInterval >= 12 && medianInterval <= 17) return "fortnightly"
  if (medianInterval >= 26 && medianInterval <= 35) return "monthly"
  if (medianInterval >= 85 && medianInterval <= 100) return "quarterly"
  return undefined
}

const normalizeDescription = (description: string): string =>
  description
    .replace(/\d+/g, "")
    .replace(/[^a-zA-Z\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
