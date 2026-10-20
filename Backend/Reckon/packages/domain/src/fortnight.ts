// The Fortnight — the ambient pay-cycle lens (concept §4). Always-live and
// scrubbable: the cycle is derived from the dominant fortnightly income
// cluster, never configured, never generated or delivered. Pure helpers here;
// the Postgres adapter composes them with the mirror.

import { BigDecimal, Schema } from "effect"
import {
  type Forecast,
  ForecastRisk,
  type RecurringCharge,
  type Transaction,
} from "./BankData.js"
import { addDays } from "./derivations.js"
import {
  deriveReceipts,
  type FlagKey,
  FlagReceipt,
  type FlagSighting,
  sightingStats,
} from "./flags.js"

const ZERO = BigDecimal.fromNumberUnsafe(0)
const round2 = (n: BigDecimal.BigDecimal): BigDecimal.BigDecimal =>
  BigDecimal.round(n, { scale: 2, mode: "half-from-zero" })

export const PayCycle = Schema.Struct({
  cycleStart: Schema.String.annotate({
    description: "First day of the cycle — the payday (YYYY-MM-DD).",
  }),
  nextPayday: Schema.String.annotate({
    description: "Exclusive end of the cycle — the next payday (YYYY-MM-DD).",
  }),
  anchorMerchant: Schema.String.annotate({
    description: "Income cluster the cycle is anchored to.",
  }),
})
export type PayCycle = typeof PayCycle.Type

// Anchor to the dominant fortnightly income cluster (largest average-amount
// magnitude — income clusters arrive sign-flipped from detection, so compare
// absolutes). Roll forward from the last observed payday to the first payday
// strictly after today; offset ≤ 0 scrubs whole cycles back. Positive offsets
// are clamped to 0 — a future cycle is nonsense data.
export const derivePayCycle = (
  income: ReadonlyArray<RecurringCharge>,
  today: string,
  offset = 0,
): PayCycle | undefined => {
  offset = Math.min(0, offset)
  const fortnightly = income.filter((c) => c.cadence === "fortnightly")
  if (fortnightly.length === 0) return undefined
  const anchor = fortnightly.reduce((best, c) =>
    BigDecimal.isGreaterThan(
      BigDecimal.abs(c.averageAmount),
      BigDecimal.abs(best.averageAmount),
    )
      ? c
      : best,
  )
  let nextPayday = addDays(anchor.lastDate, 14)
  while (nextPayday <= today) nextPayday = addDays(nextPayday, 14)
  nextPayday = addDays(nextPayday, offset * 14)
  return {
    cycleStart: addDays(nextPayday, -14),
    nextPayday,
    anchorMerchant: anchor.merchant,
  }
}

export const FortnightPoint = Schema.Struct({
  date: Schema.String.annotate({ description: "Day (YYYY-MM-DD)." }),
  balance: Schema.BigDecimalFromString.annotate({
    description: "Liquid balance at end of day — real or projected.",
  }),
  projected: Schema.Boolean.annotate({
    description: "True for forecast points past today.",
  }),
})
export type FortnightPoint = typeof FortnightPoint.Type

export const Fortnight = Schema.Struct({
  cycleStart: Schema.String,
  nextPayday: Schema.String,
  offset: Schema.Int.annotate({
    description: "0 = current cycle, -1 = previous, …",
  }),
  anchorMerchant: Schema.String,
  netSoFar: Schema.BigDecimalFromString.annotate({
    description:
      "Net cashflow (transfers excluded) from cycle start through today, or the whole cycle when scrubbed back.",
  }),
  points: Schema.Array(FortnightPoint).annotate({
    description: "Daily balance trajectory — history, then forecast to payday.",
  }),
  flagsOpened: Schema.optional(
    Schema.Int.annotate({
      description: "Flags first sighted this cycle. Absent before logging began.",
    }),
  ),
  flagsResolved: Schema.optional(
    Schema.Int.annotate({
      description:
        "Flags last sighted this cycle and no longer detected. Absent before logging began.",
    }),
  ),
  receipts: Schema.Array(FlagReceipt).annotate({
    description:
      "Resolution receipts for this cycle — flags the data confirmed gone, speaking through their last snapshot. Empty for cycles before snapshots existed.",
  }),
  risks: Schema.Array(ForecastRisk).annotate({
    description: "Risk dates before the next payday (current cycle only).",
  }),
})
export type Fortnight = typeof Fortnight.Type

