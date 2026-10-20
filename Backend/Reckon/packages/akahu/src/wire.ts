// Akahu wire-format schemas — what the REST API returns. Pure Schema,
// no Effect runtime. Each class carries a `toBank*` method that
// projects into the domain types from @reckon/domain.

import { AccountId as DomainAccountId, type Account, type Transaction, TransactionId } from "@reckon/domain"
import { BigDecimal, DateTime, Schema } from "effect"

/** Akahu account identity remains distinct from domain account identity. */
export const AccountId = Schema.String.pipe(Schema.brand("AkahuAccountId"))
/** A source account identity established by wire decoding. */
export type AccountId = typeof AccountId.Type

/** Source connection identity used while decoding account metadata. */
export const ConnectionId = Schema.String.pipe(Schema.brand("AkahuConnectionId"))
/** A decoded source connection identity. */
export type ConnectionId = typeof ConnectionId.Type

/** Source user identity, retained only inside Akahu decoding. */
export const UserId = Schema.String.pipe(Schema.brand("AkahuUserId"))
/** A decoded source user identity. */
export type UserId = typeof UserId.Type

const MoneyAmount = Schema.Union([Schema.Finite, Schema.FiniteFromString])

/** Bank balance amounts are finite before decimal conversion. */
export class AkahuBalance extends Schema.Class<AkahuBalance, { readonly brand: unique symbol }>("AkahuBalance")({
  current: MoneyAmount,
  available: Schema.optional(MoneyAmount),
  limit: Schema.optional(MoneyAmount),
  currency: Schema.String,
}) {}

/** Merchant metadata decoded from an Akahu transaction. */
export class AkahuMerchant extends Schema.Class<AkahuMerchant, { readonly brand: unique symbol }>("AkahuMerchant")({
  name: Schema.String,
}) {}

/** Source category metadata attached to an Akahu transaction. */
export class AkahuTransactionCategory extends Schema.Class<AkahuTransactionCategory, { readonly brand: unique symbol }>(
  "AkahuTransactionCategory",
)({
  _id: Schema.String,
  name: Schema.String,
}) {}

/** A null next cursor marks the end of an Akahu result page. */
export class AkahuCursor extends Schema.Class<AkahuCursor, { readonly brand: unique symbol }>("AkahuCursor")({
  next: Schema.NullOr(Schema.String),
}) {}

/** Source bank identity and optional logo from Akahu. */
export class AkahuConnection extends Schema.Class<AkahuConnection, { readonly brand: unique symbol }>(
  "AkahuConnection",
)({
  _id: ConnectionId,
  name: Schema.String,
  logo: Schema.optional(Schema.String),
}) {}

/** Source refresh timestamps remain optional for each account data type. */
export class AkahuRefreshed extends Schema.Class<AkahuRefreshed, { readonly brand: unique symbol }>("AkahuRefreshed")({
  balance: Schema.optional(Schema.DateTimeUtc),
  meta: Schema.optional(Schema.DateTimeUtc),
  transactions: Schema.optional(Schema.DateTimeUtc),
  party: Schema.optional(Schema.DateTimeUtc),
}) {}

/** A decoded Akahu account projects its source fields into domain values. */
export class AkahuAccount extends Schema.Class<AkahuAccount, { readonly brand: unique symbol }>("AkahuAccount")({
  _id: AccountId,
  name: Schema.String,
  status: Schema.optional(Schema.String),
  type: Schema.optional(Schema.String),
  formatted_account: Schema.optional(Schema.String),
  balance: Schema.optional(AkahuBalance),
  attributes: Schema.optional(Schema.Array(Schema.String)),
  refreshed: Schema.optional(AkahuRefreshed),
  connection: Schema.optional(AkahuConnection),
}) {
  /** Preserve the account currency and convert validated amounts to decimals. */
  toBankAccount(): Account {
    return {
      id: DomainAccountId.make(this._id),
      name: this.name,
      type: toBankAccountType(this.type),
      currency: this.balance?.currency ?? "NZD",
      balance:
        this.balance?.current !== undefined
          ? BigDecimal.fromNumberUnsafe(this.balance.current)
          : BigDecimal.fromNumberUnsafe(0),
      availableBalance:
        this.balance?.available !== undefined ? BigDecimal.fromNumberUnsafe(this.balance.available) : undefined,
      creditLimit: this.balance?.limit !== undefined ? BigDecimal.fromNumberUnsafe(this.balance.limit) : undefined,
      accountNumber: this.formatted_account,
      status: toAccountStatus(this.status),
      bankName: this.connection?.name,
      bankLogo: this.connection?.logo,
    }
  }
}

