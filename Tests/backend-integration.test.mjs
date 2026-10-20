import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { once } from "node:events"
import { mkdtemp, rm } from "node:fs/promises"
import { createServer, request as httpRequest } from "node:http"
import { tmpdir } from "node:os"
import { resolve, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import test from "node:test"

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const bundle = process.env.RECKON_APP_BUNDLE ?? resolve(project, "dist/Reckon.app")
const runtime = resolve(bundle, "Contents/Helpers/node")
const script = resolve(bundle, "Contents/Resources/Backend/backend.cjs")
const appToken = "app_token_local_fixture"
const userToken = "user_token_local_fixture"
const apiToken = "local-api-fixture-".repeat(4)
const timeout = (promise, milliseconds = 6000) => {
  let timer
  return Promise.race([promise, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error("Backend integration check timed out")), milliseconds)
  })]).finally(() => clearTimeout(timer))
}

async function launchBackend(t, handshake) {
  const directory = await mkdtemp(resolve(tmpdir(), "reckon-backend-"))
  const child = spawn(runtime, [script], { cwd: directory, env: { PATH: "/usr/bin:/bin" }, stdio: ["pipe", "pipe", "pipe"] })
  let stdout = ""
  let stderr = ""
  child.stdout.on("data", chunk => { stdout += chunk })
  child.stderr.on("data", chunk => { stderr += chunk })
  const exit = once(child, "exit")
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.stdin.end()
      await timeout(exit).catch(() => child.kill("SIGKILL"))
    }
    assert(!stdout.includes(appToken) && !stdout.includes(userToken) && !stdout.includes(apiToken), "stdout exposed a token")
    assert(!stderr.includes(appToken) && !stderr.includes(userToken) && !stderr.includes(apiToken), "stderr exposed a token")
    await rm(directory, { recursive: true, force: true })
  })
  const firstLine = timeout(new Promise((resolveLine, reject) => {
    let buffer = ""
    child.stdout.on("data", chunk => {
      buffer += chunk
      if (buffer.includes("\n")) resolveLine(JSON.parse(buffer.split("\n")[0]))
    })
    child.on("error", reject)
    child.on("exit", () => { if (!buffer.includes("\n")) reject(new Error(`Backend exited before readiness: ${stderr}`)) })
  }))
  child.stdin.write(`${JSON.stringify(handshake)}\n`)
  return { child, exit, firstLine }
}

async function fakeAkahu(t) {
  const calls = []
  const accounts = [
    { _id: "acc_main", name: "Everyday", type: "CHECKING", balance: { current: 123.45, currency: "NZD" } },
    { _id: "acc_save", name: "Savings", type: "SAVINGS", balance: { current: 1000, currency: "NZD" } },
    { _id: "acc_invest", name: "Long term", type: "INVESTMENT", balance: { current: 5000, currency: "NZD" } },
  ].map(account => ({ ...account, status: "ACTIVE", refreshed: { balance: "2026-10-20T00:00:00Z", transactions: "2026-10-20T00:00:00Z" } }))
  const transaction = (id, account, date, amount, merchant, category) => ({
    _id: id, _account: account, date: `${date}T00:00:00Z`, amount, description: merchant, merchant: { name: merchant }, meta: { logo: "https://cdn.akahu.nz/fixture.png" }, category: { _id: category, name: category },
  })
  const transactions = [
    ...["2026-07-05", "2026-08-05", "2026-09-05", "2026-10-05"].map((date, index) => transaction(`rent_${index}`, "acc_main", date, -75, "Rent", "Rent")),
    transaction("food", "acc_main", "2026-10-15", -25.5, "Grocer", "Groceries"),
    transaction("pay", "acc_main", "2026-10-01", 1000, "Employer", "Income"),
    transaction("transfer_out", "acc_main", "2026-10-12", -50, "Transfer", "Transfer"),
    transaction("transfer_in", "acc_save", "2026-10-12", 50, "Transfer", "Transfer"),
  ]
  const upstream = createServer((request, response) => {
    calls.push({ url: request.url, method: request.method, headers: request.headers })
    assert.equal(request.headers.authorization, `Bearer ${userToken}`)
    assert.equal(request.headers["x-akahu-id"], appToken)
    const url = new URL(request.url, "http://localhost")
    let items
    let cursor = null
    if (url.pathname === "/v1/accounts") {
      items = url.searchParams.has("cursor") ? accounts.slice(2) : accounts.slice(0, 2)
      cursor = url.searchParams.has("cursor") ? null : "second-page"
    } else if (url.pathname.endsWith("/transactions/pending")) {
      items = []
    } else if (url.pathname.endsWith("/transactions")) {
      const account = url.pathname.split("/")[3]
      items = transactions.filter(row => row._account === account
        && row.date >= (url.searchParams.get("start") ?? "")
        && row.date <= (url.searchParams.get("end") ?? "9999"))
    } else {
      response.writeHead(404).end()
      return
    }
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ success: true, items, cursor: { next: cursor } }))
  })
  upstream.listen(0, "127.0.0.1")
  await once(upstream, "listening")
  t.after(() => new Promise(resolveClose => upstream.close(resolveClose)))
  return { calls, baseURL: `http://127.0.0.1:${upstream.address().port}/v1` }
}

