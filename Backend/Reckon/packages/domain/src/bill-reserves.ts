import { BigDecimal, Schema } from 'effect'
import { addDays } from './derivations.js'
import type { ForecastEvent } from './BankData.js'

const ZERO = BigDecimal.fromNumberUnsafe(0)
const moneyText = Schema.String.check(Schema.isPattern(/^\d{1,9}(\.\d{1,2})?$/))
const billDate = Schema.String.check(
  Schema.makeFilter(
    (value) =>
      /^\d{4}-\d{2}-\d{2}$/.test(value) &&
      Number.isFinite(Date.parse(value)) &&
      new Date(value).toISOString().slice(0, 10) === value,
  ),
)

/** A bill reserve identifies a planning entry, never a bank transaction. */
export const BillReserveId = Schema.NonEmptyString.pipe(
  Schema.brand('BillReserveId'),
)

/** Bill money is NZD held in checking; savings balances are protected separately. */
export const BillReserve = Schema.Struct({
  id: BillReserveId,
  name: Schema.NonEmptyString.check(Schema.isMaxLength(100)),
  amount: moneyText,
  setAside: moneyText,
  dueDate: billDate,
  payment: Schema.Literals(['additional', 'in-forecast']),
}).check(
  Schema.makeFilter((bill) => {
    const amount = BigDecimal.fromStringUnsafe(bill.amount)
    return (
      BigDecimal.isGreaterThan(amount, ZERO) &&
      BigDecimal.isLessThanOrEqualTo(
        BigDecimal.fromStringUnsafe(bill.setAside),
        amount,
      )
    )
  }),
)

/** Validated irregular bill amounts use exact NZD decimal strings. */
export interface BillReserve extends Schema.Schema.Type<typeof BillReserve> {}

/** Additional bill payments appear once; entries already in the forecast are excluded. */
export function billPaymentEvents(bills: ReadonlyArray<BillReserve>, window: { readonly from: string; readonly to: string }): ReadonlyArray<Pick<ForecastEvent, 'date' | 'description' | 'amount'> & { readonly kind: 'planned_bill' }> {
  return bills.filter((bill) => bill.payment === 'additional' && bill.dueDate >= window.from && bill.dueDate <= window.to)
    .map((bill) => ({ date: bill.dueDate, description: bill.name, amount: BigDecimal.negate(BigDecimal.fromStringUnsafe(bill.amount)), kind: 'planned_bill' }))
}

/** Funding dates are assumptions; contributions earmark liquid money and never move it. */
export interface BillFundingPlan {
  readonly bill: BillReserve
  readonly contribution: BigDecimal.BigDecimal
  readonly fundingDates: ReadonlyArray<string>
  readonly overdue: boolean
}

/** Divide the unfunded bill over this cycle and fortnightly paydays strictly before it is due. */
export function planBillFunding(
  bill: BillReserve,
  today: string,
  nextPayday?: string,
): BillFundingPlan {
  const fundingDates = [today]
  if (nextPayday && nextPayday > today) {
    for (let date = nextPayday; date < bill.dueDate; date = addDays(date, 14)) {
      fundingDates.push(date)
    }
  }
  const remaining = BigDecimal.subtract(
    BigDecimal.fromStringUnsafe(bill.amount),
    BigDecimal.fromStringUnsafe(bill.setAside),
  )
  return {
    bill,
    fundingDates,
    contribution: BigDecimal.round(
      BigDecimal.divideUnsafe(
        remaining,
        BigDecimal.fromNumberUnsafe(fundingDates.length),
      ),
      { scale: 2, mode: 'ceil' },
    ),
    overdue: bill.dueDate < today,
  }
}

/** Release a bill reserve on its due date; overdue entries remain protected until reviewed. */
export function billReserveOnDate(
  plan: BillFundingPlan,
  date: string,
): BigDecimal.BigDecimal {
  if (!plan.overdue && date >= plan.bill.dueDate) return ZERO
  const amount = BigDecimal.fromStringUnsafe(plan.bill.amount)
  if (plan.overdue) return amount
  return BigDecimal.min(
    amount,
    BigDecimal.sum(
      BigDecimal.fromStringUnsafe(plan.bill.setAside),
      BigDecimal.multiply(
        plan.contribution,
        BigDecimal.fromNumberUnsafe(
          plan.fundingDates.filter((day) => day <= date).length,
        ),
      ),
    ),
  )
}
