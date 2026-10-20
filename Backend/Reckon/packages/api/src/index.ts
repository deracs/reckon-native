import {
  Account,
  AccountFreshness,
  AccountId,
  BankCategory,
  BudgetStatus,
  DateRange,
  Forecast,
  FoundMoneySummary,
  GoalConfig,
  GoalId,
  GoalInput,
  GoalStatus,
  MerchantSummary,
  MonthlyCashflow,
  RecurringCharge,
  RoundUpSummary,
  SpendingByCategory,
  Transaction,
  UnusualTransaction,
} from "@reckon/domain";
import { Schema, SchemaGetter } from "effect";
import {
  HttpApi,
  HttpApiEndpoint,
  HttpApiError,
  HttpApiGroup,
  HttpApiMiddleware,
  HttpApiSecurity,
  OpenApi,
} from "effect/unstable/httpapi";

const Unauthorized = HttpApiError.Unauthorized.annotate({
  identifier: "Unauthorized",
  description:
    "Bearer token was missing, malformed, or didn't match `API_BEARER_TOKEN`. Returned as an empty 401 response.",
});

export class Authentication extends HttpApiMiddleware.Service<Authentication>()(
  "Authentication",
  {
    security: { bearer: HttpApiSecurity.bearer },
    error: Unauthorized,
  },
) {}

// HTTP query strings are always strings; this transforms the literals
// "true" / "false" into a real Boolean so endpoint handlers see a typed
// `excludeTransfers?: boolean`.
const BooleanFromString = Schema.Literals(["true", "false"]).pipe(
  Schema.decodeTo(Schema.Boolean, {
    decode: SchemaGetter.transform((s) => s === "true"),
    encode: SchemaGetter.transform((b) => (b ? "true" : "false")),
  }),
);

const excludeTransfers = {
  excludeTransfers: Schema.optional(BooleanFromString),
};

// Query strings can only carry strings; map "1" / "2" / "5" into the
// numeric RoundUpUnit literal so handlers see a typed `unit: 1 | 2 | 5`.
const RoundUpUnitFromString = Schema.Literals(["1", "2", "5"]).pipe(
  Schema.decodeTo(Schema.Literals([1, 2, 5]), {
    decode: SchemaGetter.transform((s) => Number(s) as 1 | 2 | 5),
    encode: SchemaGetter.transform((n) => String(n) as "1" | "2" | "5"),
  }),
);

