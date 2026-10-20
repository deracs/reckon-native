import { BigDecimal } from 'effect'
import type { GoalStatus, Transaction } from './BankData.js'
import { addDays } from './derivations.js'
import type { LedgerEntry } from './flags.js'

const ZERO = BigDecimal.fromNumberUnsafe(0)

/** Merchant comparisons use two complete 30-day windows, excluding transfers before this boundary. */
export interface SavingsComparison {
  readonly merchant: string
  readonly beforeFrom: string
  readonly beforeTo: string
  readonly afterFrom: string
  readonly afterTo: string
  readonly before: BigDecimal.BigDecimal
  readonly after: BigDecimal.BigDecimal
  readonly reduction: BigDecimal.BigDecimal
}

/** A lower merchant outflow is an observation, not proof of causation or a savings deposit. */
export function compareSavingsOutflows(
  entry: LedgerEntry,
  transactions: ReadonlyArray<Transaction>,
  options: {
    readonly asOf: string
    readonly coverageFrom: string
  },
): SavingsComparison | undefined {
  if (
    entry.type !== 'standing_order_hike' &&
    entry.type !== 'new_standing_order'
  )
    return undefined
  const prefix = `${entry.type}:`
  if (!entry.key.startsWith(prefix)) return undefined
  const merchant = entry.key.slice(prefix.length)
  const beforeFrom = addDays(entry.resolvedOn, -29)
  const beforeTo = entry.resolvedOn
  const afterFrom = addDays(entry.resolvedOn, 1)
  const afterTo = addDays(entry.resolvedOn, 30)
  if (!merchant || beforeFrom < options.coverageFrom || afterTo >= options.asOf)
    return undefined
  const matching = transactions.filter(
    (transaction) =>
      transaction.currency === entry.currency &&
      transaction.merchant?.toLowerCase() === merchant &&
      BigDecimal.isNegative(transaction.amount),
  )
  const spent = (from: string, to: string) =>
    BigDecimal.sumAll(
      matching
        .filter(
          (transaction) => transaction.date >= from && transaction.date <= to,
        )
        .map((transaction) => BigDecimal.abs(transaction.amount)),
    )
  const before = spent(beforeFrom, beforeTo)
  if (!BigDecimal.isGreaterThan(before, ZERO)) return undefined
  const after = spent(afterFrom, afterTo)
  return {
    merchant,
    beforeFrom,
    beforeTo,
    afterFrom,
    afterTo,
    before,
    after,
    reduction: BigDecimal.subtract(before, after),
  }
}

/** Goal scenarios apply the entire weekly reduction to one goal at its current monthly save rate. */
export function estimateGoalWithReduction(
  goal: GoalStatus,
  weeklyReduction: BigDecimal.BigDecimal,
  today: string,
): string | undefined {
  if (
    goal.currency !== 'NZD' ||
    !BigDecimal.isGreaterThan(weeklyReduction, ZERO)
  )
    return undefined
  const remaining = BigDecimal.max(
    ZERO,
    BigDecimal.subtract(goal.targetAmount, goal.saved),
  )
  const rate = BigDecimal.sum(
    goal.saveRate,
    BigDecimal.divideUnsafe(
      BigDecimal.multiply(weeklyReduction, BigDecimal.fromNumberUnsafe(52)),
      BigDecimal.fromNumberUnsafe(12),
    ),
  )
  if (!BigDecimal.isGreaterThan(rate, ZERO)) return undefined
  const days = Math.ceil(
    BigDecimal.toNumberUnsafe(
      BigDecimal.multiply(
        BigDecimal.divideUnsafe(remaining, rate),
        BigDecimal.fromNumberUnsafe(365 / 12),
      ),
    ),
  )
  return days <= 36500 ? addDays(today, days) : undefined
}