/** A posted transaction has a source ID and finite amount. */
export class AkahuTransaction extends Schema.Class<AkahuTransaction, { readonly brand: unique symbol }>(
  "AkahuTransaction",
)({
  _id: Schema.String,
  _account: AccountId,
  _user: Schema.optional(UserId),
  _connection: Schema.optional(ConnectionId),
  date: Schema.DateTimeUtc,
  description: Schema.String,
  amount: MoneyAmount,
  merchant: Schema.optional(AkahuMerchant),
  meta: Schema.optional(Schema.Struct({ logo: Schema.optional(Schema.String) })),
  category: Schema.optional(AkahuTransactionCategory),
}) {
  /** Convert source amounts to decimals using the account currency. */
  toBankTransaction(currency = "NZD"): Transaction {
    return {
      id: TransactionId.make(this._id),
      accountId: DomainAccountId.make(this._account),
      date: DateTime.formatIsoDateUtc(this.date),
      description: this.description,
      merchant: this.merchant?.name,
      merchantLogo: this.meta?.logo,
      category: this.category?.name,
      amount: BigDecimal.fromNumberUnsafe(this.amount),
      currency,
    }
  }
}

/** Pending transactions derive an ID from their source account, date, description, and amount. */
export class AkahuPendingTransaction extends Schema.Class<AkahuPendingTransaction, { readonly brand: unique symbol }>(
  "AkahuPendingTransaction",
)({
  _account: Schema.optional(AccountId),
  account: Schema.optional(AccountId),
  _user: Schema.optional(UserId),
  _connection: Schema.optional(ConnectionId),
  connection: Schema.optional(ConnectionId),
  date: Schema.DateTimeUtc,
  description: Schema.String,
  amount: MoneyAmount,
}) {
  /** Accept either Akahu account field, with an explicit unknown fallback. */
  get accountId(): AccountId {
    return this._account ?? this.account ?? AccountId.make("unknown")
  }

  /** Convert source amounts to decimals using the account currency. */
  toBankTransaction(currency = "NZD"): Transaction {
    const date = DateTime.formatIsoDateUtc(this.date)
    return {
      id: TransactionId.make(`pending:${this.accountId}:${date}:${this.description}:${this.amount}`),
      accountId: DomainAccountId.make(this.accountId),
      date,
      description: this.description,
      amount: BigDecimal.fromNumberUnsafe(this.amount),
      currency,
    }
  }
}

/** A source result page ends when its cursor is absent or null. */
export const PaginatedResponse = <S extends Schema.Top>(schema: S) =>
  Schema.Struct({
    success: Schema.Boolean,
    items: Schema.Array(schema),
    cursor: Schema.optional(AkahuCursor),
  })

const toAccountStatus = (status: string | undefined): Account["status"] => {
  if (status === "ACTIVE") return "active"
  if (status === "INACTIVE") return "inactive"
  return undefined
}

/** Unknown source account types retain the existing checking-account fallback. */
export const toBankAccountType = (type: string | undefined): Account["type"] => {
  switch (type) {
    case "SAVINGS":
      return "savings"
    case "CREDITCARD":
      return "credit"
    case "LOAN":
      return "loan"
    case "KIWISAVER":
    case "INVESTMENT":
    case "TERMDEPOSIT":
      return "investment"
    case "CHECKING":
    case "FOREIGN":
    case "TAX":
    case "REWARDS":
    case "WALLET":
    case undefined:
      return "checking"
    default:
      return "checking"
  }
}
