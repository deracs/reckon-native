import assert from "node:assert/strict"
import { spawn, execFileSync } from "node:child_process"
import { randomUUID, createHash } from "node:crypto"
import { once } from "node:events"
import { readFile, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { cpus, release } from "node:os"
import { dirname, resolve } from "node:path"
import { performance } from "node:perf_hooks"
import { fileURLToPath } from "node:url"
import { parseArgs } from "node:util"

const { values } = parseArgs({
  options: {
    runs: { type: "string", default: "20" },
    output: { type: "string" },
  },
})
const runs = Number(values.runs)
assert(Number.isInteger(runs) && runs >= 2 && runs <= 100, "Use 2–100 measurement runs.")
const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const runtime = resolve(project, "dist/Reckon.app/Contents/Helpers/node")
const backend = resolve(project, "dist/Reckon.app/Contents/Resources/Backend/backend.cjs")
const token = "synthetic-benchmark-token"
const today = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Pacific/Auckland",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
}).format(new Date())
const todayMillis = Date.parse(`${today}T00:00:00Z`)
const fromDate = new Date(todayMillis)
fromDate.setUTCMonth(fromDate.getUTCMonth() - 6, 1)
const from = fromDate.toISOString().slice(0, 10)
const dayCount = Math.floor((todayMillis - fromDate.getTime()) / 86_400_000) + 1
const dateAt = (day) => new Date(fromDate.getTime() + day * 86_400_000).toISOString().slice(0, 10)
const accounts = ["CHECKING", "SAVINGS", "INVESTMENT"].map((type, index) => ({
  _id: `fixture_account_${index}`,
  name: `Fixture account ${index}`,
  type,
  balance: { current: 1000 + index * 1000, currency: "NZD" },
  refreshed: { balance: `${today}T00:00:00Z`, transactions: `${today}T00:00:00Z` },
}))
const history = accounts.map((account, accountIndex) =>
  Array.from({ length: 1000 }, (_, index) => ({
    _id: `fixture_transaction_${accountIndex}_${index}`,
    _account: account._id,
    date: `${dateAt(index % dayCount)}T00:00:00Z`,
    amount: index % 29 === 0 ? 1000 : -(5 + ((index * 37 + accountIndex * 13) % 30000) / 100),
    description: `Fixture merchant ${index % 35}`,
    merchant: { name: `Fixture merchant ${index % 35}` },
    category: { _id: `fixture_category_${index % 8}`, name: `Fixture category ${index % 8}` },
  })),
)
const paths = (() => {
  const previousEnd = new Date(`${today.slice(0, 7)}-01T00:00:00Z`)
  previousEnd.setUTCDate(0)
  const previousStart = new Date(`${today.slice(0, 7)}-01T00:00:00Z`)
  previousStart.setUTCMonth(previousStart.getUTCMonth() - 3)
  const current = `from=${today.slice(0, 7)}-01&to=${today}&excludeTransfers=true`
  const previous = `from=${previousStart.toISOString().slice(0, 10)}&to=${previousEnd.toISOString().slice(0, 10)}&excludeTransfers=true`
  const sixMonths = new Date(todayMillis)
  sixMonths.setUTCMonth(sixMonths.getUTCMonth() - 6)
  const recurring = `from=${sixMonths.toISOString().slice(0, 10)}&to=${today}`
  return [
    "/accounts",
    `/cashflow?${current}`,
    `/spending?${current}`,
    `/spending?${previous}`,
    `/recurring?${recurring}`,
    "/freshness",
    `/transactions?${recurring}&limit=100&excludeTransfers=true`,
    "/forecast?days=30&excludeTransfers=true",
  ]
})()

const deadline = (promise, milliseconds = 10000) => {
  let timer
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("Backend measurement timed out.")), milliseconds)
    }),
  ]).finally(() => clearTimeout(timer))
}
const residentMiB = (pid) =>
  Number(execFileSync("ps", ["-o", "rss=", "-p", String(pid)], { encoding: "utf8" }).trim()) / 1024
const summarize = (numbers) => {
  const sorted = [...numbers].sort((a, b) => a - b)
  const quantile = (fraction) => sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)]
  const middle = Math.floor(sorted.length / 2)
  const median = sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
  return { median, p95: quantile(0.95), min: sorted[0], max: sorted.at(-1) }
}

