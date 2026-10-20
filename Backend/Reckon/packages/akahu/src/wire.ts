// Akahu wire-format schemas — what the REST API returns. Pure Schema,
// no Effect runtime. Each class carries a `toBank*` method that
// projects into the domain types from @reckon/domain.

import {
  AccountId as DomainAccountId,
  type Account,
  type BankCategory,
  type Transaction,
  TransactionId,
} from "@reckon/domain"
import { BigDecimal, DateTime, Schema } from "effect"

export const AccountId = Schema.String.pipe(Schema.brand("AkahuAccountId"))
export type AccountId = typeof AccountId.Type

export const ConnectionId = Schema.String.pipe(Schema.brand("AkahuConnectionId"))
export type ConnectionId = typeof ConnectionId.Type

export const UserId = Schema.String.pipe(Schema.brand("AkahuUserId"))
export type UserId = typeof UserId.Type

const MoneyAmount = Schema.Union([Schema.Number, Schema.NumberFromString])

export class AkahuBalance extends Schema.Class<AkahuBalance>("AkahuBalance")({
  current: MoneyAmount,
  available: Schema.optional(MoneyAmount),
  limit: Schema.optional(MoneyAmount),
  currency: Schema.String,
}) {}

export class AkahuMerchant extends Schema.Class<AkahuMerchant>("AkahuMerchant")({
  name: Schema.String,
}) {}

export class AkahuTransactionCategory extends Schema.Class<AkahuTransactionCategory>(
  "AkahuTransactionCategory",
)({
  _id: Schema.String,
  name: Schema.String,
}) {}

export class AkahuCursor extends Schema.Class<AkahuCursor>("AkahuCursor")({
  next: Schema.NullOr(Schema.String),
}) {}

export class AkahuConnection extends Schema.Class<AkahuConnection>("AkahuConnection")({
  _id: ConnectionId,
  name: Schema.String,
  logo: Schema.optional(Schema.String),
}) {}

export class AkahuRefreshed extends Schema.Class<AkahuRefreshed>("AkahuRefreshed")({
  balance: Schema.optional(Schema.DateTimeUtc),
  meta: Schema.optional(Schema.DateTimeUtc),
  transactions: Schema.optional(Schema.DateTimeUtc),
  party: Schema.optional(Schema.DateTimeUtc),
}) {}

export class AkahuAccount extends Schema.Class<AkahuAccount>("AkahuAccount")({
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
        this.balance?.available !== undefined
          ? BigDecimal.fromNumberUnsafe(this.balance.available)
          : undefined,
      creditLimit:
        this.balance?.limit !== undefined
          ? BigDecimal.fromNumberUnsafe(this.balance.limit)
          : undefined,
      accountNumber: this.formatted_account,
      status: toAccountStatus(this.status),
      bankName: this.connection?.name,
      bankLogo: this.connection?.logo,
    }
  }
}

export class AkahuTransaction extends Schema.Class<AkahuTransaction>("AkahuTransaction")({
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

export class AkahuPendingTransaction extends Schema.Class<AkahuPendingTransaction>(
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
  get accountId(): AccountId {
    return this._account ?? this.account ?? AccountId.make("unknown")
  }

  toBankTransaction(currency = "NZD"): Transaction {
    const date = DateTime.formatIsoDateUtc(this.date)
    return {
      id: TransactionId.make(
        `pending:${this.accountId}:${date}:${this.description}:${this.amount}`,
      ),
      accountId: DomainAccountId.make(this.accountId),
      date,
      description: this.description,
      amount: BigDecimal.fromNumberUnsafe(this.amount),
      currency,
    }
  }
}

export class AkahuCategoryGroup extends Schema.Class<AkahuCategoryGroup>(
  "AkahuCategoryGroup",
)({
  _id: Schema.String,
  name: Schema.String,
}) {}

export class AkahuCategoryDoc extends Schema.Class<AkahuCategoryDoc>("AkahuCategoryDoc")({
  _id: Schema.String,
  name: Schema.String,
  groups: Schema.optional(Schema.Record(Schema.String, AkahuCategoryGroup)),
}) {
  toBankCategory(): BankCategory {
    return {
      id: this._id,
      name: this.name,
      group: this.groups?.["personal_finance"]?.name,
    }
  }
}

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
