// The Flag — the unit of the "Reckon as Linear" pipeline. A flag is an
// actionable, data-verified item you process to zero in the Inbox. This is
// the start of the @reckon/flags bounded context; for now it
// lives in @reckon/domain so detectors can sit beside the derivations they
// reuse. Slice 1 is detection only — stateless, derive-on-read, in `triage`
// state. Persisted lifecycle (snooze/act/dismiss + resolve predicates +
// reopen-on-regression) and the per-sync evaluation loop come later.
//
// A well-formed flag carries a Trigger (the detector below), an Action (the
// decision it demands) and — once persistence lands — a resolve predicate.
// Every flag carries a dollar `impact` and a stable natural `key` so a future
// FlagStore can upsert by it and Dismiss-suppression has something stable to
// target. Detectors here build on aggregates that don't retain transaction
// ids, so `sourceTransactionIds` is empty for now.

import { BigDecimal, Schema } from "effect"
import {
  type Forecast,
  type GoalStatus,
  type MonthlyCashflow,
  type RecurringCharge,
  TransactionId,
} from "./BankData.js"
import { addDays } from "./derivations.js"

const ZERO = BigDecimal.fromNumberUnsafe(0)
const bd = BigDecimal.fromNumberUnsafe
const toNum = BigDecimal.toNumberUnsafe
const round2 = (n: BigDecimal.BigDecimal): BigDecimal.BigDecimal =>
  BigDecimal.round(n, { scale: 2, mode: "half-from-zero" })

// Dollar formatting for flag copy: whole dollars when integral, else 2dp.
const money = (n: BigDecimal.BigDecimal): string => {
  const v = toNum(round2(n))
  return `$${Number.isInteger(v) ? v.toString() : v.toFixed(2)}`
}

const DEFAULT_CURRENCY = "NZD"

// Stable natural identity for a flag (e.g. "structural_deficit",
// "new_standing_order:netflix", "goal_slipping:goal-1"). Deterministic across
// syncs so the same real-world situation maps to the same flag.
export const FlagKey = Schema.String.pipe(Schema.brand("FlagKey"))
export type FlagKey = typeof FlagKey.Type

export const FlagType = Schema.Literals([
  "risk_date",
  "new_standing_order",
  "goal_slipping",
  "structural_deficit",
  "standing_order_hike",
]).annotate({
  description:
    "Which detector raised the flag — including standing_order_hike, a known recurring charge jumping above its own baseline. (Fee-incurred is deferred — no fee primitive in the mirror yet.)",
})
export type FlagType = typeof FlagType.Type

export const FlagStatus = Schema.Literals([
  "triage",
  "snoozed",
  "acting",
  "resolved",
  "dismissed",
]).annotate({
  description:
    "Lifecycle state. Detection raises flags in 'triage'; the human moves to snoozed/acting/dismissed; the data resolves/reopens (persistence is a later slice).",
})
export type FlagStatus = typeof FlagStatus.Type

export const Flag = Schema.Struct({
  key: FlagKey.annotate({
    description: "Stable natural identity, deterministic across syncs.",
  }),
  type: FlagType,
  status: FlagStatus,
  title: Schema.String.annotate({
    description: "Short headline for the flag card.",
  }),
  action: Schema.String.annotate({
    description: "The decision the flag demands of you. No action ⇒ not a flag.",
  }),
  impact: Schema.BigDecimalFromString.annotate({
    description: "Dollar figure for the flag (positive magnitude).",
  }),
  impactLabel: Schema.String.annotate({
    description: "What the dollar figure means (e.g. 'Annualised cost').",
  }),
  currency: Schema.String.annotate({
    description: "Currency code (e.g. 'NZD').",
  }),
  structural: Schema.Boolean.annotate({
    description:
      "True for recurring/ongoing flags. Weights pinned-red-flag selection toward structural over one-off.",
  }),
  sourceTransactionIds: Schema.Array(TransactionId).annotate({
    description: "Transactions the flag cites. Empty for aggregate-derived flags.",
  }),
  date: Schema.optional(
    Schema.String.annotate({
      description: "Relevant anchor date (YYYY-MM-DD), e.g. the risk date.",
    }),
  ),
  detail: Schema.optional(
    Schema.String.annotate({
      description: "Blunt, dated/dollar'd one-line explanation.",
    }),
  ),
  merchant: Schema.optional(
    Schema.String.annotate({
      description: "Counterparty the flag is about (standing-order flags) — used for evidence drill-links.",
    }),
  ),
  note: Schema.optional(
    Schema.String.annotate({
      description: "Lifecycle note attached by the engine or the human (e.g. a regression note).",
    }),
  ),
  firstSeen: Schema.optional(
    Schema.String.annotate({
      description:
        "Date (YYYY-MM-DD) this flag's key was first sighted — drives carried-cycle pressure.",
    }),
  ),
})
export type Flag = typeof Flag.Type

