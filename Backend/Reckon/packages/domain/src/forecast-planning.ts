import { BigDecimal, Data, Option, Result } from 'effect'
import type { Account, Forecast, ForecastPoint } from './BankData.js'
import {
  type BillFundingPlan,
  type BillReserve,
  billReserveOnDate,
  planBillFunding,
} from './bill-reserves.js'

const ZERO = BigDecimal.fromNumberUnsafe(0)

/** Invalid forecast assumptions are reported against the editable field. */
export class ForecastPlanningError extends Data.TaggedError(
  'ForecastPlanningError',
)<{
  readonly field:
    | 'dailySpending'
    | 'buffer'
    | 'amount'
    | 'date'
    | 'weeklyReduction'
  readonly message: string
}> {}

/** Planning inputs use NZD decimal strings; a blank daily allowance means unknown. */
export interface ForecastPlanningInput {
  readonly dailySpending: string
  readonly buffer: string
  readonly purchase?: { readonly amount: string; readonly date: string }
  readonly endsBefore?: string
  readonly startsOn?: string
  readonly bills?: ReadonlyArray<BillReserve>
  readonly nextPayday?: string
  readonly weeklyReduction?: string
}

/** Daily liquid balances retain protected savings; headroom subtracts the reserve separately. */
export interface ForecastPosition {
  readonly points: ReadonlyArray<ForecastPoint>
  readonly lowest: ForecastPoint
  readonly ending: ForecastPoint
  readonly firstRisk: ForecastPoint | undefined
  readonly firstReserveBreach: ForecastPoint | undefined
  readonly headroom: BigDecimal.BigDecimal
}

/** Decision comparisons use the same allowances and dated reserves on both trajectories. */
export interface ForecastPlan {
  readonly baseline: ForecastPosition
  readonly scenario: ForecastPosition | undefined
  readonly protectedSavings: BigDecimal.BigDecimal
  readonly buffer: BigDecimal.BigDecimal
  readonly reserve: BigDecimal.BigDecimal
  readonly dailySpending: BigDecimal.BigDecimal | undefined
  readonly reservePoints: ReadonlyArray<ForecastPoint>
  readonly billFunding: ReadonlyArray<BillFundingPlan>
  readonly weeklyReduction: BigDecimal.BigDecimal
}

function parsePlanningAmount(
  value: string,
  field: ForecastPlanningError['field'],
): Result.Result<BigDecimal.BigDecimal, ForecastPlanningError> {
  const text = value.trim()
  const amount = /^\d{1,9}(\.\d{1,2})?$/.test(text)
    ? BigDecimal.fromString(text)
    : Option.none()
  return Option.isSome(amount)
    ? Result.succeed(amount.value)
    : Result.fail(
        new ForecastPlanningError({
          field,
          message:
            'Enter an NZD amount of zero or more, with up to two decimal places.',
        }),
      )
}

function summarisePosition(
  points: ReadonlyArray<ForecastPoint>,
  reserveAt: (date: string) => BigDecimal.BigDecimal,
): ForecastPosition | undefined {
  const first = points[0]
  const ending = points.at(-1)
  if (!first || !ending) return undefined
  const lowest = points.reduce(
    (low, point) =>
      BigDecimal.isLessThan(point.projectedBalance, low.projectedBalance)
        ? point
        : low,
    first,
  )
  return {
    points,
    lowest,
    ending,
    firstRisk: points.find((point) =>
      BigDecimal.isLessThan(point.projectedBalance, ZERO),
    ),
    firstReserveBreach: points.find((point) =>
      BigDecimal.isLessThan(point.projectedBalance, reserveAt(point.date)),
    ),
    headroom: points.reduce(
      (room, point) =>
        BigDecimal.min(
          room,
          BigDecimal.subtract(point.projectedBalance, reserveAt(point.date)),
        ),
      BigDecimal.subtract(first.projectedBalance, reserveAt(first.date)),
    ),
  }
}

