# Project context — language, voice, vibe

This document is the shared vocabulary for the project. New contributors (human or agent) should read this before writing code, copy, or documentation. If a term here conflicts with something you're about to write, change what you're writing — not the term.

The project has two parts that share a voice:

- **`personal-bank-mcp`** — the Effect v4 MCP server. Exposes the user's NZ bank data (via Akahu) as tools for Claude to read. Lives in `apps/mcp` with the domain split into `packages/domain` (BankData service + pure helpers) and `packages/akahu` (the adapter). `apps/cli` is a CLI on the same domain. `packages/rpc` exposes the same domain as an RpcGroup, served (alongside the REST API at `/docs`) by `apps/server`.
- **Reckon** — the always-live personal-finance **web app**. Reflects the current Akahu mirror whenever you open it. Currently single-user (built for the author), but the design and voice anticipate productisation later. Lives in `apps/web` (TanStack Start; routes-only) and `packages/ui` (the design system: Tailwind v4 tokens, Base UI primitives, shadcn-style components).

The same voice runs through both: honest, direct, specific, no fluff. The code is terse for the same reason the copy is.

---

## Ubiquitous language

### Bank-data domain (MCP backend)

| Term | Meaning |
|---|---|
| **Account** | A single bank/wallet at the source. Has `id`, `name`, `type` (checking / savings / investment), `currency`, `balance`. |
| **Transaction** | A single debit or credit on an account. Amount is signed (negative = outflow). |
| **Merchant** | Normalised counterparty name (e.g. "PAK'nSAVE"). Distinct from the raw transaction `description`. |
| **Source category** | Category supplied by Akahu. Preserved in the raw transaction mirror. |
| **Effective category** | Category shown in Reckon and used for search, spending and budgets: explicit transaction override first, then category rules, then the source category. |
| **Custom category** | A named category created when a reviewed suggestion is accepted. Has a stable ID and a unique trimmed, whitespace-collapsed, case-normalised name. Differently named categories remain distinct. Transactions and budgets still store category names. |
| **Uncategorised** | An effective category that is missing, blank, or a normalised “uncategorised” / “uncategorized” placeholder. Explicit manual overrides remain protected, including an explicit uncategorised choice. |
| **Categorisation preview** | A persisted set of eligible transactions under a date, account and search scope, grouped by conservative merchant/description name variants, direction and currency. Original variants are retained for exact remembered matches. Model suggestions are reviewed before any categories or assignments are written. Detected transfers are excluded. |
| **Remembered match** | An optional category rule accepted during review. Fills eligible missing categories across the mirror and future matching transactions; uses exact merchant/description, direction and currency, excludes transfers, and preserves manual choices. |
| **Liquid balance** | Sum of NZD checking + savings accounts only. **Excludes** investments and dust foreign-currency wallets (USD/AUD/etc.). The number that matters week-to-week. |
| **Cashflow** | Per-month `{income, spending, net}` over a window. Inter-account transfers excluded by default. |
| **Spending** | Outflows only, grouped by category. Inter-account transfers excluded by default. |
| **Inter-account transfer** | A debit/credit pair across two of the user's own accounts within ~3 days. Excluded from spending and cashflow unless explicitly investigated. |
| **Recurring charge** | A merchant + amount + cadence cluster — weekly / fortnightly / monthly / quarterly debit. The data behind *standing orders* in the Reckon UI. |
| **Unusual transaction** | A debit ≥ 3× the per-category median, with a minimum baseline count. Surfaced for proactive flagging. |
| **Trailing average** | Default comparison window is trailing 3 months. "↑ 18% vs avg" always means vs trailing-3mo unless stated otherwise. |
| **Freshness** | Per-account `balanceRefreshedAt` / `transactionsRefreshedAt` timestamps. Data is considered fresh if the most recent transaction refresh is < 12 hours old. |
| **Refresh** | A request to the bank source to repull data. Async, rate-limited upstream — call sparingly. |
| **Forecast** | Projected balance over the next N days, using recurring charges + average discretionary burn. Surfaces *risk dates* — first day a checking account goes negative. |
| **Budget** | User-defined monthly cap per category. Stored in Postgres (`budgets` table); the `/budgets` UI was retired in the IA collapse, so budgets are read via MCP and managed through RPC or REST for now. Empty by default. |
| **Goal** | A user-defined savings target — an amount, linked savings account(s), a start date, and an optional deadline. Stored in Postgres (`savings_goals`). Progress is *derived* from real net inflow to the linked accounts since the start date. |
| **Save rate** | Trailing-3-month average monthly net inflow to a goal's linked accounts. Drives the goal's ETA. |

