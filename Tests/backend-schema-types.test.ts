import { AkahuTransactionCategory, AkahuMerchant } from "../Backend/Reckon/packages/akahu/src/wire.js"
import { Account, RecurringCharge } from "../Backend/Reckon/packages/domain/src/index.js"
import { Schema } from "effect"

const merchant = new AkahuMerchant({ name: "Fixture merchant" })
const categoryFields = { _id: "fixture-category", name: "Fixture category" }
const transactionCategory = new AkahuTransactionCategory(categoryFields)

// @ts-expect-error A transaction category has a name but is not a decoded merchant.
const invalidMerchant: AkahuMerchant = transactionCategory

// @ts-expect-error Wire classes must be constructed or decoded, not supplied as plain records.
const invalidTransactionCategory: AkahuTransactionCategory = categoryFields

const validMerchant: AkahuMerchant = merchant
void invalidMerchant
void invalidTransactionCategory
void validMerchant

const account = Schema.decodeSync(Account)({
  id: "acc_fixture",
  name: "Everyday",
  type: "checking",
  currency: "NZD",
  balance: "100",
})
const recurringCharge = Schema.decodeSync(RecurringCharge)({
  merchant: "Fixture bill",
  cadence: "weekly",
  occurrences: 3,
  averageAmount: "10",
  minAmount: "10",
  maxAmount: "10",
  totalSpent: "30",
  firstDate: "2026-10-01",
  lastDate: "2026-10-15",
})
const liquid: boolean = account.isLiquidNZD()
const dates: ReadonlyArray<string> = recurringCharge.projectDates("2026-10-21", "2026-11-21")
const accountFields = Schema.decodeSync(Schema.Struct(Account.fields))(Schema.encodeSync(Account)(account))
const recurringFields = Schema.decodeSync(Schema.Struct(RecurringCharge.fields))(
  Schema.encodeSync(RecurringCharge)(recurringCharge),
)

// @ts-expect-error Plain fields must be constructed or decoded to retain account behavior.
const invalidAccount: Account = accountFields

// @ts-expect-error Plain fields must be constructed or decoded to retain recurring-charge behavior.
const invalidRecurringCharge: RecurringCharge = recurringFields

void liquid
void dates
void invalidAccount
void invalidRecurringCharge
