import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { randomUUID } from "node:crypto"
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
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error("Backend integration check timed out")), milliseconds)
    }),
  ]).finally(() => clearTimeout(timer))
}

async function launchBackend(t, handshake) {
  const directory = await mkdtemp(resolve(tmpdir(), "reckon-backend-"))
  const child = spawn(runtime, [script], {
    cwd: directory,
    env: { PATH: "/usr/bin:/bin" },
    stdio: ["pipe", "pipe", "pipe"],
  })
  let stdout = ""
  let stderr = ""
  child.stdout.on("data", (chunk) => {
    stdout += chunk
  })
  child.stderr.on("data", (chunk) => {
    stderr += chunk
  })
  const exit = once(child, "exit")
  t.after(async () => {
    if (child.exitCode === null && child.signalCode === null) {
      child.stdin.end()
      await timeout(exit).catch(() => child.kill("SIGKILL"))
    }
    assert(
      !stdout.includes(appToken) && !stdout.includes(userToken) && !stdout.includes(apiToken),
      "stdout exposed a token",
    )
    assert(
      !stderr.includes(appToken) && !stderr.includes(userToken) && !stderr.includes(apiToken),
      "stderr exposed a token",
    )
    await rm(directory, { recursive: true, force: true })
  })
  const firstLine = timeout(
    new Promise((resolveLine, reject) => {
      let buffer = ""
      child.stdout.on("data", (chunk) => {
        buffer += chunk
        if (buffer.includes("\n")) resolveLine(JSON.parse(buffer.split("\n")[0]))
      })
      child.on("error", reject)
      child.on("exit", () => {
        if (!buffer.includes("\n")) reject(new Error(`Backend exited before readiness: ${stderr}`))
      })
    }),
  )
  child.stdin.write(`${JSON.stringify(handshake)}\n`)
  return { child, exit, firstLine }
}

async function fakeAkahu(
  t,
  {
    accountBalance = { current: 123.45, currency: "NZD" },
    transactionAmount = -25.5,
    responses = [],
    transactionDate = (date) => date,
    transactionPageSize = Infinity,
    beforeResponse,
  } = {},
) {
  const calls = []
  const accounts = [
    { _id: "acc_main", name: "Everyday", type: "CHECKING", balance: accountBalance },
    { _id: "acc_save", name: "Savings", type: "SAVINGS", balance: { current: 1000, currency: "NZD" } },
    { _id: "acc_invest", name: "Long term", type: "INVESTMENT", balance: { current: 5000, currency: "NZD" } },
  ].map((account) => ({
    ...account,
    status: "ACTIVE",
    refreshed: { balance: "2026-10-20T00:00:00Z", transactions: "2026-10-20T00:00:00Z" },
  }))
  const transaction = (id, account, date, amount, merchant, category) => ({
    _id: id,
    _account: account,
    date: `${transactionDate(date)}T00:00:00Z`,
    amount,
    description: merchant,
    merchant: { name: merchant },
    meta: { logo: "https://cdn.akahu.nz/fixture.png" },
    category: { _id: category, name: category },
  })
  const transactions = [
    ...["2026-07-05", "2026-08-05", "2026-09-05", "2026-10-05"].map((date, index) =>
      transaction(`rent_${index}`, "acc_main", date, -75, "Rent", "Rent"),
    ),
    transaction("food", "acc_main", "2026-10-15", transactionAmount, "Grocer", "Groceries"),
    transaction("pay", "acc_main", "2026-10-01", 1000, "Employer", "Income"),
    transaction("transfer_out", "acc_main", "2026-10-12", -50, "Transfer", "Transfer"),
    transaction("transfer_in", "acc_save", "2026-10-12", 50, "Transfer", "Transfer"),
  ]
  const upstream = createServer((request, response) => {
    calls.push({ url: request.url, method: request.method, headers: request.headers })
    assert.equal(request.headers.authorization, `Bearer ${userToken}`)
    assert.equal(request.headers["x-akahu-id"], appToken)
    if (beforeResponse?.(request, response)) return
    const injected = responses.shift()
    if (injected) {
      response.writeHead(injected.status, injected.headers).end(injected.body)
      return
    }
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
      const matching = transactions.filter(
        (row) =>
          row._account === account &&
          row.date >= (url.searchParams.get("start") ?? "") &&
          row.date <= (url.searchParams.get("end") ?? "9999"),
      )
      const offset = Number(url.searchParams.get("cursor") ?? 0)
      items = matching.slice(offset, offset + transactionPageSize)
      cursor = offset + transactionPageSize < matching.length ? String(offset + transactionPageSize) : null
    } else {
      response.writeHead(404).end()
      return
    }
    response
      .writeHead(200, { "content-type": "application/json" })
      .end(JSON.stringify({ success: true, items, cursor: { next: cursor } }))
  })
  upstream.listen(0, "127.0.0.1")
  await once(upstream, "listening")
  t.after(() => new Promise((resolveClose) => upstream.close(resolveClose)))
  return { calls, transactions, baseURL: `http://127.0.0.1:${upstream.address().port}/v1` }
}