// The Inbox: at most one pinned red flag, the rest in a prioritised queue.
export const FlagInbox = Schema.Struct({
  pinned: Schema.optional(Flag).annotate({
    description: "The single promoted red flag, if any open flags exist.",
  }),
  queue: Schema.Array(Flag).annotate({
    description: "Remaining open flags, prioritised (highest first).",
  }),
})
export type FlagInbox = typeof FlagInbox.Type

// A persisted human action on a flag, keyed by the flag's stable key. This is
// the sidecar that holds lifecycle state — detection stays pure and
// derive-on-read; only the human's snooze/act/dismiss lives here, never on the
// Akahu-sourced rows.
export const FlagState = Schema.Struct({
  key: FlagKey,
  status: FlagStatus,
  snoozeUntil: Schema.optional(
    Schema.String.annotate({
      description: "Wake date (YYYY-MM-DD) for a snoozed flag.",
    }),
  ),
  expiresAt: Schema.optional(
    Schema.String.annotate({
      description:
        "Date (YYYY-MM-DD) a dismissal stops suppressing, so a materially-changed pattern can resurface.",
    }),
  ),
  note: Schema.optional(
    Schema.String.annotate({
      description: "Optional note attached when acting on or dismissing a flag.",
    }),
  ),
  expectedImpact: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description:
        "Dollar outcome committed to at Act time — compared against the verified figure on the receipt.",
    }),
  ),
})
export type FlagState = typeof FlagState.Type

// ── detectors (triggers) ─────────────────────────────────────────────────

// Risk date — dead reckoning projects the balance into the red before income
// lands. Anchored to the earliest breach; impact is the deepest shortfall.
export const detectRiskDateFlag = (
  forecast: Forecast,
  options: { currency?: string } = {},
): Flag | undefined => {
  if (forecast.risks.length === 0) return undefined
  const date = forecast.risks.reduce(
    (earliest, r) => (r.date < earliest ? r.date : earliest),
    forecast.risks[0].date,
  )
  const shortfall = round2(
    forecast.risks.reduce((worst, r) => {
      const magnitude = BigDecimal.isLessThan(r.projectedBalance, ZERO)
        ? BigDecimal.abs(r.projectedBalance)
        : ZERO
      return BigDecimal.max(worst, magnitude)
    }, ZERO),
  )
  return {
    key: FlagKey.make("risk_date"),
    type: "risk_date",
    status: "triage",
    title: "Risk date",
    action: `Move money or cut a planned spend before ${date}.`,
    impact: shortfall,
    impactLabel: "Projected shortfall",
    currency: options.currency ?? DEFAULT_CURRENCY,
    structural: false,
    sourceTransactionIds: [],
    date,
    detail: `Checking projected to reach -${money(shortfall)} on ${date} before income lands.`,
  }
}

const PERIODS_PER_YEAR: Record<RecurringCharge["cadence"], number> = {
  weekly: 52,
  fortnightly: 26,
  monthly: 12,
  quarterly: 4,
}