const bankGroup = HttpApiGroup.make("bank")
  .add(
    HttpApiEndpoint.get("listAccounts", "/accounts", {
      success: Schema.Array(Account),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "List connected bank accounts",
        description:
          "Returns every account Akahu has connected for the current user — checking, savings, credit, loans, investments. Includes balance, currency, bank name and logo, and freshness timestamps.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("searchTransactions", "/transactions", {
      query: {
        ...DateRange,
        query: Schema.optional(Schema.String),
        accountId: Schema.optional(Schema.String),
        category: Schema.optional(Schema.String),
        limit: Schema.optional(Schema.NumberFromString),
        ...excludeTransfers,
      },
      success: Schema.Array(Transaction),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Search transactions",
        description:
          "Filter transactions by free-text query, account, effective category, and ISO date range. Rules and manual overrides are resolved before filtering and limiting (default 25, max 100). Uncategorised includes blank and placeholder categories. Amounts are signed — negative is outflow.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("summarizeSpending", "/spending", {
      query: { ...DateRange, ...excludeTransfers },
      success: Schema.Array(SpendingByCategory),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Spending grouped by category",
        description:
          "Outflows only, summed by effective category (manual overrides, rules, then source category) for the given date range. Inter-account transfers are excluded by default.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("summarizeCashflow", "/cashflow", {
      query: { ...DateRange, ...excludeTransfers },
      success: Schema.Array(MonthlyCashflow),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Monthly cashflow",
        description:
          "Per-month income, spending, and net for the given window. Drives the cashflow chart.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("listRecurringCharges", "/recurring", {
      query: {
        ...DateRange,
        minOccurrences: Schema.optional(Schema.NumberFromString),
      },
      success: Schema.Array(RecurringCharge),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Detected recurring charges (standing orders)",
        description:
          "Clusters transactions into recurring patterns: weekly / fortnightly / monthly / quarterly. The data behind *Standing orders*. Set `minOccurrences` to tighten the detection threshold.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("findUnusualTransactions", "/unusual", {
      query: {
        ...DateRange,
        threshold: Schema.optional(Schema.NumberFromString),
        minBaseline: Schema.optional(Schema.NumberFromString),
      },
      success: Schema.Array(UnusualTransaction),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Unusual transactions",
        description:
          "Outliers vs the user's per-category median, intended for proactive flagging. Defaults: `threshold=3` (3× median), `minBaseline=5` (need at least 5 prior transactions in the category before flagging).",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("topMerchants", "/merchants", {
      query: {
        ...DateRange,
        limit: Schema.optional(Schema.NumberFromString),
        direction: Schema.optional(Schema.Literals(["spending", "income"])),
        ...excludeTransfers,
      },
      success: Schema.Array(MerchantSummary),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Top merchants by amount",
        description:
          "Largest counterparties by total spend (default) or by income (`direction=income`). Useful for identifying concentration and the largest discretionary lines.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("summarizeRoundUps", "/round-ups", {
      query: {
        ...DateRange,
        unit: RoundUpUnitFromString,
        ...excludeTransfers,
        merchantLimit: Schema.optional(Schema.NumberFromString),
      },
      success: RoundUpSummary,
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Round-up savings simulator",
        description:
          "A 'save the change' round-up projection. For each outgoing transaction in the range, rounds spend up to the nearest `$unit` (1, 2, or 5) and returns total simulated savings, plus breakdowns by month, day, and top contributing merchants.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("listCategories", "/categories", {
      success: Schema.Array(BankCategory),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "List source-assigned categories",
        description:
          "The source taxonomy combined with accepted custom categories. Category IDs are stable; transaction categories and budgets continue to use names.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("getDataFreshness", "/freshness", {
      success: Schema.Array(AccountFreshness),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Per-account refresh timestamps",
        description:
          "When each account last had its balance / transactions / party / meta refreshed by Akahu. Use to decide whether to call `/refresh` before pulling fresh data.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post("refresh", "/refresh", {
      success: Schema.Struct({ ok: Schema.Boolean }),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Trigger an Akahu refresh",
        description:
          "Async — Akahu rate-limits the upstream pull. Returns immediately. Real data lands in subsequent calls (check `/freshness` to confirm).",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("budgetStatus", "/budgets", {
      query: {
        month: Schema.optional(Schema.String),
        categories: Schema.optional(Schema.Array(Schema.String)),
      },
      success: Schema.Array(BudgetStatus),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Per-category budget status",
        description:
          "Reads `~/.personal-bank-budgets.json` (override with `PERSONAL_BANK_BUDGETS_PATH`). For each configured category: spent, % used, % of month elapsed, projected end-of-month spend, and a `status` of under / on_pace / over / exceeded.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("forecastCashflow", "/forecast", {
      query: {
        days: Schema.optional(Schema.NumberFromString),
        ...excludeTransfers,
      },
      success: Forecast,
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Dead reckoning — N-day balance forecast",
        description:
          "Projects daily liquid balance for the next `days` (default 30) by overlaying detected recurring charges and recurring income onto current NZD checking + savings balances. Returns risk dates where the balance crosses zero.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("listGoals", "/goals", {
      success: Schema.Array(GoalConfig),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "List savings goals",
        description:
          "Returns all configured savings goals with their target amounts, linked accounts, and date window.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("goalStatus", "/goals/status", {
      success: Schema.Array(GoalStatus),
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Live savings goal progress",
        description:
          "Enriches each goal with current balance, progress percentage, save rate, projected completion date, and on-track status.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.get("foundMoney", "/found-money", {
      success: FoundMoneySummary,
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Reclaimable money this month",
        description:
          "Derives per-bucket amounts from existing signals — round-up savings, headroom under category budgets, and total standing-orders burn. Returns a `reclaimable` monthly total you could bank now without changing behaviour.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.post("upsertGoal", "/goals", {
      payload: GoalInput,
      success: GoalConfig,
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Create or update a savings goal",
        description:
          "Omit `id` to create a new goal; pass an existing `id` to update it. `accountIds` must be non-empty and `targetAmount` must be positive.",
      }),
    ),
  )
  .add(
    HttpApiEndpoint.delete("deleteGoal", "/goals/:id", {
      params: Schema.Struct({ id: GoalId }),
      success: Schema.Void,
    }).annotateMerge(
      OpenApi.annotations({
        summary: "Delete a savings goal",
        description: "Permanently removes the goal. Linked account data is unaffected.",
      }),
    ),
  )
  .middleware(Authentication)
  .annotateMerge(
    OpenApi.annotations({
      title: "Bank",
      description:
        "Read-mostly access to the user's NZ bank data via Akahu — accounts, transactions, derived summaries, forecast.",
    }),
  );

export const bankApi = HttpApi.make("reckon")
  .add(bankGroup)
  .annotateMerge(
    OpenApi.annotations({
      title: "Reckon",
      version: "0.1.0",
      description: [
        "Personal bank data, served as REST.",
        "",
        "Every operation here is also exposed over Effect RPC (`POST /rpc`) and as an MCP tool — same `BankData` domain, three surfaces. Authentication is a bearer token (`API_BEARER_TOKEN`).",
        "",
        "This API is for the single user it was built for; semantics are read-mostly and not multi-tenant.",
      ].join("\n"),
    }),
  );