test("standalone app backend serves the real Reckon calculations against a local Akahu fixture", async (t) => {
  const upstream = await fakeAkahu(t)
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  assert.equal(ready.event, "ready")
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}` }
  const get = async (path) => {
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
  assert.deepEqual(spending.map((row) => row.category).sort(), ["Groceries", "Rent"])
  const previous = await get("/spending?from=2026-07-01&to=2026-09-30&excludeTransfers=true")
  assert.equal(previous[0].spent, "225")
  const recurring = await get("/recurring?from=2026-04-20&to=2026-10-20")
  assert.equal(recurring.find((row) => row.merchant === "Rent")?.cadence, "monthly")
  assert.equal((await get("/freshness"))[0].transactionsRefreshedAt, "2026-10-20T00:00:00.000Z")
  assert.equal((await fetch(`${base}/accounts`)).status, 401)
  assert.equal((await fetch(`${base}/health`, { headers: { Authorization: "Bearer incorrect" } })).status, 401)
  assert.equal(
    (await fetch(`${base}/accounts`, { headers: { ...headers, Origin: "https://example.invalid" } })).status,
    403,
  )
  assert.equal((await fetch(`${base}/refresh`, { method: "POST", headers })).status, 404)
  const transactions = await get(`/transactions?${range}&limit=100`)
  assert(transactions.length > 0)
  assert(transactions.every((row) => !row.id.startsWith("transfer_")))
  assert.equal(transactions.find((row) => row.id === "food")?.merchantLogo, "https://cdn.akahu.nz/fixture.png")
  const forecast = await get("/forecast?days=30&excludeTransfers=true")
  assert.equal(forecast.startingBalance, "1123.45")
  assert.equal(forecast.points.length, 31)
  assert.equal((await fetch(`${base}/transactions`, { method: "POST", headers })).status, 404)
  assert.equal((await fetch(`${base}/forecast`, { headers: { Authorization: "Bearer wrong" } })).status, 401)
  assert.equal((await fetch(`${base}/docs`, { headers })).status, 404)
  const hostStatus = await new Promise((resolveStatus, reject) => {
    const request = httpRequest(`${base}/health`, { headers: { ...headers, Host: "attacker.invalid" } }, (response) => {
      response.resume()
      resolveStatus(response.statusCode)
    })
    request.on("error", reject).end()
  })
  assert.equal(hostStatus, 403)
  assert(upstream.calls.every((call) => call.method === "GET"))
})

test("closing the app pipe stops the backend and releases its local port", async (t) => {
  const { child, firstLine, exit } = await launchBackend(t, { appToken, userToken, apiToken })
  const ready = await firstLine
  assert.equal(ready.event, "ready")
  child.stdin.end()
  await timeout(exit, 4000)
  await assert.rejects(fetch(`http://127.0.0.1:${ready.port}/health`))
})

for (const signal of ["SIGINT", "SIGTERM"]) {
  test(`${signal} closes the backend listener and exits cleanly`, async (t) => {
    const { child, firstLine, exit } = await launchBackend(t, { appToken, userToken, apiToken })
    const ready = await firstLine
    child.kill(signal)
    const [code] = await timeout(exit, 4000)
    assert.equal(code, 0)
    await assert.rejects(fetch(`http://127.0.0.1:${ready.port}/health`))
  })
}