// New standing order — a recurring-charge cluster that first appeared within
// the recency window. ("New since last seen" needs the FlagStore; this is the
// stateless proxy.) Impact is the annualised cost.
export const detectNewStandingOrderFlags = (
  recurring: ReadonlyArray<RecurringCharge>,
  today: string,
  options: { withinDays?: number; currency?: string } = {},
): ReadonlyArray<Flag> => {
  const cutoff = addDays(today, -(options.withinDays ?? 35))
  return recurring
    .filter((charge) => charge.firstDate >= cutoff)
    .map((charge) => {
      const avg = BigDecimal.abs(charge.averageAmount)
      const annualised = round2(
        BigDecimal.multiply(avg, bd(PERIODS_PER_YEAR[charge.cadence])),
      )
      return {
        key: FlagKey.make(`new_standing_order:${charge.merchant.toLowerCase()}`),
        type: "new_standing_order" as const,
        status: "triage" as const,
        title: `New standing order: ${charge.merchant}`,
        action: "Keep it or cancel it.",
        impact: annualised,
        impactLabel: "Annualised cost",
        currency: options.currency ?? DEFAULT_CURRENCY,
        structural: true,
        sourceTransactionIds: [],
        merchant: charge.merchant,
        detail: `${charge.merchant} now recurring at ${money(avg)} ${charge.cadence}, ${money(annualised)}/yr.`,
      }
    })
}

// Standing-order hike — a known recurring charge jumps above its own
// baseline. Baseline = the cluster average excluding the most recent charge;
// a hike older than the window has become the new normal and the flag
// retires (newness semantics, like new_standing_order). The recurring
// detector's variance ceiling means extreme repricings split the cluster
// and resurface as a *new* standing order instead — also a usable signal.
export const detectStandingOrderHikeFlags = (
  recurring: ReadonlyArray<RecurringCharge>,
  today: string,
  options: {
    hikePct?: number
    withinDays?: number
    minOccurrences?: number
    currency?: string
  } = {},
): ReadonlyArray<Flag> => {
  const hikePct = options.hikePct ?? 0.2
  const minOccurrences = options.minOccurrences ?? 4
  const cutoff = addDays(today, -(options.withinDays ?? 35))
  const out: Array<Flag> = []
  for (const charge of recurring) {
    if (charge.lastAmount === undefined) continue
    if (charge.occurrences < minOccurrences) continue
    if (charge.lastDate < cutoff) continue
    const last = BigDecimal.abs(charge.lastAmount)
    const prior = BigDecimal.divideUnsafe(
      BigDecimal.subtract(BigDecimal.abs(charge.totalSpent), last),
      bd(charge.occurrences - 1),
    )
    if (toNum(last) <= toNum(prior) * (1 + hikePct)) continue
    const annualised = round2(
      BigDecimal.multiply(
        BigDecimal.subtract(last, prior),
        bd(PERIODS_PER_YEAR[charge.cadence]),
      ),
    )
    out.push({
      key: FlagKey.make(`standing_order_hike:${charge.merchant.toLowerCase()}`),
      type: "standing_order_hike",
      status: "triage",
      title: `Standing-order hike: ${charge.merchant}`,
      action: "Accept the new price, or push back / cancel.",
      impact: annualised,
      impactLabel: "Annualised increase",
      currency: options.currency ?? DEFAULT_CURRENCY,
      structural: true,
      sourceTransactionIds: [],
      merchant: charge.merchant,
      date: charge.lastDate,
      detail: `${charge.merchant} averaged ${money(round2(prior))}, last charge ${money(last)} — ${money(annualised)}/yr more if it sticks.`,
    })
  }
  return out
}

// Goal slipping — a goal whose trailing save-rate has fallen behind what its
// deadline needs. Impact is the extra per-month required to recover.
export const detectGoalSlippingFlags = (
  goalStatuses: ReadonlyArray<GoalStatus>,
  options: { currency?: string } = {},
): ReadonlyArray<Flag> =>
  goalStatuses
    .filter((g) => g.status === "behind" && g.requiredMonthly !== undefined)
    .map((g) => {
      const extra = round2(
        BigDecimal.max(ZERO, BigDecimal.subtract(g.requiredMonthly!, g.saveRate)),
      )
      return {
        key: FlagKey.make(`goal_slipping:${g.id}`),
        type: "goal_slipping" as const,
        status: "triage" as const,
        title: `${g.name} is slipping`,
        action: "Raise the contribution or move the deadline.",
        impact: extra,
        impactLabel: "Extra per month to recover",
        currency: options.currency ?? g.currency ?? DEFAULT_CURRENCY,
        structural: false,
        sourceTransactionIds: [],
        detail: `Saving ${money(g.saveRate)}/mo, needs ${money(g.requiredMonthly!)}/mo to hit the deadline.`,
      }
    })