async function measureScenario(latencyMs) {
  let upstreamCalls = 0
  const server = createServer((request, response) => {
    upstreamCalls += 1
    assert.equal(request.headers.authorization, `Bearer ${token}`)
    assert.equal(request.headers["x-akahu-id"], token)
    const url = new URL(request.url, "http://localhost")
    let items
    let cursor = null
    if (url.pathname === "/v1/accounts") items = accounts
    else if (url.pathname.endsWith("/pending")) items = []
    else {
      const accountIndex = accounts.findIndex((account) => url.pathname === `/v1/accounts/${account._id}/transactions`)
      assert(accountIndex >= 0, "Unexpected fixture route.")
      const matching = history[accountIndex].filter(
        (transaction) =>
          transaction.date >= (url.searchParams.get("start") ?? "") &&
          transaction.date <= (url.searchParams.get("end") ?? "9999"),
      )
      const offset = Number(url.searchParams.get("cursor") ?? 0)
      items = matching.slice(offset, offset + 500)
      cursor = offset + 500 < matching.length ? String(offset + 500) : null
    }
    const body = JSON.stringify({ success: true, items, cursor: { next: cursor } })
    const reply = () => response.writeHead(200, { "content-type": "application/json" }).end(body)
    if (latencyMs) setTimeout(reply, latencyMs)
    else reply()
  })
  server.listen(0, "127.0.0.1")
  await once(server, "listening")
  const baseURL = `http://127.0.0.1:${server.address().port}/v1`
  const samples = []
  try {
    for (let run = 0; run < runs; run += 1) {
      const started = performance.now()
      const child = spawn(runtime, [backend], { env: { PATH: "/usr/bin:/bin" }, stdio: ["pipe", "pipe", "pipe"] })
      const exit = once(child, "exit")
      const ready = deadline(
        new Promise((resolveReady, reject) => {
          let buffer = ""
          child.stdout.on("data", (chunk) => {
            buffer += chunk
            if (buffer.includes("\n")) {
              const message = JSON.parse(buffer.split("\n")[0])
              if (message.event === "ready")
                resolveReady({ port: message.port, startupMs: performance.now() - started })
              else reject(new Error("Backend did not become ready."))
            }
          })
          child.once("error", reject)
          child.once("exit", () => reject(new Error("Backend exited before readiness.")))
        }),
      )
      child.stderr.resume()
      child.stdin.write(
        `${JSON.stringify({ appToken: token, userToken: token, apiToken: token, akahuBaseURL: baseURL })}\n`,
      )
      try {
        const { port, startupMs } = await ready
        const startupRssMiB = residentMiB(child.pid)
        const loadDashboard = async () => {
          const headers = { Authorization: `Bearer ${token}`, "X-Reckon-Snapshot": randomUUID() }
          const beforeCalls = upstreamCalls
          const loadStarted = performance.now()
          const data = await deadline(
            Promise.all(
              paths.map(async (path) => {
                const response = await fetch(`http://127.0.0.1:${port}${path}`, { headers })
                assert.equal(response.status, 200, "Dashboard section failed.")
                return response.json()
              }),
            ),
          )
          const elapsedMs = performance.now() - loadStarted
          assert.equal(data[0].length, 3)
          assert.equal(data[6].length, 100)
          assert.equal(data[7].points.length, 31)
          return { elapsedMs, upstreamRequests: upstreamCalls - beforeCalls }
        }
        const firstLoad = await loadDashboard()
        const loadedRssMiB = residentMiB(child.pid)
        const reload = await loadDashboard()
        const reloadRssMiB = residentMiB(child.pid)
        samples.push({ startupMs, startupRssMiB, firstLoad, loadedRssMiB, reload, reloadRssMiB })
      } finally {
        child.stdin.end()
        await deadline(exit).catch((error) => {
          child.kill("SIGKILL")
          throw error
        })
      }
    }
  } finally {
    server.closeAllConnections()
    await new Promise((resolveClose) => server.close(resolveClose))
  }
  const summary = {
    startupMs: summarize(samples.map((sample) => sample.startupMs)),
    firstDashboardMs: summarize(samples.map((sample) => sample.firstLoad.elapsedMs)),
    freshReloadMs: summarize(samples.map((sample) => sample.reload.elapsedMs)),
    startupRssMiB: summarize(samples.map((sample) => sample.startupRssMiB)),
    loadedRssMiB: summarize(samples.map((sample) => sample.loadedRssMiB)),
    reloadRssMiB: summarize(samples.map((sample) => sample.reloadRssMiB)),
    firstLoadUpstreamRequests: [...new Set(samples.map((sample) => sample.firstLoad.upstreamRequests))],
    reloadUpstreamRequests: [...new Set(samples.map((sample) => sample.reload.upstreamRequests))],
  }
  return { latencyMs, runs, summary, samples }
}

const report = {
  measuredAt: new Date().toISOString(),
  environment: {
    cpu: cpus()[0].model,
    architecture: process.arch,
    platform: process.platform,
    kernel: release(),
    backendNode: execFileSync(runtime, ["--version"], { encoding: "utf8" }).trim(),
    effect: JSON.parse(await readFile(resolve(project, "package.json"), "utf8")).dependencies.effect,
    bundleBytes: (await readFile(backend)).length,
    bundleSha256: createHash("sha256")
      .update(await readFile(backend))
      .digest("hex"),
  },
  workload: {
    accounts: accounts.length,
    postedTransactions: history.flat().length,
    pageSize: 500,
    dashboardRequests: paths.length,
    from,
    to: today,
  },
  method: {
    startup:
      "Fresh process spawn through ready stdout handshake; OS caches are not flushed. No source requests occur before readiness.",
    dashboard:
      "Eight concurrent authenticated requests through JSON decoding in this Node harness. Each load uses a new snapshot UUID. Excludes Swift decoding, UI rendering, Keychain, and live Akahu.",
    memory:
      "Backend process RSS from ps, in MiB, sampled outside the timed intervals. Shared pages count toward RSS. This is not peak memory or the full Swift app footprint.",
    latency:
      "Local fixture has 0 or 50 ms delay per upstream response. This simulates latency; it does not predict live Akahu performance.",
  },
  scenarios: [],
}
for (const latency of [0, 50]) {
  const result = await measureScenario(latency)
  report.scenarios.push(result)
  console.log(JSON.stringify({ latencyMs: latency, runs, ...result.summary }, null, 2))
}
if (values.output) await writeFile(resolve(values.output), `${JSON.stringify(report, null, 2)}\n`)
