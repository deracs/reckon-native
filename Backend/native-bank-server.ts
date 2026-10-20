import { timingSafeEqual } from "node:crypto"
import { createServer } from "node:http"
import * as NodeHttpServer from "@effect/platform-node/NodeHttpServer"
import {
  Account,
  AccountFreshness,
  BankData,
  type BankDataError,
  BankSnapshotId,
  DateRange,
  Forecast,
  MonthlyCashflow,
  RecurringCharge,
  SpendingByCategory,
  Transaction,
} from "@reckon/domain"
import { Effect, Redacted, Schema, SchemaGetter, type Scope } from "effect"
import * as HttpServerRequest from "effect/http/HttpServerRequest"
import * as HttpServerResponse from "effect/http/HttpServerResponse"
import * as UrlParams from "effect/http/UrlParams"

class NativeHttpError extends Schema.TaggedError<NativeHttpError, { readonly brand: unique symbol }>()(
  "NativeHttpError",
  { status: Schema.Literals([400, 500]), message: Schema.String },
) {}

class NativeServerError extends Schema.TaggedError<NativeServerError, { readonly brand: unique symbol }>()(
  "NativeServerError",
  { message: Schema.String },
) {}

type NativeRoute = (
  query: Readonly<Record<string, string>>,
  snapshotId: BankSnapshotId | undefined,
) => Effect.Effect<HttpServerResponse.HttpServerResponse, NativeHttpError | BankDataError>

const BooleanFromString = Schema.Literals(["true", "false"]).pipe(
  Schema.decodeTo(Schema.Boolean, {
    decode: SchemaGetter.transform((value) => value === "true"),
    encode: SchemaGetter.transform((value) => (value ? "true" : "false")),
  }),
)
const excludeTransfers = { excludeTransfers: Schema.optionalKey(BooleanFromString) }
const RangeQuery = Schema.Struct({ ...DateRange, ...excludeTransfers })
const QueryValues = Schema.Record(Schema.String, Schema.String)

const bankRoute =
  <Q, A>(
    querySchema: Schema.ConstraintDecoder<Q>,
    responseSchema: Schema.ConstraintCodec<A, unknown>,
    read: (query: Q, snapshotId: BankSnapshotId | undefined) => Effect.Effect<A, BankDataError>,
  ): NativeRoute =>
  (raw, snapshotId) =>
    Effect.gen(function* () {
      const query = yield* Schema.decodeEffect(querySchema)(raw).pipe(
        Effect.mapError(() => new NativeHttpError({ status: 400, message: "Invalid bank query." })),
      )
      const data = yield* read(query, snapshotId)
      return yield* HttpServerResponse.schemaJson(responseSchema)(data).pipe(
        Effect.mapError(() => new NativeHttpError({ status: 500, message: "Could not encode bank data." })),
      )
    })