test("numeric query parameters reject non-finite values before contacting Akahu", async (t) => {
  const upstream = await fakeAkahu(t)
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}` }
  for (const value of ["NaN", "Infinity", "-Infinity", "1e309"]) {
    for (const query of ["/transactions?limit=", "/recurring?minOccurrences=", "/forecast?days="]) {
      const response = await fetch(`${base}${query}${encodeURIComponent(value)}`, { headers })
      assert.equal(response.status, 400, `${query}${value}`)
      await response.arrayBuffer()
    }
  }
  for (const path of [
    "/transactions?limit=1&limit=2",
    "/forecast?excludeTransfers=yes",
    "/spending?excludeTransfers=1",
  ]) {
    const response = await fetch(`${base}${path}`, { headers })
    assert.equal(response.status, 400, path)
    await response.arrayBuffer()
  }
  assert.equal(upstream.calls.length, 0)
})

test("transient Akahu failures retry GET requests and preserve cursor pagination", async (t) => {
  const upstream = await fakeAkahu(t, { responses: [{ status: 503, body: "temporarily unavailable" }] })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const response = await fetch(`http://127.0.0.1:${ready.port}/accounts`, {
    headers: { Authorization: `Bearer ${apiToken}` },
  })
  assert.equal(response.status, 200)
  assert.equal((await response.json()).length, 3)
  assert.equal(upstream.calls.length, 3)
  assert.equal(upstream.calls[0].url, upstream.calls[1].url)
  assert.equal(new URL(upstream.calls[2].url, upstream.baseURL).searchParams.get("cursor"), "second-page")
})

test("transient upstream retries stop after the initial attempt and five retries", async (t) => {
  const upstream = await fakeAkahu(t, {
    responses: Array.from({ length: 6 }, () => ({ status: 503, body: "temporarily unavailable" })),
  })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const response = await fetch(`http://127.0.0.1:${ready.port}/accounts`, {
    headers: { Authorization: `Bearer ${apiToken}` },
  })
  assert.equal(response.status, 502)
  assert.equal(await response.text(), "Could not read Akahu data.")
  assert.equal(upstream.calls.length, 6)
})

test("permanent upstream failures and malformed JSON fail safely without retries", async (t) => {
  for (const injected of [
    { status: 401, body: "private upstream detail" },
    { status: 200, body: "{" },
  ]) {
    await t.test(`upstream status ${injected.status}`, async (t) => {
      const upstream = await fakeAkahu(t, { responses: [injected] })
      const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
      const ready = await firstLine
      const response = await fetch(`http://127.0.0.1:${ready.port}/accounts`, {
        headers: { Authorization: `Bearer ${apiToken}` },
      })
      assert.equal(response.status, 502)
      assert.equal(await response.text(), "Could not read Akahu data.")
      assert.equal(upstream.calls.length, 1)
    })
  }
})

test("Akahu redirects are rejected without forwarding credentials", async (t) => {
  const forwarded = []
  const destination = createServer((request, response) => {
    forwarded.push(request.headers)
    response.writeHead(200).end("{}")
  })
  destination.listen(0, "127.0.0.1")
  await once(destination, "listening")
  t.after(() => new Promise((resolveClose) => destination.close(resolveClose)))
  const upstream = await fakeAkahu(t, {
    responses: [
      { status: 302, headers: { location: `http://127.0.0.1:${destination.address().port}/capture` }, body: "" },
    ],
  })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const response = await fetch(`http://127.0.0.1:${ready.port}/accounts`, {
    headers: { Authorization: `Bearer ${apiToken}` },
  })
  assert.equal(response.status, 502)
  assert.equal(await response.text(), "Could not read Akahu data.")
  assert.equal(upstream.calls.length, 1)
  assert.deepEqual(forwarded, [])
})

for (const stop of ["client disconnect", "app shutdown"]) {
  test(`${stop} cancels an in-flight Akahu request`, async (t) => {
    let receivedRequest
    let disconnectedRequest
    const received = new Promise((resolveReceived) => {
      receivedRequest = resolveReceived
    })
    const disconnected = new Promise((resolveDisconnected) => {
      disconnectedRequest = resolveDisconnected
    })
    const upstream = createServer((_request, response) => {
      response.once("close", () => disconnectedRequest())
      receivedRequest()
    })
    upstream.listen(0, "127.0.0.1")
    await once(upstream, "listening")
    t.after(
      () =>
        new Promise((resolveClose) => {
          upstream.closeAllConnections()
          upstream.close(resolveClose)
        }),
    )
    const { child, exit, firstLine } = await launchBackend(t, {
      appToken,
      userToken,
      apiToken,
      akahuBaseURL: `http://127.0.0.1:${upstream.address().port}/v1`,
    })
    const ready = await firstLine
    const controller = new AbortController()
    const pending = fetch(`http://127.0.0.1:${ready.port}/accounts`, {
      headers: { Authorization: `Bearer ${apiToken}` },
      signal: controller.signal,
    })
    const rejected = assert.rejects(pending)
    await timeout(received)
    if (stop === "client disconnect") controller.abort()
    else child.stdin.end()
    await timeout(disconnected)
    await timeout(rejected)
    if (stop === "app shutdown") await timeout(exit, 4000)
  })
}

