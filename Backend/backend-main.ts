import { timingSafeEqual } from "node:crypto"
import { createServer } from "node:http"
import { createInterface } from "node:readline"
import { NodeHttpServer, NodeRuntime } from "@effect/platform-node"
import { AkahuBankDataLayer } from "@reckon/akahu"
import { Authentication, bankApi } from "@reckon/api"
import { BankHandlers } from "@reckon/native-handlers"
import { ConfigProvider, Effect, Layer, Logger, Redacted, Schema } from "effect"
import { HttpApiBuilder, HttpApiError } from "effect/unstable/httpapi"
import * as HttpRouter from "effect/unstable/http/HttpRouter"
import * as HttpServerRequest from "effect/unstable/http/HttpServerRequest"
import * as HttpServerResponse from "effect/unstable/http/HttpServerResponse"

class BackendStartupError extends Schema.TaggedError<BackendStartupError>()("BackendStartupError", {
  message: Schema.String,
}) {}

const Secret = Schema.RedactedFromValue(Schema.String.check(
  Schema.isMinLength(1), Schema.isMaxLength(4096), Schema.isPattern(/^\S+$/),
))
const BackendHandshake = Schema.fromJsonString(Schema.Struct({
  appToken: Secret,
  userToken: Secret,
  apiToken: Secret,
  akahuBaseURL: Schema.optionalKey(Schema.String.check(Schema.isPattern(
    /^(https:\/\/api\.akahu\.io\/v1\/?|http:\/\/(127\.0\.0\.1|localhost):[0-9]+\/v1\/?)$/,
  ))),
}))

const safeEqual = (received: string | undefined, expected: string): boolean => {
  if (received === undefined) return false
  const actual = Buffer.from(received)
  const wanted = Buffer.from(expected)
  return actual.length === wanted.length && timingSafeEqual(actual, wanted)
}

const parentPID = process.ppid
const input = createInterface({ input: process.stdin, terminal: false })
let stopping = false
const stopBackend = (): void => {
  if (stopping) return
  stopping = true
  process.kill(process.pid, "SIGTERM")
  setTimeout(() => process.exit(0), 2000).unref()
}
input.once("close", stopBackend)
setInterval(() => {
  if (process.ppid !== parentPID || process.ppid === 1) stopBackend()
}, 1000).unref()

const readHandshake = Effect.callback<string, BackendStartupError>((resume) => {
  let bytes = 0
  const deadline = setTimeout(() => resume(Effect.fail(new BackendStartupError({ message: "Backend credentials were not received." }))), 10_000)
  const countInput = (chunk: Buffer): void => {
    bytes += chunk.byteLength
    if (bytes > 32_768) resume(Effect.fail(new BackendStartupError({ message: "Backend credentials exceeded the input limit." })))
  }
  const readLine = (line: string): void => resume(Effect.succeed(line))
  process.stdin.on("data", countInput)
  input.once("line", readLine)
  return Effect.sync(() => {
    clearTimeout(deadline)
    process.stdin.off("data", countInput)
    input.off("line", readLine)
  })
})

const program = Effect.gen(function* () {
  const raw = yield* readHandshake
  const handshake = yield* Schema.decodeEffect(BackendHandshake)(raw).pipe(
    Effect.mapError(() => new BackendStartupError({ message: "Backend credentials were invalid." })),
  )
  const apiToken = Redacted.value(handshake.apiToken)
  const AuthenticationLive = Layer.succeed(Authentication, {
    bearer: (effect, { credential }) => safeEqual(Redacted.value(credential), apiToken)
      ? effect : Effect.fail(new HttpApiError.Unauthorized()),
  })
  const ApiLayer = HttpApiBuilder.layer(bankApi).pipe(Layer.provide(BankHandlers), Layer.provide(AuthenticationLive))
  const HealthLayer = HttpRouter.add("GET", "/health", HttpServerResponse.jsonUnsafe({ status: "ok" }))
  const server = createServer()
  const allowedPaths = new Set(["/accounts", "/cashflow", "/spending", "/recurring", "/freshness", "/transactions", "/forecast", "/health"])
  const ServerLayer = HttpRouter.serve(Layer.mergeAll(ApiLayer, HealthLayer), {
    middleware: (app) => Effect.gen(function* () {
      const request = yield* HttpServerRequest.HttpServerRequest
      const address = server.address()
      if (!address || typeof address === "string"
        || request.headers.host !== `127.0.0.1:${address.port}` || request.headers.origin !== undefined) {
        return HttpServerResponse.empty({ status: 403 })
      }
      if (!safeEqual(request.headers.authorization, `Bearer ${apiToken}`)) return HttpServerResponse.empty({ status: 401 })
      const path = request.url.split("?")[0]
      if (request.method !== "GET" || path === undefined || !allowedPaths.has(path)) return HttpServerResponse.empty({ status: 404 })
      return yield* app.pipe(Effect.catchCause(() => Effect.succeed(HttpServerResponse.text("Could not read Akahu data.", { status: 502 }))))
    }),
  }).pipe(
    Layer.provide(AkahuBankDataLayer),
    Layer.provide(NodeHttpServer.layer(() => server, { host: "127.0.0.1", port: 0, gracefulShutdownTimeout: "1 second" })),
    Layer.provide(ConfigProvider.layer(ConfigProvider.fromUnknown({
      AKAHU_APP_TOKEN: Redacted.value(handshake.appToken),
      AKAHU_USER_TOKEN: Redacted.value(handshake.userToken),
      AKAHU_BASE_URL: handshake.akahuBaseURL ?? "https://api.akahu.io/v1",
    }))),
  )
  yield* Layer.build(ServerLayer)
  const address = server.address()
  if (!address || typeof address === "string") {
    return yield* Effect.fail(new BackendStartupError({ message: "Backend did not open a local port." }))
  }
  yield* Effect.sync(() => process.stdout.write(`${JSON.stringify({ event: "ready", port: address.port })}\n`))
  return yield* Effect.never
}).pipe(
  Effect.scoped,
  Effect.provide(Logger.layer([])),
  Effect.tapCause(() => Effect.sync(() => process.stdout.write(`${JSON.stringify({ event: "failed" })}\n`))),
)

NodeRuntime.runMain(program, { disableErrorReporting: true })