// Structural deficit — the last N *complete* months all ran net-negative. The
// current (incomplete) month is excluded so fortnightly pay timing can't flip
// it. Impact is the average monthly deficit.
export const detectStructuralDeficitFlag = (
  monthly: ReadonlyArray<MonthlyCashflow>,
  today: string,
  options: { months?: number; currency?: string } = {},
): Flag | undefined => {
  const months = Math.max(2, options.months ?? 3)
  const currentMonth = today.slice(0, 7)
  const complete = monthly
    .filter((m) => m.month < currentMonth)
    .sort((a, b) => a.month.localeCompare(b.month))
  const window = complete.slice(-months)
  if (window.length < months) return undefined
  if (!window.every((m) => BigDecimal.isLessThan(m.net, ZERO))) return undefined

  const totalDeficit = window.reduce(
    (acc, m) => BigDecimal.sum(acc, BigDecimal.abs(m.net)),
    ZERO,
  )
  const deficit = round2(BigDecimal.divideUnsafe(totalDeficit, bd(months)))
  return {
    key: FlagKey.make("structural_deficit"),
    type: "structural_deficit",
    status: "triage",
    title: "Structural deficit",
    action: `Commit a structural cut of about ${money(deficit)}/mo.`,
    impact: deficit,
    impactLabel: "Monthly deficit",
    currency: options.currency ?? DEFAULT_CURRENCY,
    structural: true,
    sourceTransactionIds: [],
    detail: `Net negative ${months} months running, averaging -${money(deficit)}/mo.`,
  }
}

// ── composition + state overlay ──────────────────────────────────────────

// Run every MVP detector over the inputs a single sync provides. Flags come
// out in `triage`; the adapter overlays stored human actions and prioritises.
export const detectAllFlags = (input: {
  readonly forecast: Forecast
  readonly recurring: ReadonlyArray<RecurringCharge>
  readonly goalStatuses: ReadonlyArray<GoalStatus>
  readonly monthly: ReadonlyArray<MonthlyCashflow>
  readonly today: string
  readonly options?: {
    readonly currency?: string
    readonly structuralDeficitMonths?: number
    readonly newWithinDays?: number
  }
}): ReadonlyArray<Flag> => {
  const currency = input.options?.currency
  const flags: Array<Flag> = []
  const risk = detectRiskDateFlag(input.forecast, { currency })
  if (risk) flags.push(risk)
  flags.push(
    ...detectNewStandingOrderFlags(input.recurring, input.today, {
      currency,
      withinDays: input.options?.newWithinDays,
    }),
  )
  flags.push(...detectStandingOrderHikeFlags(input.recurring, input.today, { currency }))
  flags.push(...detectGoalSlippingFlags(input.goalStatuses, { currency }))
  const deficit = detectStructuralDeficitFlag(input.monthly, input.today, {
    currency,
    months: input.options?.structuralDeficitMonths,
  })
  if (deficit) flags.push(deficit)
  return flags
}

// Overlay persisted human actions onto freshly-detected flags to produce the
// OPEN set for the inbox. Resolution is implicit (always-live): a flag that is
// no longer detected simply stops appearing. Snoozed flags wake when their
// date passes; dismissed flags are suppressed until their expiry, then
// resurface — so the inbox can't go permanently blind to a changed pattern.
export const applyFlagStates = (
  flags: ReadonlyArray<Flag>,
  states: ReadonlyArray<FlagState>,
  today: string,
): ReadonlyArray<Flag> => {
  const byKey = new Map(states.map((s) => [s.key, s] as const))
  const open: Array<Flag> = []
  for (const flag of flags) {
    const state = byKey.get(flag.key)
    if (state === undefined) {
      open.push(flag)
      continue
    }
    switch (state.status) {
      case "dismissed":
        if (state.expiresAt !== undefined && state.expiresAt <= today) {
          open.push(flag)
        }
        break
      case "snoozed":
        if (state.snoozeUntil === undefined || state.snoozeUntil <= today) {
          open.push(flag)
        }
        break
      case "acting":
        open.push({ ...flag, status: "acting" })
        break
      case "triage":
        // A regression reset: open, with the engine's note attached.
        open.push({ ...flag, note: state.note })
        break
      default:
        open.push(flag)
    }
  }
  return open
}

