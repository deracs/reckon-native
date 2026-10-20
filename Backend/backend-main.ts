import { createInterface } from "node:readline"
import * as NodeRuntime from "@effect/platform-node/NodeRuntime"
import { AkahuBankDataLayer } from "@reckon/akahu"
import { Cause, ConfigProvider, Effect, Layer, Logger, Redacted, Schedule, Schema } from "effect"
import { listenForBankRequests } from "./native-bank-server.js"

class BackendStartupError extends Schema.TaggedError<BackendStartupError, { readonly brand: unique symbol }>()(
  "BackendStartupError",
  {
    message: Schema.String,
  },
) {}

const Secret = Schema.RedactedFromValue(
  Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(4096), Schema.isPattern(/^\S+$/)),
)
const BackendHandshake = Schema.fromJsonString(
  Schema.Struct({
    appToken: Secret,
    userToken: Secret,
    apiToken: Secret,
    akahuBaseURL: Schema.optionalKey(
      Schema.String.check(
        Schema.isPattern(/^(https:\/\/api\.akahu\.io\/v1\/?|http:\/\/(127\.0\.0\.1|localhost):[0-9]+\/v1\/?)$/),
      ),
    ),
  }),
)

const parentPID = process.ppid
const input = createInterface({ input: process.stdin, terminal: false })
const waitForDisconnect = Effect.callback<void>((resume) => {
  const closed = (): void => resume(Effect.void)
  input.once("close", closed)
  return Effect.sync(() => input.off("close", closed))
})
const waitForParentExit = Effect.sync(() => process.ppid !== parentPID || process.ppid === 1).pipe(
  Effect.repeat({ schedule: Schedule.spaced("1 second"), until: (orphaned) => orphaned }),
)

const readHandshake = Effect.callback<string, BackendStartupError>((resume) => {
  let bytes = 0
  const countInput = (chunk: Buffer): void => {
    bytes += chunk.byteLength
    if (bytes > 32_768)
      resume(Effect.fail(new BackendStartupError({ message: "Backend credentials exceeded the input limit." })))
  }
  const readLine = (line: string): void => resume(Effect.succeed(line))
  process.stdin.on("data", countInput)
  input.once("line", readLine)
  return Effect.sync(() => {
    process.stdin.off("data", countInput)
    input.off("line", readLine)
  })
}).pipe(
  Effect.timeoutOrElse({
    duration: "10 seconds",
    orElse: () => Effect.fail(new BackendStartupError({ message: "Backend credentials were not received." })),
  }),
)

const program = Effect.gen(function* () {
  const raw = yield* readHandshake
  const handshake = yield* Schema.decodeEffect(BackendHandshake)(raw).pipe(
    Effect.mapError(() => new BackendStartupError({ message: "Backend credentials were invalid." })),
  )
  return yield* listenForBankRequests(handshake.apiToken).pipe(
    Effect.flatMap((port) =>
      Effect.sync(() => process.stdout.write(`${JSON.stringify({ event: "ready", port })}\n`)).pipe(
        Effect.andThen(Effect.never),
      ),
    ),
    Effect.provide(
      AkahuBankDataLayer.pipe(
        Layer.provide(
          ConfigProvider.layer(
            ConfigProvider.fromUnknown({
              AKAHU_APP_TOKEN: Redacted.value(handshake.appToken),
              AKAHU_USER_TOKEN: Redacted.value(handshake.userToken),
              AKAHU_BASE_URL: handshake.akahuBaseURL ?? "https://api.akahu.io/v1",
            }),
          ),
        ),
      ),
    ),
  )
}).pipe(
  Effect.scoped,
  Effect.provide(Logger.layer([])),
  Effect.tapCause((cause) =>
    Cause.hasInterruptsOnly(cause)
      ? Effect.void
      : Effect.sync(() => process.stdout.write(`${JSON.stringify({ event: "failed" })}\n`)),
  ),
)

NodeRuntime.runMain(
  Effect.raceFirst(program, Effect.raceFirst(waitForDisconnect, waitForParentExit)).pipe(
    Effect.ensuring(
      Effect.sync(() => {
        input.close()
        process.stdin.destroy()
      }),
    ),
  ),
  {
    disableErrorReporting: true,
    teardown: (exit, onExit) => onExit(exit._tag === "Success" || Cause.hasInterruptsOnly(exit.cause) ? 0 : 1),
  },
)
