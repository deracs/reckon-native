import { Context, Effect, Schema } from "effect"
import { GoalConfig, GoalInput } from "./BankData.js"

/** A caller-generated key reused for every retry of one goal creation. */
export const GoalCreationKey = Schema.String.check(
  Schema.isPattern(/^[A-Za-z0-9._:-]{1,128}$/),
).pipe(Schema.brand("GoalCreationKey"))

/** Goal creation failures preserve the original request when a key conflicts. */
export class GoalCreationError extends Schema.TaggedError<GoalCreationError>()("GoalCreationError", {
  code: Schema.Literals(["unsupported", "idempotency_conflict", "invalid_input", "invalid_account", "storage"]),
  message: Schema.String,
  retryable: Schema.Boolean,
}) {}

/** Durable goal creation returns the original result without overwriting later edits. */
export interface GoalCreationService {
  readonly available: boolean
  readonly create: (input: {
    readonly idempotencyKey: typeof GoalCreationKey.Type
    readonly goal: Omit<GoalInput, "id">
  }) => Effect.Effect<GoalConfig, GoalCreationError>
}

/** The adapter owns atomic goal creation and durable idempotency receipts. */
export class GoalCreation extends Context.Service<GoalCreation, GoalCreationService>()("reckon/GoalCreation") {}