// ── inbox prioritisation ─────────────────────────────────────────────────

// Deterministic baseline ordering: structural before one-off, then larger
// dollar impact, then key for a stable tie-break. The deferred AI layer (B)
// may later re-order/re-phrase, but never changes membership. At most one
// flag is pinned as the red flag. When `today` is given, carried cycles
// outrank dollar impact within a structural tier — stale flags get louder.
export const buildFlagInbox = (
  flags: ReadonlyArray<Flag>,
  today?: string,
): FlagInbox => {
  const carried = (f: Flag): number =>
    today === undefined ? 0 : carriedCycles(f.firstSeen, today)
  const ordered = [...flags].sort(
    (a, b) =>
      Number(b.structural) - Number(a.structural) ||
      carried(b) - carried(a) ||
      toNum(BigDecimal.subtract(b.impact, a.impact)) ||
      a.key.localeCompare(b.key),
  )
  return ordered.length === 0
    ? { pinned: undefined, queue: [] }
    : { pinned: ordered[0], queue: ordered.slice(1) }
}

// ── sightings (observation log) ──────────────────────────────────────────

// One row per flag key ever detected: when it first appeared and when it was
// last seen. Pure observation — resolution stays implicit — but it makes
// "opened / resolved this cycle" answerable for the Fortnight.
export const FlagSighting = Schema.Struct({
  key: FlagKey,
  firstSeen: Schema.String.annotate({
    description: "Date (YYYY-MM-DD) the key was first detected.",
  }),
  lastSeen: Schema.String.annotate({
    description: "Date (YYYY-MM-DD) the key was most recently detected.",
  }),
  // Snapshot of the flag's last-known face, refreshed on every sighting — so
  // a receipt can still speak (title, dollars) after the flag stops being
  // detected. Optional: rows logged before snapshots existed stay decodable
  // and simply never become receipts.
  type: Schema.optional(FlagType),
  title: Schema.optional(Schema.String),
  impact: Schema.optional(Schema.BigDecimalFromString),
  impactLabel: Schema.optional(Schema.String),
  currency: Schema.optional(Schema.String),
  detail: Schema.optional(Schema.String),
})
export type FlagSighting = typeof FlagSighting.Type

// Opened = first sighted inside the cycle. Resolved = last sighted inside the
// cycle AND no longer in the detected set (so a Dismiss never masquerades as a
// data-verified resolution — the key keeps being sighted while suppressed).
// Returns undefined when the cycle predates logging: we can't tell "no flags"
// from "no log", and the Fortnight renders an honest em dash instead.
export const sightingStats = (
  sightings: ReadonlyArray<FlagSighting>,
  detectedKeys: ReadonlyArray<FlagKey>,
  cycleStart: string,
  cycleEnd: string,
): { readonly opened: number; readonly resolved: number } | undefined => {
  if (sightings.length === 0) return undefined
  const coverageStart = sightings.reduce(
    (min, s) => (s.firstSeen < min ? s.firstSeen : min),
    sightings[0].firstSeen,
  )
  if (cycleEnd <= coverageStart) return undefined
  const detected = new Set<string>(detectedKeys)
  let opened = 0
  let resolved = 0
  for (const s of sightings) {
    if (s.firstSeen >= cycleStart && s.firstSeen < cycleEnd) opened += 1
    if (s.lastSeen >= cycleStart && s.lastSeen < cycleEnd && !detected.has(s.key)) {
      resolved += 1
    }
  }
  return { opened, resolved }
}