const tokenMatches = (received: string | undefined, token: Redacted.Redacted<string>): boolean => {
  if (received === undefined) return false
  const actual = Buffer.from(received)
  const expected = Buffer.from(`Bearer ${Redacted.value(token)}`)
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

const readBankRequest = (
  port: number,
  apiToken: Redacted.Redacted<string>,
  routes: Readonly<Record<string, NativeRoute | undefined>>,
): Effect.Effect<HttpServerResponse.HttpServerResponse, never, HttpServerRequest.HttpServerRequest> =>
  Effect.gen(function* () {
    const request = yield* HttpServerRequest.HttpServerRequest
    if (request.headers.host !== `127.0.0.1:${port}` || request.headers.origin !== undefined) {
      return HttpServerResponse.empty({ status: 403 })
    }
    if (!tokenMatches(request.headers.authorization, apiToken)) return HttpServerResponse.empty({ status: 401 })
    const [path, queryString] = request.url.split("?")
    if (request.method !== "GET" || path === undefined) return HttpServerResponse.empty({ status: 404 })
    if (path === "/health") return HttpServerResponse.jsonUnsafe({ status: "ok" })
    const route = Object.hasOwn(routes, path) ? routes[path] : undefined
    if (route === undefined) return HttpServerResponse.empty({ status: 404 })
    return yield* Effect.gen(function* () {
      const raw = UrlParams.toRecord(UrlParams.fromInput(new URLSearchParams(queryString)))
      const query = yield* Schema.decodeUnknownEffect(QueryValues)(raw).pipe(
        Effect.mapError(() => new NativeHttpError({ status: 400, message: "Invalid bank query." })),
      )
      const snapshotId = yield* Schema.decodeEffect(Schema.UndefinedOr(BankSnapshotId))(
        request.headers["x-reckon-snapshot"],
      ).pipe(Effect.mapError(() => new NativeHttpError({ status: 400, message: "Invalid bank snapshot." })))
      return yield* route(query, snapshotId)
    }).pipe(
      Effect.catchTags({
        NativeHttpError: (error) => Effect.succeed(HttpServerResponse.text(error.message, { status: error.status })),
        BankDataError: () => Effect.succeed(HttpServerResponse.text("Could not read Akahu data.", { status: 502 })),
      }),
    )
  })

/** Effect's Node server owns request interruption and loopback listener cleanup in the calling scope. */
export const listenForBankRequests = (
  apiToken: Redacted.Redacted<string>,
): Effect.Effect<number, NativeServerError, BankData | Scope.Scope> =>
  Effect.gen(function* () {
    const bank = yield* BankData
    const routes: Readonly<Record<string, NativeRoute | undefined>> = {
      "/accounts": bankRoute(Schema.Struct({}), Schema.Array(Account), () => bank.listAccounts()),
      "/cashflow": bankRoute(RangeQuery, Schema.Array(MonthlyCashflow), (query, snapshotId) =>
        bank.summarizeCashflow({ ...query, snapshotId }),
      ),
      "/spending": bankRoute(RangeQuery, Schema.Array(SpendingByCategory), (query, snapshotId) =>
        bank.summarizeSpending({ ...query, snapshotId }),
      ),
      "/recurring": bankRoute(
        Schema.Struct({ ...DateRange, minOccurrences: Schema.optionalKey(Schema.FiniteFromString) }),
        Schema.Array(RecurringCharge),
        (query, snapshotId) => bank.listRecurringCharges({ ...query, snapshotId }),
      ),
      "/freshness": bankRoute(Schema.Struct({}), Schema.Array(AccountFreshness), () => bank.getDataFreshness()),
      "/transactions": bankRoute(
        Schema.Struct({
          ...DateRange,
          ...excludeTransfers,
          query: Schema.optionalKey(Schema.String),
          accountId: Schema.optionalKey(Schema.String),
          category: Schema.optionalKey(Schema.String),
          limit: Schema.optionalKey(Schema.FiniteFromString),
        }),
        Schema.Array(Transaction),
        (query, snapshotId) => bank.searchTransactions({ ...query, snapshotId }),
      ),
      "/forecast": bankRoute(
        Schema.Struct({ days: Schema.optionalKey(Schema.FiniteFromString), ...excludeTransfers }),
        Forecast,
        (query, snapshotId) => bank.forecastCashflow({ ...query, snapshotId }),
      ),
    }
    const listener = createServer()
    const server = yield* NodeHttpServer.make(() => listener, {
      host: "127.0.0.1",
      port: 0,
      gracefulShutdownTimeout: "1 second",
    }).pipe(Effect.mapError(() => new NativeServerError({ message: "Backend could not listen on loopback." })))
    if (server.address._tag === "UnixPathAddress") {
      return yield* new NativeServerError({ message: "Backend did not open a local port." })
    }
    const port = server.address.port
    yield* server.serve(readBankRequest(port, apiToken, routes).pipe(Effect.interruptible))
    // Quitting the app abandons dashboard reads rather than draining their HTTP responses.
    yield* Effect.addFinalizer(() => Effect.sync(() => listener.closeAllConnections()))
    return port
  })
