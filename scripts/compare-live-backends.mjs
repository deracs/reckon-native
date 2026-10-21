import { spawn, execFileSync } from "node:child_process"
import { randomUUID, createHash } from "node:crypto"
import { once } from "node:events"
import { readFile, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { request as httpsRequest, Agent } from "node:https"
import { cpus, release } from "node:os"
import { dirname, resolve } from "node:path"
import { performance } from "node:perf_hooks"
import { fileURLToPath } from "node:url"
import { inspect, isDeepStrictEqual, parseArgs } from "node:util"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const { values } = parseArgs({
  options: {
    runs: { type: "string", default: "5" },
    "replay-runs": { type: "string", default: "20" },
    "baseline-bundle": { type: "string", default: resolve(project, ".build/typescript-baseline") },
    "rust-bundle": { type: "string", default: resolve(project, "dist/Reckon.app") },
    output: { type: "string", default: resolve(project, ".build/live-backend-comparison.json") },
  },
})
const runs = Number(values.runs)
const replayRuns = Number(values["replay-runs"])
if (![runs, replayRuns].every((n) => Number.isInteger(n) && n >= 1 && n <= 30))
  throw new Error("Live backend comparison requires 1–30 runs.")

// Credentials and bank responses never enter command arguments, logs, or result files.
class BankConnectionSecret {
  #value
  constructor(value) {
    this.#value = value
  }
  [inspect.custom]() {
    return "BankConnectionSecret(<redacted>)"
  }
  toJSON() {
    return "<redacted>"
  }
  handshake(apiToken, baseURL) {
    return { ...this.#value, apiToken, ...(baseURL ? { akahuBaseURL: baseURL } : {}) }
  }
}
function readKeychainConnection() {
  let raw
  try {
    raw = execFileSync(
      "/usr/bin/security",
      ["find-generic-password", "-s", "nz.reckon.native.connection", "-a", "akahu-personal-app", "-w"],
      { stdio: ["ignore", "pipe", "pipe"], timeout: 20000 },
    )
    const parsed = JSON.parse(raw.toString())
    if (
      ![parsed.appToken, parsed.userToken].every(
        (token) => typeof token === "string" && /^[\x21-\x7e]{1,4096}$/.test(token),
      )
    )
      throw new Error()
    return new BankConnectionSecret({ appToken: parsed.appToken, userToken: parsed.userToken })
  } catch {
    throw new Error("Live backend comparison could not read the saved Keychain connection.")
  } finally {
    raw?.fill(0)
  }
}
const connection = readKeychainConnection()
const implementations = {
  typescript: {
    executable: resolve(values["baseline-bundle"], "Contents/Helpers/node"),
    args: ["--max-semi-space-size=2", resolve(values["baseline-bundle"], "Contents/Resources/Backend/backend.cjs")],
  },
  rust: { executable: resolve(values["rust-bundle"], "Contents/Helpers/reckon-backend"), args: [] },
}
const today = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Pacific/Auckland",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
}).format(new Date())
const shiftMonths = (date, months, day) => {
  const shifted = new Date(`${date}T00:00:00Z`)
  shifted.setUTCMonth(shifted.getUTCMonth() + months, day ?? shifted.getUTCDate())
  return shifted.toISOString().slice(0, 10)
}
const previousEnd = new Date(`${today.slice(0, 7)}-01T00:00:00Z`)
previousEnd.setUTCDate(0)
const current = `from=${today.slice(0, 7)}-01&to=${today}&excludeTransfers=true`
const history = `from=${shiftMonths(today, -6)}&to=${today}`
const paths = [
  "/accounts",
  `/cashflow?${current}`,
  `/spending?${current}`,
  `/spending?from=${shiftMonths(today, -3, 1)}&to=${previousEnd.toISOString().slice(0, 10)}&excludeTransfers=true`,
  `/recurring?${history}`,
  "/freshness",
  `/transactions?${history}&limit=100&excludeTransfers=true`,
  "/forecast?days=30&excludeTransfers=true",
]
function withDeadline(promise, milliseconds, message) {
  let timer
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), milliseconds)
    }),
  ]).finally(() => clearTimeout(timer))
}
const residentMiB = (pid) =>
  Number(execFileSync("/bin/ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim()) / 1024
async function measureBankDashboard(implementation, baseURL) {
  const selected = implementations[implementation]
  const apiToken = randomUUID()
  const started = performance.now()
  const child = spawn(selected.executable, selected.args, {
    env: { PATH: "/usr/bin:/bin", TZ: "Pacific/Auckland", LANG: "en_NZ.UTF-8" },
    stdio: ["pipe", "pipe", "pipe"],
  })
  const exit = once(child, "exit")
  child.stderr.resume()
  child.stdin.on("error", () => {})
  const controller = new AbortController()
  try {
    const ready = withDeadline(
      new Promise((resolveReady, reject) => {
        let buffer = ""
        child.stdout.on("data", (chunk) => {
          buffer += chunk
          if (buffer.length > 16384) {
            reject(new Error("Live backend comparison received invalid startup output."))
            return
          }
          if (!buffer.includes("\n")) return
          try {
            const message = JSON.parse(buffer.split("\n")[0])
            if (
              message.event !== "ready" ||
              !Number.isInteger(message.port) ||
              message.port < 1 ||
              message.port > 65535
            )
              throw new Error()
            resolveReady(message.port)
          } catch {
            reject(new Error("Live backend comparison backend failed startup."))
          }
        })
        child.once("error", () => reject(new Error("Live backend comparison could not start a backend.")))
        child.once("exit", () => reject(new Error("Live backend comparison backend exited before readiness.")))
      }),
      12000,
      "Live backend comparison startup timed out.",
    )
    child.stdin.write(`${JSON.stringify(connection.handshake(apiToken, baseURL))}\n`)
    const port = await ready
    const startupMs = performance.now() - started
    const startupRssMiB = residentMiB(child.pid)
    const loadStarted = performance.now()
    const headers = { Authorization: `Bearer ${apiToken}`, "X-Reckon-Snapshot": randomUUID() }
    const data = await withDeadline(
      Promise.all(
        paths.map(async (path) => {
          const response = await fetch(`http://127.0.0.1:${port}${path}`, { headers, signal: controller.signal })
          if (response.status !== 200) {
            await response.arrayBuffer()
            throw new Error(
              `Live backend comparison ${implementation} ${path.split("?")[0]} returned HTTP ${response.status}.`,
            )
          }
          return response.json()
        }),
      ),
      120000,
      "Live backend comparison dashboard timed out.",
    )
    const dashboardMs = performance.now() - loadStarted
    const loadedRssMiB = residentMiB(child.pid)
    return {
      sample: { startupMs, dashboardMs, startupAndDashboardMs: startupMs + dashboardMs, startupRssMiB, loadedRssMiB },
      data,
    }
  } finally {
    controller.abort()
    child.stdin.end()
    await withDeadline(exit, 4000, "Live backend comparison shutdown timed out.").catch(() => {
      child.kill("SIGKILL")
    })
  }
}
function compareBankResponses(first, second) {
  return paths.map((path, index) => ({
    section: index === 3 ? "previous-spending" : path.split("?")[0].slice(1),
    identical: isDeepStrictEqual(first[index], second[index]),
  }))
}
const summarize = (values) => {
  const sorted = [...values].sort((a, b) => a - b)
  const middle = Math.floor(sorted.length / 2)
  return {
    median: sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2,
    p95: sorted[Math.ceil(sorted.length * 0.95) - 1],
    min: sorted[0],
    max: sorted.at(-1),
  }
}
async function compareBankRuns(count, baseURL) {
  const samples = { typescript: [], rust: [] }
  const parity = []
  for (let run = 0; run < count; run++) {
    const order = run % 2 ? ["rust", "typescript"] : ["typescript", "rust"]
    const pair = {}
    for (const implementation of order) {
      const result = await measureBankDashboard(implementation, baseURL)
      samples[implementation].push(result.sample)
      pair[implementation] = result.data
    }
    parity.push(compareBankResponses(pair.typescript, pair.rust))
    console.log(
      JSON.stringify({
        mode: baseURL ? "real-data-replay" : "live-akahu",
        pair: run + 1,
        identicalSections: parity.at(-1).filter((row) => row.identical).length,
        sections: paths.length,
      }),
    )
  }
  return {
    runsPerImplementation: count,
    order: "Alternating pairs, TypeScript first in the first pair.",
    implementations: Object.fromEntries(
      Object.entries(samples).map(([implementation, rows]) => [
        implementation,
        {
          summary: Object.fromEntries(Object.keys(rows[0]).map((key) => [key, summarize(rows.map((row) => row[key]))])),
          samples: rows,
        },
      ]),
    ),
    parity: {
      identicalPairs: parity.filter((pair) => pair.every((row) => row.identical)).length,
      sections: paths.map((_, index) => ({
        section: parity[0][index].section,
        identicalPairs: parity.filter((pair) => pair[index].identical).length,
      })),
    },
  }
}

async function captureBankSnapshot() {
  const pages = new Map()
  const agent = new Agent({ keepAlive: true })
  let recording = true
  const pageKey = (requestURL) => {
    const url = new URL(requestURL, "http://localhost")
    url.searchParams.sort()
    return `${url.pathname}?${url.searchParams}`
  }
  const server = createServer(async (request, response) => {
    if (
      request.method !== "GET" ||
      !/^\/v1\/accounts(?:\?|$|\/[^/?]+\/transactions(?:\/pending)?(?:\?|$))/.test(request.url)
    ) {
      response.writeHead(404).end()
      return
    }
    const key = pageKey(request.url)
    if (!recording) {
      const body = pages.get(key)
      if (!body) {
        response.writeHead(502).end()
        return
      }
      response.writeHead(200, { "content-type": "application/json" }).end(body)
      return
    }
    try {
      const body = await new Promise((resolveBody, reject) => {
        const upstream = httpsRequest(
          {
            hostname: "api.akahu.io",
            port: 443,
            path: request.url,
            method: "GET",
            agent,
            headers: {
              Authorization: request.headers.authorization,
              "X-Akahu-Id": request.headers["x-akahu-id"],
              Accept: "application/json",
            },
          },
          (source) => {
            const chunks = []
            source.on("data", (chunk) => chunks.push(chunk))
            source.on("error", () => reject(new Error("Live snapshot source connection failed.")))
            source.on("end", () => {
              if (source.statusCode !== 200) {
                response.writeHead(source.statusCode ?? 502).end()
                resolveBody(null)
                return
              }
              resolveBody(Buffer.concat(chunks))
            })
          },
        )
        upstream.on("error", () => reject(new Error("Live snapshot source request failed.")))
        upstream.setTimeout(20000, () => upstream.destroy())
        upstream.end()
      })
      if (body) {
        pages.set(key, body)
        response.writeHead(200, { "content-type": "application/json" }).end(body)
      }
    } catch {
      response.writeHead(502).end()
    }
  })
  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  const baseURL = `http://127.0.0.1:${server.address().port}/v1`
  const close = async () => {
    agent.destroy()
    server.closeAllConnections()
    await new Promise((resolveClose) => server.close(resolveClose))
    for (const body of pages.values()) body.fill(0)
    pages.clear()
  }
  try {
    await measureBankDashboard("rust", baseURL)
    recording = false
    return { baseURL, close }
  } catch (error) {
    await close()
    throw error
  }
}

try {
  const backendMetadata = {}
  for (const [implementation, target] of Object.entries(implementations)) {
    const binary = await readFile(implementation === "typescript" ? target.args.at(-1) : target.executable)
    backendMetadata[implementation] = {
      sha256: createHash("sha256").update(binary).digest("hex"),
      bytes: binary.length,
    }
  }
  const live = await compareBankRuns(runs)
  const snapshot = await captureBankSnapshot()
  let replay
  try {
    replay = await compareBankRuns(replayRuns, snapshot.baseURL)
  } finally {
    await snapshot.close()
  }
  const report = {
    measuredAt: new Date().toISOString(),
    environment: { cpu: cpus()[0].model, architecture: process.arch, kernel: release(), backends: backendMetadata },
    method: {
      live: "Both backends read Akahu directly with the saved Keychain connection. Each sample starts a fresh process and loads the same eight dashboard requests. No bank refresh or write operation occurs.",
      replay:
        "One read-only Akahu capture is retained only in RAM. Both backends replay the exact same successful source pages over loopback. Capture time is excluded. The replay server cannot reach Akahu after capture.",
      memory:
        "Backend process RSS in MiB from ps, immediately after readiness and after the dashboard. Not peak RSS or the full Swift app. Sampling occurs outside timed phases.",
      privacy:
        "Only timings, RSS, binary metadata, and response-equality counts enter this report. No credentials, account identities, balances, categories, merchants, or transactions are saved.",
      limits:
        "Live results include network and provider variation. Replay excludes TLS and external latency. The parent harness and its in-memory source capture are excluded from RSS.",
    },
    live,
    replay,
  }
  await writeFile(resolve(values.output), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 })
  console.log(
    JSON.stringify({
      complete: true,
      live: live.implementations,
      replay: replay.implementations,
      parity: { live: live.parity, replay: replay.parity },
    }),
  )
} catch (error) {
  // Only allowlisted harness errors reach stdout; native/HTTP diagnostics may contain sensitive data.
  const message =
    error instanceof Error && /^(Live backend comparison|Live snapshot)/.test(error.message)
      ? error.message
      : "Live backend comparison failed. No bank records were saved."
  console.error(message)
  process.exitCode = 1
}
