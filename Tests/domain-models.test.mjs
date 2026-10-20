import assert from "node:assert/strict"
import { dirname, resolve } from "node:path"
import test from "node:test"
import { fileURLToPath, pathToFileURL } from "node:url"
import { build } from "esbuild"
import { Arbitrary, BigDecimal, Effect, Schema } from "effect"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const output = resolve(project, ".build/domain-tests/domain.mjs")
await build({
  entryPoints: [resolve(project, "Backend/Reckon/packages/domain/src/index.ts")],
  outfile: output,
  bundle: true,
  platform: "node",
  format: "esm",
  packages: "external",
})
const { Account, RecurringCharge, Transaction, detectRecurringCharges, forecastCashflow } = await import(
  pathToFileURL(output).href
)

const accountRecord = {
  id: "acc_fixture",
  name: "Everyday",
  type: "checking",
  currency: "NZD",
  balance: "-123.45",
  availableBalance: "456.78",
  creditLimit: "1000",
  accountNumber: "fixture-account",
  status: "active",
  bankName: "Fixture bank",
  bankLogo: "https://example.com/bank.png",
}
const recurringRecord = {
  merchant: "Fixture bill",
  category: "Utilities",
  cadence: "weekly",
  occurrences: 3,
  averageAmount: "25.5",
  minAmount: "25.5",
  maxAmount: "25.5",
  totalSpent: "76.5",
  firstDate: "2024-02-15",
  lastDate: "2024-02-29",
  lastAmount: "25.5",
}

test("only NZD checking and savings accounts are liquid, including overdrawn accounts", () => {
  for (const type of ["checking", "savings", "credit", "loan", "investment"]) {
    for (const currency of ["NZD", "USD", "AUD"]) {
      for (const balance of ["-100", "0", "100"]) {
        const account = Schema.decodeUnknownSync(Account)({ ...accountRecord, type, currency, balance })
        assert.equal(
          account.isLiquidNZD(),
          currency === "NZD" && ["checking", "savings"].includes(type),
          `${currency} ${type} with balance ${balance}`,
        )
      }
    }
  }
})

test("domain classes preserve their JSON records and regain behavior after decoding", () => {
  for (const [schema, record] of [
    [Account, accountRecord],
    [RecurringCharge, recurringRecord],
  ]) {
    const model = Schema.decodeUnknownSync(schema)(record)
    const json = JSON.stringify(Schema.encodeSync(schema)(model))
    assert.deepEqual(JSON.parse(json), record)
    const decoded = Schema.decodeUnknownSync(schema)(JSON.parse(json))
    assert(decoded instanceof schema)
    if (decoded instanceof Account) assert.equal(decoded.isLiquidNZD(), true)
    else assert.deepEqual(decoded.projectDates("2024-03-07", "2024-03-14"), ["2024-03-07", "2024-03-14"])
  }
})

test("recurring projections keep fixed-day cadences across leap days and year boundaries", () => {
  const cases = [
    ["weekly", "2024-02-22", "2024-02-29"],
    ["fortnightly", "2024-12-25", "2025-01-08"],
    ["monthly", "2024-01-31", "2024-03-01"],
    ["quarterly", "2024-01-31", "2024-05-01"],
  ]
  for (const [cadence, lastDate, nextDate] of cases) {
    const charge = Schema.decodeUnknownSync(RecurringCharge)({ ...recurringRecord, cadence, lastDate })
    assert.deepEqual(charge.projectDates(nextDate, nextDate), [nextDate])
    assert.deepEqual(charge.projectDates(lastDate, lastDate), [])
    assert.deepEqual(charge.projectDates(nextDate, lastDate), [])
  }
})

test("projected dates cover every cadence occurrence inside arbitrary inclusive windows", async () => {
  const cases = Arbitrary.schema(
    Schema.Struct({
      cadence: Schema.Literals(["weekly", "fortnightly", "monthly", "quarterly"]),
      start: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 730 })),
      width: Schema.Int.check(Schema.isBetween({ minimum: 0, maximum: 365 })),
    }),
  )
  const epoch = Date.parse("2024-01-01T00:00:00Z")
  const day = 86_400_000
  const dateAt = (offset) => new Date(epoch + offset * day).toISOString().slice(0, 10)
  const result = await Effect.runPromise(
    Arbitrary.checkEffect(
      cases,
      ({ cadence, start, width }) => {
        const interval = { weekly: 7, fortnightly: 14, monthly: 30, quarterly: 91 }[cadence]
        const charge = Schema.decodeUnknownSync(RecurringCharge)({ ...recurringRecord, cadence, lastDate: dateAt(0) })
        const expected = Array.from({ length: width + 1 }, (_, index) => start + index)
          .filter((offset) => offset > 0 && offset % interval === 0)
          .map(dateAt)
        const actual = charge.projectDates(dateAt(start), dateAt(start + width))
        return JSON.stringify(actual) === JSON.stringify(expected)
      },
      { runs: 300, seed: "recurring-projection" },
    ),
  )
  assert.equal(result._tag, "Passed", Arbitrary.formatCheckFailure(result))
})

test("detected charges carry projection behavior through cashflow forecasts", () => {
  const transactions = ["2024-02-15", "2024-02-22", "2024-02-29"].map((date, index) =>
    Schema.decodeUnknownSync(Transaction)({
      id: `tx_${index}`,
      accountId: "acc_fixture",
      date,
      description: "Fixture bill",
      amount: "-25.5",
      currency: "NZD",
    }),
  )
  const recurring = detectRecurringCharges(transactions)
  assert.equal(recurring.length, 1)
  assert(recurring[0] instanceof RecurringCharge)
  const forecast = forecastCashflow({
    startingBalance: BigDecimal.fromNumberUnsafe(100),
    today: "2024-03-01",
    days: 14,
    recurring,
    income: [],
  })
  assert.deepEqual(
    forecast.events.map((event) => event.date),
    ["2024-03-07", "2024-03-14"],
  )
  assert.equal(BigDecimal.format(forecast.events[0].amount), "-25.5")
})