test("Akahu money fields reject non-finite strings without exposing source data", async (t) => {
  for (const field of ["current", "available", "limit", "amount"]) {
    for (const value of ["NaN", "Infinity", "-Infinity", "1e309"]) {
      await t.test(`${field}: ${value}`, async (t) => {
        const upstream = await fakeAkahu(
          t,
          field === "amount"
            ? { transactionAmount: value }
            : { accountBalance: { current: 123.45, currency: "NZD", [field]: value } },
        )
        const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
        const ready = await firstLine
        const path = field === "amount" ? "/transactions?from=2026-10-01&to=2026-10-20" : "/accounts"
        const response = await fetch(`http://127.0.0.1:${ready.port}${path}`, {
          headers: { Authorization: `Bearer ${apiToken}` },
        })
        assert.equal(response.status, 502)
        const body = await response.text()
        for (const privateValue of [value, "acc_main", "Grocer", appToken, userToken, apiToken]) {
          assert(!body.includes(privateValue), "upstream validation failure exposed source data")
        }
      })
    }
  }
})

test("Akahu finite money strings preserve account projections and transaction metadata", async (t) => {
  const upstream = await fakeAkahu(t, {
    accountBalance: { current: "-12.50", available: "0", limit: "250.75", currency: "NZD" },
    transactionAmount: "-25.50",
  })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}` }
  const accountResponse = await fetch(`${base}/accounts`, { headers })
  assert.equal(accountResponse.status, 200)
  const accounts = await accountResponse.json()
  assert.equal(accounts[0].balance, "-12.5")
  assert.equal(accounts[0].availableBalance, "0")
  assert.equal(accounts[0].creditLimit, "250.75")
  const transactionResponse = await fetch(`${base}/transactions?from=2026-10-01&to=2026-10-20`, { headers })
  assert.equal(transactionResponse.status, 200)
  const transactions = await transactionResponse.json()
  const food = transactions.find((transaction) => transaction.id === "food")
  assert.equal(food.amount, "-25.5")
  assert.equal(food.merchant, "Grocer")
  assert.equal(food.category, "Groceries")
})

test("invalid credentials fail startup without a public listener or secret output", async (t) => {
  const { firstLine, exit } = await launchBackend(t, { appToken, userToken, apiToken: "bad token" })
  assert.deepEqual(await firstLine, { event: "failed" })
  const [code] = await timeout(exit)
  assert.notEqual(code, 0)
})

// Keep the history fixture inside the live backend's six-month window as the test date changes.
function currentFixtureDates() {
  const today = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Pacific/Auckland",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date())
  const shift = Date.parse(`${today}T00:00:00Z`) - Date.parse("2026-10-20T00:00:00Z")
  const date = (value) => new Date(Date.parse(`${value}T00:00:00Z`) + shift).toISOString().slice(0, 10)
  return { today, date }
}

test("one dashboard reload shares paginated history across every section and the next reload reads fresh data", async (t) => {
  const { today, date } = currentFixtureDates()
  const upstream = await fakeAkahu(t, { transactionDate: date, transactionPageSize: 2 })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const snapshot = randomUUID()
  const headers = { Authorization: `Bearer ${apiToken}`, "X-Reckon-Snapshot": snapshot }
  const currentRange = `from=${date("2026-10-01")}&to=${today}&excludeTransfers=true`
  const historyRange = `from=${date("2026-07-01")}&to=${today}`
  const paths = [
    "/accounts",
    `/cashflow?${currentRange}`,
    `/spending?${currentRange}`,
    `/spending?from=${date("2026-07-01")}&to=${date("2026-09-30")}&excludeTransfers=true`,
    `/recurring?${historyRange}`,
    "/freshness",
    `/transactions?${historyRange}&limit=100&excludeTransfers=true`,
    "/forecast?days=30&excludeTransfers=true",
  ]
  const responses = await Promise.all(
    paths.map(async (path) => {
      const response = await fetch(`${base}${path}`, { headers })
      assert.equal(response.status, 200, `${path}: ${await response.clone().text()}`)
      return response.json()
    }),
  )
  assert.equal(responses[0].length, 3)
  assert.equal(responses[2].find((row) => row.category === "Groceries").spent, "25.5")
  assert.equal(responses[3].find((row) => row.category === "Rent").spent, "225")
  assert(responses[6].every((row) => !row.id.startsWith("transfer_")))
  assert.equal(responses[7].startingBalance, "1123.45")
  assert.equal(upstream.calls.filter((call) => new URL(call.url, base).pathname === "/v1/accounts").length, 2)
  const historyCalls = upstream.calls.filter((call) => call.url.includes("/transactions"))
  const urls = historyCalls.map((call) => call.url)
  assert.equal(new Set(urls).size, urls.length, "each history page must be fetched once per reload")
  assert.equal(historyCalls.filter((call) => new URL(call.url, base).pathname.endsWith("/pending")).length, 3)
  assert.equal(historyCalls.filter((call) => !new URL(call.url, base).pathname.endsWith("/pending")).length, 6)

  const food = upstream.transactions.find((row) => row._id === "food")
  food.amount = -30
  const repeated = await fetch(`${base}/spending?${currentRange}`, { headers })
  assert.equal((await repeated.json()).find((row) => row.category === "Groceries").spent, "25.5")
  const refreshed = await fetch(`${base}/spending?${currentRange}`, {
    headers: { ...headers, "X-Reckon-Snapshot": randomUUID() },
  })
  assert.equal((await refreshed.json()).find((row) => row.category === "Groceries").spent, "30")
  assert.equal(upstream.calls.filter((call) => call.url.includes("/transactions")).length, historyCalls.length * 2)
})

test("failed account and dashboard history reads can recover immediately", async (t) => {
  const { today, date } = currentFixtureDates()
  const injected = [{ status: 401, body: "private source failure" }]
  const upstream = await fakeAkahu(t, { responses: injected, transactionDate: date })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}`, "X-Reckon-Snapshot": randomUUID() }
  assert.equal((await fetch(`${base}/accounts`, { headers })).status, 502)
  assert.equal((await fetch(`${base}/accounts`, { headers })).status, 200)
  injected.push({ status: 401, body: "private history failure" })
  const path = `/spending?from=${date("2026-10-01")}&to=${today}&excludeTransfers=true`
  assert.equal((await fetch(`${base}${path}`, { headers })).status, 502)
  const recovered = await fetch(`${base}${path}`, { headers })
  assert.equal(recovered.status, 200)
  assert.equal((await recovered.json()).find((row) => row.category === "Groceries").spent, "25.5")
})