// Daily end-of-day balances reconstructed backwards from the current balance:
// balance(d) = current − Σ amounts of transactions dated after d. The
// transaction window must cover [from, today] for this to hold.
export const walkBalanceHistory = (input: {
  readonly transactions: ReadonlyArray<Transaction>
  readonly currentBalance: BigDecimal.BigDecimal
  readonly from: string
  readonly to: string
}): ReadonlyArray<FortnightPoint> => {
  const points: Array<FortnightPoint> = []
  for (let d = input.from; d <= input.to; d = addDays(d, 1)) {
    const afterDay = input.transactions.reduce(
      (acc, t) => (t.date.slice(0, 10) > d ? BigDecimal.sum(acc, t.amount) : acc),
      ZERO,
    )
    points.push({
      date: d,
      balance: round2(BigDecimal.subtract(input.currentBalance, afterDay)),
      projected: false,
    })
  }
  return points
}

// Assemble the lens. `transactions` must be liquid-NZD-account rows covering
// [cycleStart, today]; `netTransactions` the same but transfer-filtered (net
// excludes transfers by convention; the balance walk must NOT — transfers move
// real balance). `forecast` only for the current cycle.
export const buildFortnight = (input: {
  readonly cycle: PayCycle
  readonly offset: number
  readonly today: string
  readonly transactions: ReadonlyArray<Transaction>
  readonly netTransactions: ReadonlyArray<Transaction>
  readonly currentLiquidBalance: BigDecimal.BigDecimal
  readonly forecast?: Forecast | undefined
  readonly sightings: ReadonlyArray<FlagSighting>
  readonly detectedKeys: ReadonlyArray<FlagKey>
  readonly expectedImpactByKey?: ReadonlyMap<string, BigDecimal.BigDecimal>
}): Fortnight => {
  const { anchorMerchant, cycleStart, nextPayday } = input.cycle
  const lastRealDay =
    nextPayday <= input.today ? addDays(nextPayday, -1) : input.today
  const netSoFar = round2(
    input.netTransactions.reduce((acc, t) => {
      const d = t.date.slice(0, 10)
      return d >= cycleStart && d <= lastRealDay
        ? BigDecimal.sum(acc, t.amount)
        : acc
    }, ZERO),
  )
  const history = walkBalanceHistory({
    transactions: input.transactions,
    currentBalance: input.currentLiquidBalance,
    from: cycleStart,
    to: lastRealDay,
  })
  const projected =
    input.forecast === undefined
      ? []
      : input.forecast.points
          .filter((p) => p.date > input.today && p.date < nextPayday)
          .map((p) => ({
            date: p.date,
            balance: p.projectedBalance,
            projected: true,
          }))
  const stats = sightingStats(
    input.sightings,
    input.detectedKeys,
    cycleStart,
    nextPayday,
  )
  const receipts = deriveReceipts(
    input.sightings,
    input.detectedKeys,
    cycleStart,
    nextPayday,
    input.expectedImpactByKey,
  )
  const risks =
    input.forecast === undefined
      ? []
      : input.forecast.risks.filter((r) => r.date < nextPayday)
  return {
    cycleStart,
    nextPayday,
    offset: input.offset,
    anchorMerchant,
    netSoFar,
    points: [...history, ...projected],
    ...(stats === undefined
      ? {}
      : { flagsOpened: stats.opened, flagsResolved: stats.resolved }),
    receipts,
    risks,
  }
}
