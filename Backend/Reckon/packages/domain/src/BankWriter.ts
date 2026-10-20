// Bank-writer port — the storage-write side of the hexagon. An
// implementation (e.g. @reckon/postgres) accepts domain Account and
// Transaction values and persists them. The domain → storage projection
// lives entirely inside the implementation; this port traffics only in
// domain types.
//
// This file declares the service interface + Context tag + error class
// only. No runtime, no I/O, no implementations.

import { Context, Effect, Schema } from "effect";
import type { Account, Transaction } from "./BankData.js";

export class BankWriterError extends Schema.TaggedError<BankWriterError>()(
  "BankWriterError",
  {
    reason: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {}

export interface BankWriterService {
  readonly upsertAccounts: (
    accounts: ReadonlyArray<Account>,
  ) => Effect.Effect<void, BankWriterError>;
  readonly upsertTransactions: (
    txns: ReadonlyArray<Transaction>,
  ) => Effect.Effect<void, BankWriterError>;
}

export class BankWriter extends Context.Service<
  BankWriter,
  BankWriterService
>()("personal-bank-mcp/BankWriter") {}