test("malformed snapshot IDs, repeated query keys, and invalid calendar dates fail before upstream calls", async (t) => {
  const upstream = await fakeAkahu(t)
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}` }
  for (const id of ["", "not-a-uuid", "a".repeat(4096)]) {
    const response = await fetch(`${base}/accounts`, { headers: { ...headers, "X-Reckon-Snapshot": id } })
    assert.equal(response.status, 400)
  }
  for (const path of [
    "/transactions?limit=1&limit=100",
    "/spending?from=2026-02-30",
    "/cashflow?to=not-a-date",
    "/recurring?from=2026-01-01&from=2026-02-01",
  ]) {
    assert.equal((await fetch(`${base}${path}`, { headers })).status, 400)
  }
  for (const path of ["/budgets", "/goals", "/categories", "/unusual", "/constructor", "/__proto__"]) {
    assert.equal((await fetch(`${base}${path}`, { headers })).status, 404)
  }
  assert.equal(upstream.calls.length, 0)
})

test("abandoning a dashboard cancels shared history and the same reload ID can recover", async (t) => {
  const { today, date } = currentFixtureDates()
  const started = Promise.withResolvers()
  const cancelled = Promise.withResolvers()
  let holdFirstHistoryRead = true
  const upstream = await fakeAkahu(t, {
    transactionDate: date,
    beforeResponse: (request, response) => {
      if (!holdFirstHistoryRead || !new URL(request.url, "http://localhost").pathname.endsWith("/transactions"))
        return false
      holdFirstHistoryRead = false
      response.once("close", cancelled.resolve)
      started.resolve()
      return true
    },
  })
  const { firstLine } = await launchBackend(t, { appToken, userToken, apiToken, akahuBaseURL: upstream.baseURL })
  const ready = await firstLine
  const base = `http://127.0.0.1:${ready.port}`
  const headers = { Authorization: `Bearer ${apiToken}`, "X-Reckon-Snapshot": randomUUID() }
  const path = `/spending?from=${date("2026-10-01")}&to=${today}&excludeTransfers=true`
  const controller = new AbortController()
  const abandoned = fetch(`${base}${path}`, { headers, signal: controller.signal })
  const rejected = assert.rejects(abandoned)
  await timeout(started.promise)
  controller.abort()
  await timeout(rejected)
  await timeout(cancelled.promise)
  const recovered = await fetch(`${base}${path}`, { headers })
  assert.equal(recovered.status, 200)
  assert.equal((await recovered.json()).find((row) => row.category === "Groceries").spent, "25.5")
})