// A resolution receipt — derived, never stored: a sighting whose key is no
// longer detected, speaking through its snapshot. "The data closes the loop"
// made visible: dated, dollar'd, with the original detail line as evidence.
export const FlagReceipt = Schema.Struct({
  key: FlagKey,
  type: FlagType,
  title: Schema.String,
  impact: Schema.BigDecimalFromString,
  impactLabel: Schema.String,
  currency: Schema.String,
  firstSeen: Schema.String.annotate({ description: "Date first detected (YYYY-MM-DD)." }),
  resolvedOn: Schema.String.annotate({
    description: "Last date the flag was detected — the day the data confirmed it gone.",
  }),
  detail: Schema.optional(Schema.String),
  expectedImpact: Schema.optional(
    Schema.BigDecimalFromString.annotate({
      description: "The $-impact committed to when the flag was acted on, if any.",
    }),
  ),
})
export type FlagReceipt = typeof FlagReceipt.Type

// Receipts for a cycle: not currently detected, last seen in [cycleStart,
// cycleEnd), snapshot present (pre-snapshot rows are an honest gap — skipped,
// same rule as "— before the log began"). Newest first.
export const deriveReceipts = (
  sightings: ReadonlyArray<FlagSighting>,
  detectedKeys: ReadonlyArray<FlagKey>,
  cycleStart: string,
  cycleEnd: string,
  expectedImpactByKey?: ReadonlyMap<string, BigDecimal.BigDecimal>,
): ReadonlyArray<FlagReceipt> => {
  const detected = new Set<string>(detectedKeys)
  const out: Array<FlagReceipt> = []
  for (const s of sightings) {
    if (detected.has(s.key)) continue
    if (s.lastSeen < cycleStart || s.lastSeen >= cycleEnd) continue
    if (
      s.type === undefined || s.title === undefined || s.impact === undefined ||
      s.impactLabel === undefined || s.currency === undefined
    ) continue
    out.push({
      key: s.key,
      type: s.type,
      title: s.title,
      impact: s.impact,
      impactLabel: s.impactLabel,
      currency: s.currency,
      firstSeen: s.firstSeen,
      resolvedOn: s.lastSeen,
      ...(s.detail === undefined ? {} : { detail: s.detail }),
      ...(expectedImpactByKey?.has(s.key)
        ? { expectedImpact: expectedImpactByKey.get(s.key)! }
        : {}),
    })
  }
  return out.sort(
    (a, b) =>
      b.resolvedOn.localeCompare(a.resolvedOn) ||
      toNum(BigDecimal.subtract(b.impact, a.impact)),
  )
}

const DAY_MS = 86_400_000

// ── the banked ledger ────────────────────────────────────────────────────

export const LedgerBasis = Schema.Literals(["elapsed", "self-resolved", "one-off"])

export const LedgerEntry = Schema.Struct({
  key: FlagKey,
  type: FlagType,
  title: Schema.String,
  currency: Schema.String,
  resolvedOn: Schema.String,
  ratePerYear: Schema.BigDecimalFromString.annotate({
    description: "Dollars per year this resolution keeps in your pocket. 0 for one-offs.",
  }),
  elapsedDays: Schema.Int,
  verified: Schema.BigDecimalFromString.annotate({
    description: "Elapsed verified savings: ratePerYear × elapsedDays / 365. Never the full projection.",
  }),
  counted: Schema.Boolean,
  basis: LedgerBasis,
  expectedImpact: Schema.optional(Schema.BigDecimalFromString),
})
export type LedgerEntry = typeof LedgerEntry.Type

export const Ledger = Schema.Struct({
  totalVerified: Schema.BigDecimalFromString,
  asOf: Schema.String,
  entries: Schema.Array(LedgerEntry),
})
export type Ledger = typeof Ledger.Type

// $/yr a resolved flag type keeps saving. One-offs rate 0 — listed, never
// accrued.
const ratePerYear = (type: FlagType, impact: BigDecimal.BigDecimal): BigDecimal.BigDecimal => {
  switch (type) {
    case "new_standing_order":
    case "standing_order_hike":
      return impact
    case "structural_deficit":
      return BigDecimal.multiply(impact, bd(12))
    default:
      return ZERO
  }
}

