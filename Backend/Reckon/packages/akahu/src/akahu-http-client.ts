import { BankDataError } from "@reckon/domain"
import { Effect, Redacted, Schedule, Schema } from "effect"
import * as Headers from "effect/http/Headers"
import * as HttpClient from "effect/http/HttpClient"
import * as HttpClientRequest from "effect/http/HttpClientRequest"
import * as HttpClientResponse from "effect/http/HttpClientResponse"

interface AkahuHttpClient {
  readonly getJson: <A>(
    path: string,
    schema: Schema.ConstraintDecoder<A>,
    query?: Readonly<Record<string, string | number | boolean>>,
  ) => Effect.Effect<A, BankDataError>
}

/** Effect HTTP owns authentication, bounded transient retries, body decoding, and interruption. */
export const makeAkahuHttpClient = (options: {
  readonly baseURL: URL
  readonly appToken: Redacted.Redacted<string>
  readonly userToken: Redacted.Redacted<string>
}): Effect.Effect<AkahuHttpClient, never, HttpClient.HttpClient> =>
  Effect.gen(function* () {
    const redactedHeaders = [...(yield* Headers.CurrentRedactedNames), "x-akahu-id"]
    const client = (yield* HttpClient.HttpClient).pipe(
      HttpClient.mapRequest((request) =>
        request.pipe(
          HttpClientRequest.prependUrl(options.baseURL.href.replace(/\/$/, "")),
          HttpClientRequest.setHeader("X-Akahu-Id", Redacted.value(options.appToken)),
          HttpClientRequest.bearerToken(options.userToken),
          HttpClientRequest.acceptJson,
        ),
      ),
      HttpClient.withScope,
      HttpClient.filterStatusOk,
      // All operations are GETs; Effect also honours the provider's Retry-After header.
      HttpClient.retryTransient({ schedule: Schedule.exponential("500 millis").pipe(Schedule.jittered), times: 5 }),
    )

    return {
      getJson: Effect.fn("Akahu.getJson")(
        <A>(
          path: string,
          schema: Schema.ConstraintDecoder<A>,
          query: Readonly<Record<string, string | number | boolean>> = {},
        ) =>
          client.get(path, { urlParams: query }).pipe(
            Effect.flatMap(HttpClientResponse.schemaBodyJson(schema)),
            Effect.mapError((error) => {
              if (error._tag === "SchemaError") {
                return new BankDataError({ operation: "Akahu.decodeResponse", reason: "decode", retryable: false })
              }
              const reason = error.reason
              if (reason._tag === "StatusCodeError") {
                return new BankDataError({
                  operation: "Akahu.request",
                  reason: "http",
                  status: reason.response.status,
                  retryable: [408, 429, 500, 502, 503, 504].includes(reason.response.status),
                })
              }
              return new BankDataError({
                operation: "Akahu.request",
                reason: reason._tag === "DecodeError" ? "decode" : "transport",
                retryable: reason._tag === "TransportError",
              })
            }),
            Effect.scoped,
            Effect.provideService(Headers.CurrentRedactedNames, redactedHeaders),
            Effect.timeoutOrElse({
              duration: "20 seconds",
              orElse: () =>
                Effect.fail(new BankDataError({ operation: "Akahu.timeout", reason: "transport", retryable: true })),
            }),
          ),
      ),
    }
  })