### Reckon product language

Reckon is an always-live view of the current Akahu mirror. These are the section names used in UI, copy, and conversation:

| Term | Meaning |
|---|---|
| **The bleed** | Top spending categories with deltas vs trailing average. *Not* "where it's going" or "spending breakdown". |
| **Standing orders** | Recurring charges (subscriptions, memberships, regular bills). *Not* "subscriptions" — Standing orders is more accurate (rent and insurance aren't subscriptions) and reads more Kiwi/UK than American. |
| **Dead reckoning** | The forecast view. Plays on the nautical "navigating by calculation" meaning. *Not* "forecast" or "projection" in user-facing copy. |

### Engineering domain (the codebase)

The architecture is **Hexagonal / Ports & Adapters** on Effect v4 — one PNPM workspace package per bounded responsibility, with `apps/*` as thin composition roots that wire layers together.

| Term | Meaning |
|---|---|
| **Port** | An Effect `Context.Service` interface in `@reckon/domain` (e.g. `BankData`). Defines what the domain needs without saying how it's provided. |
| **Adapter** | A workspace package that supplies a `Layer.Layer<Port>`. `@reckon/akahu` supplies source data; `@reckon/postgres` and `@reckon/d1` supply mirror persistence. `@reckon/typesafe` implements the classifier port. |
| **Bounded context** | One workspace package per responsibility — `domain` (contracts + pure helpers), `categorisation` (review workflow), `typesafe` (classifier adapter), `akahu` (source adapter), `rpc` / `api` (wire contracts), `ui` (presentation), `telemetry` (observability). Cross-package imports go only through each package's `index.ts`. |
| **Wire schema** | Schema that decodes an external system's response (e.g. `AkahuAccount` in `@reckon/akahu/wire.ts`). Never crosses package boundaries; adapters project wire → domain types in `toBank*()` methods. |
| **Layer** | An Effect `Layer<R, E, A>` providing one or more services. Each adapter exports exactly one composite Layer that satisfies the port it implements. |
| **Service** | An Effect `Context.Service` — the unit of dependency injection. |
| **Composition root** | The single `Effect.gen` block at the top of each app's `main.ts` that picks which adapter layers to provide. Apps stay thin — domain code and presentation live in packages. |
| **Derivation helpers** | Pure functions in `@reckon/domain/derivations.ts` that operate over already-fetched transactions (`filterTransfers`, `summarizeMonthlyCashflow`, `forecastCashflow`, etc.). Reusable across any `BankData` implementation. |

---

## Voice — Reckon (user-facing)

The product carries two registers in tension, and **both matter**:

1. **The opinion register** — *"what do you reckon?"* — Kiwi vernacular, conversational, no fluff.
2. **The accounting register** — *reckoning*, *day of reckoning*, *dead reckoning*. Older, heavier. Accountability, settling accounts, facing the numbers.

If the product sounds only like (1), it's a mate at the pub. Only like (2), it's a bank. We want both — the mate at the pub who happens to be an accountant.

### Rules

- **Honest, not encouraging.** No "you've got this", no "keep it up". Milestone moments are allowed when a goal is hit, but they stay dated and dollar'd ("Done. $15,000 banked, three weeks ahead of target.") — never streaks, XP, levels, points, badges, or confetti.
- **Every recommendation has a dollar figure.** "Cut grocery spend by ~$200/mo" beats "track your spending".
- **Comparisons over totals.** "$180 on takeaways, 18% above your trailing 3-mo avg" beats "$180 on takeaways".
- **Specific not generic.** "Switch supermarket chains — the cheaper one is 12% less on your basket" beats "shop more cheaply".
- **No therapy speech.** The user wants the read, not the hug.
- **No emoji.**
- **No exclamation marks.** Even when the news is good.
- **Reckon is a noun.** *"Reckon's take this week"*, *"Reckon flagged 3 things"*. Used sparingly — once or twice per view.
- **Avoid *"Reckon reckons…"*** outside of rare playful moments.

### Sentence shapes that fit

- *"Running −$240/mo for four straight months."*
- *"Your spending account hit $4.10 — that's an overdraft fee incoming."*
- *"Most of the grocery spend goes to the most expensive chain, not the cheapest."*
- *"Bank the whole increase. The budget already balanced without it."*

### Sentence shapes that don't

- *"Great job staying under budget this week! 🎉"*
- *"Take control of your finances with Reckon."*
- *"You might want to consider reviewing your spending."*
- *"Smart insights powered by AI."*

---

## Voice — engineering (code & docs)

The code carries the same register. Effect v4 lends itself to this — terse, declarative, no incidental scaffolding.

- **Default to no comments.** Only add one when the *why* is non-obvious. Never explain the *what*.
- **No flourish in PR descriptions or commit messages.** What changed, why, in two sentences.
- **No backwards-compat hacks** for code only Reckon uses. Delete the old thing.
- **No premature abstraction.** Three similar lines beats a wrong abstraction.
- **Effect-first.** Consult `effect-solutions` before writing Effect code; never guess at patterns.
- **One bounded context = one module.** Cross-context references use branded IDs only.

---

## What this project is not

Useful as a tone-calibration check:

- Not a budgeting app — Reckon doesn't help you set budgets, it tells you when your existing one isn't holding.
- Categorisation is user-requested and reviewed. Reckon can suggest existing categories and users can enter custom categories during review; it does not run unattended categorisation or silently replace manual choices.
- Not investment advice — investment balances are surfaced, not analysed.
- Not game-y — no streaks, no XP, no levels, no badges, no confetti. Savings goals and honest milestones are in; the dopamine loop is not.
- Always-live — the weekly brief is retired. Reckon reflects the current Akahu mirror whenever you open it.
- Not American — *standing orders*, *PAK'nSAVE*, *fortnightly*, NZD-first. The product is built for NZ and reads that way.


## Categorisation implementation

`CategorisationRpcs` joins `BankRpcs` at `/rpc` on the Node server and API Worker. It exposes capability, start/load preview, generate next batch, single-transaction review, background start/status/pause, remembered-rule reach and apply operations. There are no new MCP or CLI commands. See [categorisation.md](categorisation.md) for configuration and recovery.

Previews retain their scope, exact transaction membership and fingerprints, suggestions, model/prompt versions, and group application status. Up to 20 groups are classified in one TypeSafe System One request with a 60-second timeout. Jev chooses an existing category or leaves the group unresolved; custom category names remain a manual review edit. Completed batches survive later failures and reloads. Transaction descriptions are untrusted data; the model receives no credentials, account IDs, transaction IDs or account numbers.

An expanded non-transfer transaction can be reviewed independently by Jev, including when it already has a category. The current category is not sent to the classifier. The UI shows confidence and the closest existing-category alternatives, while accepting a suggestion still requires the normal reviewed single-transaction or remembered-match save action.

Application does not call the model. Every group rechecks fingerprints and effective categories, then atomically writes accepted overrides, an optional custom category and remembered rule, and its completion status. Database revision guards detect concurrent mirror, rule and manual edits. A repeated application does not replace later edits or duplicate categories/rules. Changed members are skipped and excluded from that group's remembered rule. Raw Akahu rows remain unchanged by categorisation.

Hosted suggestion generation runs as a Cloudflare Workflow, one durable step per batch. The browser polls persisted results and can close without cancelling the job. The Node server uses a server-owned background fiber; a process restart requires resuming the persisted preview. Generation stays user-requested, and acceptance stays manual.