test("standalone app backend serves the real Reckon calculations against a local Akahu fixture", async t => {
  const upstream = await fakeAkahu(t)
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  assert.equal(ready.event, "ready")
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}` }
  const get = async path => {
    const response = await fetch(`${base}${path}`, { headers })
    assert.equal(response.status, 200, `${path}: ${await response.clone().text()}`)
    return response.json()
  }
  assert.deepEqual(await get("/health"), { status: "ok" })
  const accounts = await get("/accounts")
  assert.equal(accounts.length, 3)
  assert.equal(accounts[0].balance, "123.45")
  assert.equal(accounts[1].type, "savings")
  const range = "from=2026-10-01&to=2026-10-20&excludeTransfers=true"
  const cashflow = await get(`/cashflow?${range}`)
  assert.equal(cashflow[0].income, "1000")
  assert.equal(cashflow[0].spending, "100.5")
  assert.equal(cashflow[0].net, "899.5")
  const spending = await get(`/spending?${range}`)
  assert.deepEqual(spending.map(row => row.category).sort(), ["Groceries", "Rent"])
  const previous = await get("/spending?from=2026-07-01&to=2026-09-30&excludeTransfers=true")
  assert.equal(previous[0].spent, "225")
  const recurring = await get("/recurring?from=2026-04-20&to=2026-10-20")
  assert.equal(recurring.find(row => row.merchant === "Rent")?.cadence, "monthly")
  assert.equal((await get("/freshness"))[0].transactionsRefreshedAt, "2026-10-20T00:00:00.000Z")
  assert.equal((await fetch(`${base}/accounts`)).status, 401)
  assert.equal((await fetch(`${base}/health`, { headers: { Authorization: "Bearer incorrect" } })).status, 401)
  assert.equal((await fetch(`${base}/accounts`, { headers: { ...headers, Origin: "https://example.invalid" } })).status, 403)
  assert.equal((await fetch(`${base}/refresh`, { method: "POST", headers })).status, 404)
  const transactions = await get(`/transactions?${range}&limit=100`)
  assert(transactions.length > 0)
  assert(transactions.every(row => !row.id.startsWith("transfer_")))
  assert.equal(transactions.find(row => row.id === "food")?.merchantLogo, "https://cdn.akahu.nz/fixture.png")
  const forecast = await get("/forecast?days=30&excludeTransfers=true")
  assert.equal(forecast.startingBalance, "1123.45")
  assert.equal(forecast.points.length, 31)
  assert.equal((await fetch(`${base}/transactions`, { method: "POST", headers })).status, 404)
  assert.equal((await fetch(`${base}/forecast`, { headers: { Authorization: "Bearer wrong" } })).status, 401)
  assert.equal((await fetch(`${base}/docs`, { headers })).status, 404)
  const hostStatus = await new Promise((resolveStatus, reject) => {
    const request = httpRequest(`${base}/health`, { headers: { ...headers, Host: "attacker.invalid" } }, response => { response.resume(); resolveStatus(response.statusCode) })
    request.on("error", reject).end()
  })
  assert.equal(hostStatus, 403)
  assert(upstream.calls.every(call => call.method === "GET"))
})

test("closing the app pipe stops the backend and releases its local port", async t => {
  const { child, firstLine, exit } = await launchBackend(t, { appToken, userToken, apiToken })
  const ready = await firstLine
  assert.equal(ready.event, "ready")
  child.stdin.end()
  await timeout(exit, 4000)
  await assert.rejects(fetch(`http://127.0.0.1:${ready.port}/health`))
})

test("invalid credentials fail startup without a public listener or secret output", async t => {
  const { firstLine, exit } = await launchBackend(t, { appToken, userToken, apiToken: "bad token" })
  assert.deepEqual(await firstLine, { event: "failed" })
  const [code] = await timeout(exit)
  assert.notEqual(code, 0)
})
