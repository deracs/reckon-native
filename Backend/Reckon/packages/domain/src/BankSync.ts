// Bank-sync port — the upstream-pull side of the hexagon. An
// implementation (e.g. @reckon/akahu) fetches accounts and transactions
// from the upstream source and hands them to BankWriter. The port
// returns void; the side-effect is internal data being mirrored.
//
// This file declares the service interface + Context tag + error class
// only. No runtime, no I/O, no implementations.

import { Context, Effect, Schema } from "effect";

export class BankSyncError extends Schema.TaggedError<BankSyncError>()(
  "BankSyncError",
  {
    reason: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {}

export interface PullWindowOptions {
  readonly accountId: string;
  readonly from: string;
  readonly to: string;
}

export interface PullWindowResult {
  readonly count: number;
}

export interface BankSyncService {
  readonly pull: () => Effect.Effect<void, BankSyncError>;
  readonly pullWindow: (
    options: PullWindowOptions,
  ) => Effect.Effect<PullWindowResult, BankSyncError>;
}

export class BankSync extends Context.Service<BankSync, BankSyncService>()(
  "personal-bank-mcp/BankSync",
) {}