/** Parse forecast inputs and subtract one daily allowance per calendar day, including today. No writes. */
export function planForecastPosition(
  forecast: Forecast,
  accounts: ReadonlyArray<Account>,
  input: ForecastPlanningInput,
): Result.Result<ForecastPlan | undefined, ForecastPlanningError> {
  const buffer = parsePlanningAmount(input.buffer, 'buffer')
  if (Result.isFailure(buffer)) return Result.fail(buffer.failure)
  const allowance =
    input.dailySpending.trim() === ''
      ? Result.succeed(undefined)
      : parsePlanningAmount(input.dailySpending, 'dailySpending')
  if (Result.isFailure(allowance)) return Result.fail(allowance.failure)
  const weeklyReduction = parsePlanningAmount(
    input.weeklyReduction?.trim() || '0',
    'weeklyReduction',
  )
  if (Result.isFailure(weeklyReduction))
    return Result.fail(weeklyReduction.failure)
  if (
    BigDecimal.isGreaterThan(
      weeklyReduction.success,
      BigDecimal.multiply(
        allowance.success ?? ZERO,
        BigDecimal.fromNumberUnsafe(7),
      ),
    )
  ) {
    return Result.fail(
      new ForecastPlanningError({
        field: 'weeklyReduction',
        message:
          'Set an everyday allowance first. The weekly reduction cannot exceed seven days of that allowance.',
      }),
    )
  }
  const sourcePoints = forecast.points.filter(
    (point) =>
      point.date >= forecast.startDate &&
      (input.startsOn === undefined || point.date >= input.startsOn) &&
      point.date <= forecast.endDate &&
      (input.endsBefore === undefined || point.date < input.endsBefore),
  )
  const protectedSavings = BigDecimal.sumAll(
    accounts
      .filter(
        (account) =>
          account.currency === 'NZD' &&
          account.type === 'savings' &&
          BigDecimal.isGreaterThan(account.balance, ZERO),
      )
      .map((account) => account.balance),
  )
  const reserve = BigDecimal.sum(protectedSavings, buffer.success)
  const billFunding = (input.bills ?? []).map((bill) =>
    planBillFunding(bill, forecast.startDate, input.nextPayday),
  )
  const reserveAt = (date: string) =>
    BigDecimal.sum(
      reserve,
      BigDecimal.sumAll(
        billFunding.map((bill) => billReserveOnDate(bill, date)),
      ),
    )
  const points = sourcePoints.map((point) => {
    const days =
      Math.round(
        (Date.parse(point.date) - Date.parse(forecast.startDate)) / 86_400_000,
      ) + 1
    return {
      date: point.date,
      projectedBalance: BigDecimal.subtract(
        BigDecimal.subtract(
          point.projectedBalance,
          BigDecimal.sumAll(
            billFunding
              .filter(
                ({ bill, overdue }) =>
                  !overdue &&
                  bill.payment === 'additional' &&
                  bill.dueDate <= point.date,
              )
              .map(({ bill }) => BigDecimal.fromStringUnsafe(bill.amount)),
          ),
        ),
        BigDecimal.multiply(
          allowance.success ?? ZERO,
          BigDecimal.fromNumberUnsafe(days),
        ),
      ),
    }
  })
  const baseline = summarisePosition(points, reserveAt)
  if (!baseline) return Result.succeed(undefined)
  let scenarioPoints = points.map((point) => ({
    ...point,
    projectedBalance: BigDecimal.sum(
      point.projectedBalance,
      BigDecimal.divideUnsafe(
        BigDecimal.multiply(
          weeklyReduction.success,
          BigDecimal.fromNumberUnsafe(
            Math.round(
              (Date.parse(point.date) - Date.parse(forecast.startDate)) /
                86_400_000,
            ) + 1,
          ),
        ),
        BigDecimal.fromNumberUnsafe(7),
      ),
    ),
  }))
  if (input.purchase) {
    const purchase = input.purchase
    const amount = parsePlanningAmount(purchase.amount, 'amount')
    if (Result.isFailure(amount)) return Result.fail(amount.failure)
    if (!BigDecimal.isGreaterThan(amount.success, ZERO)) {
      return Result.fail(
        new ForecastPlanningError({
          field: 'amount',
          message: 'Enter a purchase amount greater than zero.',
        }),
      )
    }
    if (!points.some((point) => point.date === purchase.date)) {
      return Result.fail(
        new ForecastPlanningError({
          field: 'date',
          message: 'Choose a purchase date inside this projection.',
        }),
      )
    }
    scenarioPoints = scenarioPoints.map((point) => ({
      date: point.date,
      projectedBalance:
        point.date >= purchase.date
          ? BigDecimal.subtract(point.projectedBalance, amount.success)
          : point.projectedBalance,
    }))
  }
  return Result.succeed({
    baseline,
    scenario:
      input.purchase || BigDecimal.isGreaterThan(weeklyReduction.success, ZERO)
        ? summarisePosition(scenarioPoints, reserveAt)
        : undefined,
    protectedSavings,
    buffer: buffer.success,
    reserve,
    dailySpending: allowance.success,
    reservePoints: points.map((point) => ({
      date: point.date,
      projectedBalance: reserveAt(point.date),
    })),
    billFunding,
    weeklyReduction: weeklyReduction.success,
  })
}