// The banked ledger: what acting on flags has VERIFIABLY saved, accrued by
// elapsed days. Only acted flags count; self-resolved are listed at $0;
// dismissed-then-gone keys are omitted (a dismissal is "this is fine", not a
// win). The guardrail: never count the projection, only the elapsed slice.
export const buildLedger = (
  sightings: ReadonlyArray<FlagSighting>,
  detectedKeys: ReadonlyArray<FlagKey>,
  states: ReadonlyArray<FlagState>,
  today: string,
): Ledger => {
  const detected = new Set<string>(detectedKeys)
  const stateByKey = new Map(states.map((s) => [s.key, s] as const))
  const entries: Array<LedgerEntry> = []
  for (const s of sightings) {
    if (detected.has(s.key)) continue
    if (
      s.type === undefined || s.title === undefined || s.impact === undefined ||
      s.impactLabel === undefined || s.currency === undefined
    ) continue
    const state = stateByKey.get(s.key)
    if (state?.status === "dismissed") continue
    const rate = ratePerYear(s.type, s.impact)
    const acted = state?.status === "acting"
    const counted = acted && BigDecimal.isGreaterThan(rate, ZERO)
    const elapsedDays = Math.max(
      0,
      Math.floor(
        (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${s.lastSeen}T00:00:00Z`)) / DAY_MS,
      ),
    )
    const verified = counted
      ? round2(
          BigDecimal.divideUnsafe(
            BigDecimal.multiply(rate, bd(elapsedDays)),
            bd(365),
          ),
        )
      : ZERO
    entries.push({
      key: s.key,
      type: s.type,
      title: s.title,
      currency: s.currency,
      resolvedOn: s.lastSeen,
      ratePerYear: round2(rate),
      elapsedDays,
      verified,
      counted,
      basis: counted ? "elapsed" : BigDecimal.isGreaterThan(rate, ZERO) ? "self-resolved" : "one-off",
      ...(state?.expectedImpact === undefined ? {} : { expectedImpact: state.expectedImpact }),
    })
  }
  entries.sort(
    (a, b) =>
      Number(b.counted) - Number(a.counted) ||
      toNum(BigDecimal.subtract(b.verified, a.verified)) ||
      b.resolvedOn.localeCompare(a.resolvedOn),
  )
  return {
    totalVerified: round2(
      entries.reduce((acc, e) => BigDecimal.sum(acc, e.verified), ZERO),
    ),
    asOf: today,
    entries,
  }
}

export const REGRESSION_GAP_DAYS = 7

// Honest regression: an Acting flag that genuinely cleared (unseen for >=
// gapDays) and is detected again contradicts its resolution — back to triage
// with a dated note, rather than staying falsely "acting". Evaluated against
// PRE-upsert sightings (the caller must not record this evaluation's
// sightings first, or the gap collapses to zero).
export const detectRegressions = (
  detectedKeys: ReadonlyArray<FlagKey>,
  states: ReadonlyArray<FlagState>,
  sightings: ReadonlyArray<FlagSighting>,
  today: string,
  gapDays: number = REGRESSION_GAP_DAYS,
): ReadonlyArray<{ readonly key: FlagKey; readonly note: string }> => {
  const stateByKey = new Map(states.map((s) => [s.key, s] as const))
  const seenByKey = new Map(sightings.map((s) => [s.key, s] as const))
  const out: Array<{ key: FlagKey; note: string }> = []
  for (const key of detectedKeys) {
    if (stateByKey.get(key)?.status !== "acting") continue
    const sighting = seenByKey.get(key)
    if (sighting === undefined) continue
    const gap = Math.round(
      (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${sighting.lastSeen}T00:00:00Z`)) / DAY_MS,
    )
    if (gap < gapDays) continue
    out.push({
      key,
      note: `Reappeared ${today} after ${gap} days quiet — back to triage.`,
    })
  }
  return out
}

export const CYCLE_DAYS = 14

// Whole pay-cycles a flag has been open. Stale flags get louder, not
// invisible — Linear's carried-issue pressure, on the fortnight.
export const carriedCycles = (
  firstSeen: string | undefined,
  today: string,
): number => {
  if (firstSeen === undefined) return 0
  const days = Math.floor(
    (Date.parse(`${today}T00:00:00Z`) - Date.parse(`${firstSeen}T00:00:00Z`)) / DAY_MS,
  )
  return Math.max(0, Math.floor(days / CYCLE_DAYS))
}
