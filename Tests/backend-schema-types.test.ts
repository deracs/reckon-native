import { AkahuTransactionCategory, AkahuMerchant } from "../Backend/Reckon/packages/akahu/src/wire.js"

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
