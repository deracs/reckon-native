// Pure derivation helpers — operate on already-fetched transactions so
// that any BankData implementation can reuse them. No Effect runtime,
// no I/O.

import { BigDecimal } from "effect"
import { categoryNameKey, isUncategorised } from "./Categorisation.js"
import type {
  BudgetConfig,
  BudgetStatus,
  CategoryRule,
  ChallengeConfig,
  ChallengeStatus,
  Forecast,
  ForecastEvent,
  ForecastPoint,
  ForecastRisk,
  FoundMoneyBucket,
  FoundMoneySummary,
  GoalConfig,
  GoalStatus,
  MerchantSummary,
  MonthlyCashflow,
  RecurringCharge,
  RoundUpSummary,
  RoundUpUnit,
  ScheduledTransaction,
  SpendingByCategory,
  Transaction,
  TransactionId,
  TransactionOverride,
  TransferPair,
  UnusualTransaction,
} from "./BankData.js"

const ZERO = BigDecimal.fromNumberUnsafe(0)
const ONE = BigDecimal.fromNumberUnsafe(1)
const HUNDRED = BigDecimal.fromNumberUnsafe(100)

const bd = BigDecimal.fromNumberUnsafe
const toNum = BigDecimal.toNumberUnsafe
const round2 = (n: BigDecimal.BigDecimal): BigDecimal.BigDecimal =>
  BigDecimal.round(n, { scale: 2, mode: "half-from-zero" })

export const detectTransferIds = (
  transactions: ReadonlyArray<Transaction>,
): ReadonlySet<TransactionId> => {
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
    for (let i = 0; i < sorted.length; i++) {
      const a = sorted[i]
      if (transferIds.has(a.id)) continue
      for (let j = i + 1; j < sorted.length; j++) {
        const b = sorted[j]
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

// Apply user-defined category rules at read time. Highest-priority
// enabled rule whose lowercased pattern appears in
// `${merchant} ${description}` wins. Source rows are never touched —
// reverting a rule just removes it.
export const applyCategoryRules = (
  transactions: ReadonlyArray<Transaction>,
  rules: ReadonlyArray<CategoryRule>,
): ReadonlyArray<Transaction> => {
  const active = rules
    .filter((rule) => rule.enabled && rule.pattern.length > 0)
    .sort((a, b) => Number(Boolean(a.missingOnly)) - Number(Boolean(b.missingOnly)) || b.priority - a.priority || a.id.localeCompare(b.id))
  if (active.length === 0) return transactions
  const transfers = active.some((rule) => rule.excludeTransfers) ? detectTransferIds(transactions) : new Set<TransactionId>()
  return transactions.map((tx) => {
    const match = active.find((rule) => categoryRuleMatches(tx, rule) && (!rule.excludeTransfers || !transfers.has(tx.id)))
    return match ? { ...tx, category: match.category } : tx
  })
}

export const categoryRuleMatches = (tx: Transaction, rule: CategoryRule): boolean => {
  if (!rule.enabled || !rule.pattern || (rule.missingOnly && !isUncategorised(tx.category))) return false
  if (rule.excludedTransactionIds?.includes(tx.id)) return false
  if (rule.currency && rule.currency !== tx.currency) return false
  if (rule.direction === "debit" && BigDecimal.sign(tx.amount) >= 0) return false
  if (rule.direction === "credit" && BigDecimal.sign(tx.amount) <= 0) return false
  const patterns = rule.matchPatterns?.length ? rule.matchPatterns : [rule.pattern]
  if (rule.matchKind === "merchant") return patterns.some((pattern) => categoryNameKey(tx.merchant ?? "") === categoryNameKey(pattern))
  if (rule.matchKind === "description") return patterns.some((pattern) => categoryNameKey(tx.description) === categoryNameKey(pattern))
  return `${tx.merchant ?? ""} ${tx.description}`.toLowerCase().includes(rule.pattern.toLowerCase())
}

// Apply per-transaction overrides. Run AFTER applyCategoryRules so a
// "just this one" override always wins over a pattern-derived rule —
// the user said exactly what they meant for this specific row.
export const applyTransactionOverrides = (
  transactions: ReadonlyArray<Transaction>,
  overrides: ReadonlyArray<TransactionOverride>,
): ReadonlyArray<Transaction> => {
  if (overrides.length === 0) return transactions
  const byId = new Map(overrides.map((o) => [o.transactionId, o.category]))
  if (byId.size === 0) return transactions
  return transactions.map((tx) => {
    const override = byId.get(tx.id)
    return override !== undefined ? { ...tx, category: override } : tx
  })
}

// Count how many transactions in a window match a candidate pattern —
// powers the "X matches" preview when adding/editing a rule.
export const countCategoryRuleMatches = (
  transactions: ReadonlyArray<Pick<Transaction, "description" | "merchant">>,
  pattern: string,
): number => {
  if (pattern.length === 0) return 0
  const needle = pattern.toLowerCase()
  let count = 0
  for (const tx of transactions) {
    const haystack = `${tx.merchant ?? ""} ${tx.description}`.toLowerCase()
    if (haystack.includes(needle)) count += 1
  }
  return count
}

export const filterTransfers = (
  transactions: ReadonlyArray<Transaction>,
  excludeTransfers: boolean | undefined,
): ReadonlyArray<Transaction> => {
  if (!excludeTransfers) return transactions
  const ids = detectTransferIds(transactions)
  return transactions.filter((tx) => !ids.has(tx.id))
}

// Same heuristic as `detectTransferIds` but returns the pair metadata
// (which side is outgoing, account ids, amount, date) so the UI can
// badge rows and an inspector can describe the matched leg.
export const detectTransferPairs = (
  transactions: ReadonlyArray<Transaction>,
): ReadonlyArray<TransferPair> => {
  const pairs: Array<TransferPair> = []
  const used = new Set<TransactionId>()
  const byAmount = new Map<string, Array<Transaction>>()
  for (const tx of transactions) {
    if (BigDecimal.isZero(tx.amount)) continue
    const key = BigDecimal.format(BigDecimal.abs(tx.amount))
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
    for (let i = 0; i < sorted.length; i++) {
      const a = sorted[i]
      if (used.has(a.id)) continue
      for (let j = i + 1; j < sorted.length; j++) {
        const b = sorted[j]
        if (used.has(b.id)) continue
        if (Math.abs(daysBetween(a.date, b.date)) > 3) break
        if (a.accountId === b.accountId) continue
        if (BigDecimal.sign(a.amount) === BigDecimal.sign(b.amount)) continue
        const outgoing = BigDecimal.isNegative(a.amount) ? a : b
        const incoming = outgoing === a ? b : a
        const date = a.date <= b.date ? a.date : b.date
        pairs.push({
          fromId: outgoing.id,
          toId: incoming.id,
          fromAccountId: outgoing.accountId,
          toAccountId: incoming.accountId,
          amount: BigDecimal.abs(a.amount),
          date,
        })
        used.add(a.id)
        used.add(b.id)
        break
      }
    }
  }
  return pairs
}

export const summarizeSpendingByCategory = (
  transactions: ReadonlyArray<Transaction>,
): ReadonlyArray<SpendingByCategory> => {
  const byCategory = new Map<
    string,
    { spent: BigDecimal.BigDecimal; count: number }
  >()
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

// Round-up math runs in cents so we never have to reach for BigDecimal
// remainder. Personal-bank scale (<10^12 cents) fits in a Number safely.
export const computeRoundUps = (
  transactions: ReadonlyArray<Transaction>,
  options: { readonly unit: RoundUpUnit; readonly merchantLimit?: number },
): RoundUpSummary => {
  const unit = options.unit
  const unitCents = unit * 100
  const merchantLimit = options.merchantLimit ?? 10

  let totalCents = 0
  let count = 0
  const monthCents = new Map<string, { saved: number; count: number }>()
  const dayCents = new Map<string, { saved: number; count: number }>()
  const merchantCents = new Map<string, { saved: number; count: number }>()

  for (const tx of transactions) {
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) continue
    const cents = Math.round(toNum(BigDecimal.abs(tx.amount)) * 100)
    if (cents === 0) continue
    const mod = cents % unitCents
    const savings = mod === 0 ? 0 : unitCents - mod
    if (savings === 0) continue
    totalCents += savings
    count += 1
    const month = tx.date.slice(0, 7)
    const mBucket = monthCents.get(month) ?? { saved: 0, count: 0 }
    mBucket.saved += savings
    mBucket.count += 1
    monthCents.set(month, mBucket)
    const dBucket = dayCents.get(tx.date) ?? { saved: 0, count: 0 }
    dBucket.saved += savings
    dBucket.count += 1
    dayCents.set(tx.date, dBucket)
    const merchant = tx.merchant ?? tx.description
    const merBucket = merchantCents.get(merchant) ?? { saved: 0, count: 0 }
    merBucket.saved += savings
    merBucket.count += 1
    merchantCents.set(merchant, merBucket)
  }

  const fromCents = (c: number) => bd(c / 100)

  return {
    unit,
    totalSaved: fromCents(totalCents),
    transactionCount: count,
    byMonth: Array.from(monthCents.entries())
      .map(([month, b]) => ({
        month,
        saved: fromCents(b.saved),
        transactionCount: b.count,
      }))
      .sort((a, b) => a.month.localeCompare(b.month)),
    byDay: Array.from(dayCents.entries())
      .map(([date, b]) => ({
        date,
        saved: fromCents(b.saved),
        transactionCount: b.count,
      }))
      .sort((a, b) => a.date.localeCompare(b.date)),
    byMerchant: Array.from(merchantCents.entries())
      .sort(([, a], [, b]) => b.saved - a.saved)
      .slice(0, merchantLimit)
      .map(([merchant, b]) => ({
        merchant,
        saved: fromCents(b.saved),
        transactionCount: b.count,
      })),
  }
}

export const summarizeMonthlyCashflow = (
  transactions: ReadonlyArray<Transaction>,
): ReadonlyArray<MonthlyCashflow> => {
  const byMonth = new Map<
    string,
    { income: BigDecimal.BigDecimal; spending: BigDecimal.BigDecimal; count: number }
  >()
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
      current.spending = BigDecimal.sum(
        current.spending,
        BigDecimal.abs(tx.amount),
      )
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

export const detectRecurringCharges = (
  transactions: ReadonlyArray<Transaction>,
  options: { minOccurrences?: number } = {},
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
    const variance =
      amountsNum.reduce((acc, x) => acc + (x - avgNum) ** 2, 0) /
      amountsNum.length
    const stddev = Math.sqrt(variance)
    if (stddev / avgNum > 0.25) continue
    const sorted = [...bucket].sort((a, b) => a.date.localeCompare(b.date))
    const intervals: Array<number> = []
    for (let i = 1; i < sorted.length; i++) {
      intervals.push(daysBetween(sorted[i - 1].date, sorted[i].date))
    }
    const cadence = classifyCadence(median(intervals))
    if (cadence === undefined) continue
    results.push({
      merchant: sorted[0].merchant ?? sorted[0].description,
      category: sorted[0].category,
      cadence,
      occurrences: sorted.length,
      averageAmount: round2(average),
      minAmount: round2(amounts.reduce((a, b) => BigDecimal.min(a, b))),
      maxAmount: round2(amounts.reduce((a, b) => BigDecimal.max(a, b))),
      totalSpent: round2(total),
      firstDate: sorted[0].date,
      lastDate: sorted[sorted.length - 1].date,
      lastAmount: round2(BigDecimal.abs(sorted[sorted.length - 1].amount)),
    })
  }
  return results.sort((a, b) =>
    toNum(BigDecimal.subtract(b.totalSpent, a.totalSpent)),
  )
}

export const findUnusualTransactions = (
  transactions: ReadonlyArray<Transaction>,
  options: { threshold?: number; minBaseline?: number } = {},
): ReadonlyArray<UnusualTransaction> => {
  const threshold = Math.max(options.threshold ?? 3, 1.1)
  const minBaseline = Math.max(options.minBaseline ?? 5, 2)
  const byCategory = new Map<string, Array<Transaction>>()
  for (const tx of transactions) {
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) continue
    const category = tx.category ?? "uncategorized"
    let bucket = byCategory.get(category)
    if (!bucket) {
      bucket = []
      byCategory.set(category, bucket)
    }
    bucket.push(tx)
  }
  const results: Array<UnusualTransaction> = []
  for (const [category, bucket] of byCategory) {
    if (bucket.length < minBaseline) continue
    const amounts = bucket.map((tx) => BigDecimal.abs(tx.amount))
    const baseline = medianBD(amounts)
    if (BigDecimal.isZero(baseline)) continue
    for (const tx of bucket) {
      const absAmount = BigDecimal.abs(tx.amount)
      const ratio = toNum(BigDecimal.divideUnsafe(absAmount, baseline))
      if (ratio >= threshold) {
        results.push({
          transaction: tx,
          category,
          baselineMedian: round2(baseline),
          ratio: Math.round(ratio * 100) / 100,
        })
      }
    }
  }
  return results.sort((a, b) => b.ratio - a.ratio)
}

export const summarizeTopMerchants = (
  transactions: ReadonlyArray<Transaction>,
  options: { limit?: number; direction?: "spending" | "income" } = {},
): ReadonlyArray<MerchantSummary> => {
  const limit = Math.min(Math.max(options.limit ?? 10, 1), 100)
  const direction = options.direction ?? "spending"
  const byMerchant = new Map<
    string,
    {
      amount: BigDecimal.BigDecimal
      count: number
      category: string | undefined
    }
  >()
  for (const tx of transactions) {
    if (
      direction === "spending" &&
      BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)
    )
      continue
    if (direction === "income" && BigDecimal.isLessThan(tx.amount, ZERO)) continue
    const key = tx.merchant ?? tx.description
    let current = byMerchant.get(key)
    if (!current) {
      current = { amount: ZERO, count: 0, category: tx.category }
      byMerchant.set(key, current)
    }
    current.amount = BigDecimal.sum(current.amount, BigDecimal.abs(tx.amount))
    current.count += 1
    if (!current.category) current.category = tx.category
  }
  return Array.from(byMerchant.entries())
    .map(([merchant, m]) => ({
      merchant,
      category: m.category,
      amount: round2(m.amount),
      transactionCount: m.count,
      averageAmount: round2(
        BigDecimal.divideUnsafe(m.amount, BigDecimal.fromNumberUnsafe(m.count)),
      ),
    }))
    .sort((a, b) => toNum(BigDecimal.subtract(b.amount, a.amount)))
    .slice(0, limit)
}

export interface MonthWindow {
  readonly start: string
  readonly end: string
  readonly daysIn: number
  readonly daysInto: number
}

export const monthWindowFor = (today: string, month?: string): MonthWindow => {
  const ym = month ?? today.slice(0, 7)
  const [yearStr, monthStr] = ym.split("-")
  const year = Number(yearStr)
  const mon = Number(monthStr)
  const daysIn = new Date(Date.UTC(year, mon, 0)).getUTCDate()
  const start = `${ym}-01`
  const end = `${ym}-${String(daysIn).padStart(2, "0")}`
  const daysInto = today >= start && today <= end
    ? daysBetween(start, today) + 1
    : today > end
      ? daysIn
      : 0
  return { start, end, daysIn, daysInto }
}

export const computeBudgetStatus = (
  transactions: ReadonlyArray<Transaction>,
  configs: ReadonlyArray<BudgetConfig>,
  today: string,
  month?: string,
): ReadonlyArray<BudgetStatus> => {
  const window = monthWindowFor(today, month)
  const inWindow = transactions.filter(
    (tx) => tx.date >= window.start && tx.date <= window.end,
  )
  const spendByCategory = new Map<string, BigDecimal.BigDecimal>()
  for (const tx of inWindow) {
    if (BigDecimal.isGreaterThanOrEqualTo(tx.amount, ZERO)) continue
    const category = tx.category ?? "uncategorized"
    const prev = spendByCategory.get(category) ?? ZERO
    spendByCategory.set(
      category,
      BigDecimal.sum(prev, BigDecimal.abs(tx.amount)),
    )
  }
  const pctElapsed = window.daysIn === 0 ? 0 : window.daysInto / window.daysIn
  const pctElapsedBD = bd(pctElapsed)
  return configs
    .map((config) => {
      const spent = round2(spendByCategory.get(config.category) ?? ZERO)
      const remaining = round2(BigDecimal.subtract(config.monthlyLimit, spent))
      const pctUsed = BigDecimal.isZero(config.monthlyLimit)
        ? 0
        : Math.round(
            toNum(
              BigDecimal.divideUnsafe(
                BigDecimal.multiply(spent, HUNDRED),
                config.monthlyLimit,
              ),
            ) * 100,
          ) / 100
      const projectedSpend =
        pctElapsed > 0
          ? round2(BigDecimal.divideUnsafe(spent, pctElapsedBD))
          : ZERO
      const projectedOverage = round2(
        BigDecimal.subtract(projectedSpend, config.monthlyLimit),
      )
      const limitTimes105 = BigDecimal.multiply(config.monthlyLimit, bd(1.05))
      const limitTimes90 = BigDecimal.multiply(config.monthlyLimit, bd(0.9))
      const status: BudgetStatus["status"] =
        BigDecimal.isGreaterThan(spent, config.monthlyLimit)
          ? "exceeded"
          : BigDecimal.isGreaterThan(projectedSpend, limitTimes105)
            ? "over"
            : BigDecimal.isLessThan(projectedSpend, limitTimes90)
              ? "under"
              : "on_pace"
      return {
        category: config.category,
        monthlyLimit: round2(config.monthlyLimit),
        spent,
        remaining,
        pctUsed,
        daysIntoPeriod: window.daysInto,
        daysInPeriod: window.daysIn,
        pctOfPeriodElapsed: Math.round(pctElapsed * 100 * 100) / 100,
        projectedSpend,
        projectedOverage,
        status,
      }
    })
    .sort((a, b) =>
      toNum(BigDecimal.subtract(b.projectedOverage, a.projectedOverage)),
    )
}

export const forecastCashflow = (options: {
  startingBalance: BigDecimal.BigDecimal
  today: string
  days: number
  recurring: ReadonlyArray<RecurringCharge>
  income: ReadonlyArray<RecurringCharge>
  scheduled?: ReadonlyArray<ScheduledTransaction>
}): Forecast => {
  const horizon = Math.max(1, Math.min(options.days, 365))
  const endDate = addDays(options.today, horizon)
  const events: Array<ForecastEvent> = []

  // Scheduled events run first — they're user-defined, so we want them
  // visible even when detection wouldn't have caught them. Detected
  // recurring/income are then suppressed for any merchant the user has
  // already scheduled (same lowercased description), so we don't
  // double-count rent or salary.
  const scheduledList = options.scheduled ?? []
  const suppressed = new Set<string>()
  for (const s of scheduledList) {
    if (s.enabled) suppressed.add(s.description.toLowerCase())
  }
  events.push(...expandScheduledEvents(scheduledList, options.today, endDate))

  for (const charge of options.recurring) {
    if (suppressed.has(charge.merchant.toLowerCase())) continue
    const dates = projectCadence(charge.lastDate, charge.cadence, options.today, endDate)
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
    if (suppressed.has(inflow.merchant.toLowerCase())) continue
    const dates = projectCadence(inflow.lastDate, inflow.cadence, options.today, endDate)
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
    while (pointer < events.length && events[pointer].date <= date) {
      const event = events[pointer]
      balance = BigDecimal.sum(balance, event.amount)
      if (BigDecimal.isGreaterThanOrEqualTo(event.amount, ZERO)) {
        totalIncome = BigDecimal.sum(totalIncome, event.amount)
      } else {
        totalSpending = BigDecimal.sum(totalSpending, BigDecimal.abs(event.amount))
      }
      pointer++
    }
    points.push({ date, projectedBalance: round2(balance) })
    if (
      BigDecimal.isLessThan(balance, ZERO) &&
      (risks.length === 0 || risks[risks.length - 1].date !== date)
    ) {
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

const MILESTONES = [100, 75, 50, 25] as const

const monthsBetween = (from: string, to: string): number => {
  const [fy, fm] = from.split("-").map(Number)
  const [ty, tm] = to.split("-").map(Number)
  return (ty - fy) * 12 + (tm - fm)
}

export const computeGoalStatus = (
  goal: GoalConfig,
  transactions: ReadonlyArray<Transaction>,
  today: string,
): GoalStatus => {
  const accounts = new Set<string>(goal.accountIds)
  const onAccounts = transactions.filter((tx) => accounts.has(tx.accountId))

  const saved = round2(
    onAccounts
      .filter((tx) => tx.date >= goal.startDate)
      .reduce((acc, tx) => BigDecimal.sum(acc, tx.amount), ZERO),
  )

  const windowStart = addMonths(today, -3)
  const trailingNet = onAccounts
    .filter((tx) => tx.date >= windowStart && tx.date < today)
    .reduce((acc, tx) => BigDecimal.sum(acc, tx.amount), ZERO)
  const saveRate = round2(BigDecimal.divideUnsafe(trailingNet, bd(3)))

  const remaining = BigDecimal.subtract(goal.targetAmount, saved)
  const pct = BigDecimal.isZero(goal.targetAmount)
    ? 0
    : Math.max(
        0,
        Math.min(
          100,
          Math.round(
            toNum(
              BigDecimal.divideUnsafe(
                BigDecimal.multiply(saved, bd(100)),
                goal.targetAmount,
              ),
            ) * 100,
          ) / 100,
        ),
      )

  const milestone = MILESTONES.find((m) => pct >= m) ?? 0

  const achieved = BigDecimal.isGreaterThanOrEqualTo(saved, goal.targetAmount)
  const positiveRate = BigDecimal.isGreaterThan(saveRate, ZERO)

  const etaDate =
    achieved || !positiveRate
      ? undefined
      : addMonths(
          today,
          Math.ceil(toNum(BigDecimal.divideUnsafe(remaining, saveRate))),
        )

  const requiredMonthly =
    goal.targetDate && !achieved
      ? round2(
          BigDecimal.divideUnsafe(
            remaining,
            bd(Math.max(1, monthsBetween(today, goal.targetDate))),
          ),
        )
      : undefined

  const status: GoalStatus["status"] = achieved
    ? "achieved"
    : !positiveRate
      ? "stalled"
      : goal.targetDate && etaDate
        ? etaDate <= goal.targetDate
          ? "ahead"
          : "behind"
        : "on_track"

  return {
    id: goal.id,
    name: goal.name,
    targetAmount: round2(goal.targetAmount),
    currency: goal.currency,
    saved,
    pct,
    saveRate,
    etaDate,
    requiredMonthly,
    milestone,
    status,
  }
}

// Dollar formatting for verdict copy: whole dollars when integral, else 2dp.
const money = (n: BigDecimal.BigDecimal): string => {
  const v = toNum(round2(n))
  return `$${Number.isInteger(v) ? v.toString() : v.toFixed(2)}`
}

export const scoreChallenge = (
  challenge: ChallengeConfig,
  transactions: ReadonlyArray<Transaction>,
  today: string,
): ChallengeStatus => {
  const ended = today >= challenge.endDate
  const to = ended ? challenge.endDate : today
  const inWindow = transactions.filter(
    (tx) => tx.date >= challenge.startDate && tx.date <= to,
  )

  const totalDays = Math.max(
    1,
    daysBetween(challenge.startDate, challenge.endDate),
  )
  const elapsedDays = Math.max(
    0,
    Math.min(totalDays, daysBetween(challenge.startDate, to)),
  )
  const pctElapsed = elapsedDays === 0 ? 0 : elapsedDays / totalDays

  let actual: BigDecimal.BigDecimal
  if (challenge.kind === "category_cap") {
    actual = round2(
      inWindow
        .filter(
          (tx) =>
            (tx.category ?? "uncategorized") === challenge.reference &&
            BigDecimal.isLessThan(tx.amount, ZERO),
        )
        .reduce(
          (acc, tx) => BigDecimal.sum(acc, BigDecimal.abs(tx.amount)),
          ZERO,
        ),
    )
  } else {
    const accounts = new Set<string>(challenge.accountIds)
    actual = round2(
      inWindow
        .filter((tx) => accounts.has(tx.accountId))
        .reduce((acc, tx) => BigDecimal.sum(acc, tx.amount), ZERO),
    )
  }

  const projected =
    ended || pctElapsed === 0
      ? undefined
      : round2(BigDecimal.divideUnsafe(actual, bd(pctElapsed)))

  let status: ChallengeStatus["status"]
  let verdict: string | undefined

  // Day-0 / no elapsed time: a cap reads on_track (safe until you spend);
  // a save-rate reads at_risk (nothing banked yet).
  if (challenge.kind === "category_cap") {
    if (ended || BigDecimal.isGreaterThan(actual, challenge.target)) {
      if (BigDecimal.isGreaterThan(actual, challenge.target)) {
        status = "lost"
        verdict = `Lost. ${money(actual)} on ${challenge.reference}, ${money(BigDecimal.subtract(actual, challenge.target))} over.`
      } else {
        status = "won"
        verdict = `Won. ${money(actual)} on ${challenge.reference}, ${money(
          BigDecimal.subtract(challenge.target, actual),
        )} under the ${money(challenge.target)} cap.`
      }
    } else {
      status =
        projected && BigDecimal.isGreaterThan(projected, challenge.target)
          ? "at_risk"
          : "on_track"
      verdict = undefined
    }
  } else {
    if (ended) {
      if (BigDecimal.isGreaterThanOrEqualTo(actual, challenge.target)) {
        status = "won"
        verdict = `Won. ${money(actual)} into savings, ${money(
          BigDecimal.subtract(actual, challenge.target),
        )} past the ${money(challenge.target)} target.`
      } else {
        status = "lost"
        verdict = `Lost. ${money(actual)} into savings, ${money(
          BigDecimal.subtract(challenge.target, actual),
        )} short of ${money(challenge.target)}.`
      }
    } else {
      status =
        projected &&
        BigDecimal.isGreaterThanOrEqualTo(projected, challenge.target)
          ? "on_track"
          : "at_risk"
      verdict = undefined
    }
  }

  return {
    id: challenge.id,
    kind: challenge.kind,
    name: challenge.name,
    target: round2(challenge.target),
    reference: challenge.reference,
    windowStart: challenge.startDate,
    windowEnd: challenge.endDate,
    actual,
    projected,
    status,
    verdict,
  }
}

const MONTHLY_FACTOR: Record<RecurringCharge["cadence"], number> = {
  weekly: 52 / 12,
  fortnightly: 26 / 12,
  monthly: 1,
  quarterly: 1 / 3,
}

export const summarizeFoundMoney = (inputs: {
  readonly roundUps: RoundUpSummary
  readonly budgetStatuses: ReadonlyArray<BudgetStatus>
  readonly recurringCharges: ReadonlyArray<RecurringCharge>
}): FoundMoneySummary => {
  const roundUpAmount = round2(inputs.roundUps.totalSaved)

  const headroom = round2(
    inputs.budgetStatuses.reduce(
      (acc, s) =>
        BigDecimal.isGreaterThan(s.remaining, ZERO)
          ? BigDecimal.sum(acc, s.remaining)
          : acc,
      ZERO,
    ),
  )

  const standingBurn = round2(
    inputs.recurringCharges.reduce(
      (acc, c) =>
        BigDecimal.sum(
          acc,
          BigDecimal.multiply(BigDecimal.abs(c.averageAmount), bd(MONTHLY_FACTOR[c.cadence])),
        ),
      ZERO,
    ),
  )

  const buckets: ReadonlyArray<FoundMoneyBucket> = [
    { kind: "round_ups", label: "Round-ups", amount: roundUpAmount, note: "Rounding every spend to the nearest dollar would set this aside." },
    { kind: "under_budget", label: "Under your caps", amount: headroom, note: "Headroom left under your category caps. Bank it before it drifts." },
    { kind: "standing_orders", label: "Standing orders", amount: standingBurn, note: "Monthly subscription burn. Not found money until you cancel something — audit it." },
  ]

  return { buckets, reclaimable: round2(BigDecimal.sum(roundUpAmount, headroom)) }
}

export const addDays = (date: string, days: number): string => {
  const dt = new Date(`${date}T00:00:00.000Z`)
  dt.setUTCDate(dt.getUTCDate() + days)
  return dt.toISOString().slice(0, 10)
}

// Shift an ISO date by N months (same day-of-month). Used for
// lookback windows where "6 months back" means calendar-months, not
// 6 × 30 days.
export const addMonths = (date: string, months: number): string => {
  const dt = new Date(`${date}T00:00:00.000Z`)
  dt.setUTCMonth(dt.getUTCMonth() + months)
  return dt.toISOString().slice(0, 10)
}

// First day of the month N months ago, in YYYY-MM-DD. `nMonthsAgo(today, 0)`
// returns the first of the current month.
export const firstOfMonthBack = (today: string, monthsBack: number): string => {
  const dt = new Date(`${today}T00:00:00.000Z`)
  dt.setUTCMonth(dt.getUTCMonth() - monthsBack, 1)
  return dt.toISOString().slice(0, 10)
}

// --- internals -------------------------------------------------------------

const cadenceDays = (cadence: RecurringCharge["cadence"]): number => {
  switch (cadence) {
    case "weekly":
      return 7
    case "fortnightly":
      return 14
    case "monthly":
      return 30
    case "quarterly":
      return 91
  }
}

const scheduleCadenceDays = (cadence: ScheduledTransaction["cadence"]): number => {
  switch (cadence) {
    case "weekly":
      return 7
    case "fortnightly":
      return 14
    case "monthly":
      return 30
    case "quarterly":
      return 91
    case "yearly":
      return 365
  }
}

// Expand a user-defined scheduled event forward from `nextDate` through
// `endDate`. Skips occurrences strictly before `today` — the forecast
// always starts "from now" so historical instances are already in the
// actuals window. Disabled events return [].
export const expandScheduledEvents = (
  scheduled: ReadonlyArray<ScheduledTransaction>,
  today: string,
  endDate: string,
): ReadonlyArray<ForecastEvent> => {
  const events: Array<ForecastEvent> = []
  for (const s of scheduled) {
    if (!s.enabled) continue
    const interval = scheduleCadenceDays(s.cadence)
    let cursor = s.nextDate
    // If nextDate is in the past, advance forward until it's >= today.
    while (cursor < today) cursor = addDays(cursor, interval)
    while (cursor <= endDate) {
      events.push({
        date: cursor,
        description: s.description,
        amount: s.amount,
        kind: BigDecimal.isGreaterThanOrEqualTo(s.amount, ZERO)
          ? "expected_income"
          : "recurring_charge",
      })
      cursor = addDays(cursor, interval)
    }
  }
  return events
}

const projectCadence = (
  lastDate: string,
  cadence: RecurringCharge["cadence"],
  from: string,
  to: string,
): ReadonlyArray<string> => {
  const interval = cadenceDays(cadence)
  const result: Array<string> = []
  let next = addDays(lastDate, interval)
  while (next <= to) {
    if (next >= from) result.push(next)
    next = addDays(next, interval)
  }
  return result
}

const daysBetween = (a: string, b: string): number => {
  const da = Date.UTC(
    Number(a.slice(0, 4)),
    Number(a.slice(5, 7)) - 1,
    Number(a.slice(8, 10)),
  )
  const db = Date.UTC(
    Number(b.slice(0, 4)),
    Number(b.slice(5, 7)) - 1,
    Number(b.slice(8, 10)),
  )
  return Math.round((db - da) / 86400000)
}

const median = (values: ReadonlyArray<number>): number => {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

const medianBD = (
  values: ReadonlyArray<BigDecimal.BigDecimal>,
): BigDecimal.BigDecimal => {
  if (values.length === 0) return ZERO
  const sorted = [...values].sort((a, b) =>
    toNum(BigDecimal.subtract(a, b)),
  )
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1
    ? sorted[mid]
    : BigDecimal.divideUnsafe(
        BigDecimal.sum(sorted[mid - 1], sorted[mid]),
        BigDecimal.fromNumberUnsafe(2),
      )
}

const classifyCadence = (
  medianInterval: number,
): RecurringCharge["cadence"] | undefined => {
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
