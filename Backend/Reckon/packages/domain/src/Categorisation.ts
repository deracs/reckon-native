import { BigDecimal, Context, Effect, Schema } from "effect"
import { BankCategory, CategoryRule, Transaction, TransactionId, TransactionOverride } from "./BankData.js"

export const normaliseCategoryName = (name: string): string => name.trim().replace(/\s+/g, " ")
export const categoryNameKey = (name: string): string => normaliseCategoryName(name).toLowerCase()
export const isUncategorised = (category: string | undefined | null): boolean =>
  !category || ["", "uncategorised", "uncategorized"].includes(categoryNameKey(category))

export const CategorisationPreviewId = Schema.String.pipe(Schema.brand("CategorisationPreviewId"))
export type CategorisationPreviewId = typeof CategorisationPreviewId.Type
export const CategorisationGroupId = Schema.String.pipe(Schema.brand("CategorisationGroupId"))
export type CategorisationGroupId = typeof CategorisationGroupId.Type

export class CategorisationError extends Schema.TaggedError<CategorisationError>()("CategorisationError", {
  code: Schema.Literals(["unavailable", "not_found", "conflict", "invalid", "provider", "storage"]),
  message: Schema.String,
}) {}

export const CategorisationScope = Schema.Struct({
  from: Schema.optional(Schema.NullOr(Schema.String)),
  to: Schema.optional(Schema.String),
  accountId: Schema.optional(Schema.String),
  query: Schema.optional(Schema.String),
})
export type CategorisationScope = typeof CategorisationScope.Type

/** One ranked existing category returned as evidence for a Jev category decision. */
export const CategoryAlternative = Schema.Struct({
  categoryId: Schema.String,
  categoryName: Schema.String,
  probability: Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 })),
})
export type CategoryAlternative = typeof CategoryAlternative.Type

/** A reviewed category suggestion, with optional Jev confidence evidence. */
export const CategorySuggestion = Schema.Struct({
  groupId: CategorisationGroupId,
  outcome: Schema.Literals(["existing", "new", "unresolved"]),
  categoryId: Schema.NullOr(Schema.String),
  categoryName: Schema.NullOr(Schema.String),
  reason: Schema.String,
  confidence: Schema.optionalKey(Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 }))),
  alternatives: Schema.optionalKey(Schema.Array(CategoryAlternative)),
})
export type CategorySuggestion = typeof CategorySuggestion.Type

/** Jev's independent category review for one transaction; no category is changed by this result. */
export const TransactionCategoryReview = Schema.Struct({
  transactionId: TransactionId,
  currentCategory: Schema.NullOr(Schema.String),
  outcome: CategorySuggestion.fields.outcome,
  suggestedCategory: Schema.NullOr(Schema.String),
  confidence: Schema.NullOr(Schema.Finite.check(Schema.isBetween({ minimum: 0, maximum: 1 }))),
  alternatives: Schema.Array(CategoryAlternative),
  reason: Schema.String,
  model: Schema.String,
})
export type TransactionCategoryReview = typeof TransactionCategoryReview.Type

export const CategorisationMember = Schema.Struct({
  transactionId: TransactionId,
  fingerprint: Schema.String,
})
export const CategorisationExample = Schema.Struct({
  date: Schema.String,
  description: Schema.String,
  amount: Schema.String,
})
export const CategorisationGroup = Schema.Struct({
  id: CategorisationGroupId,
  matchKind: Schema.Literals(["merchant", "description"]),
  pattern: Schema.String,
  matchPatterns: Schema.optional(Schema.Array(Schema.String)),
  direction: Schema.Literals(["debit", "credit"]),
  currency: Schema.String,
  totalAmount: Schema.String,
  members: Schema.Array(CategorisationMember),
  examples: Schema.Array(CategorisationExample),
  status: Schema.Literals(["pending", "suggested", "unresolved", "applied", "skipped"]),
  suggestion: Schema.NullOr(CategorySuggestion),
  categoryName: Schema.NullOr(Schema.String),
  remembered: Schema.Boolean,
  appliedCount: Schema.Int,
  skippedCount: Schema.Int,
})
export type CategorisationGroup = typeof CategorisationGroup.Type

export const CategorisationPreview = Schema.Struct({
  id: CategorisationPreviewId,
  createdAt: Schema.String,
  scope: CategorisationScope,
  model: Schema.String,
  promptVersion: Schema.String,
  groups: Schema.Array(CategorisationGroup),
})
export type CategorisationPreview = typeof CategorisationPreview.Type

export const CategorisationJob = Schema.Struct({
  state: Schema.Literals(["idle", "queued", "running", "pausing", "paused", "complete", "failed"]),
  error: Schema.NullOr(Schema.String),
})
export type CategorisationJob = typeof CategorisationJob.Type
export const CategorisationJobSnapshot = Schema.Struct({ preview: CategorisationPreview, job: CategorisationJob })
export type CategorisationJobSnapshot = typeof CategorisationJobSnapshot.Type
export class CategorisationJobs extends Context.Service<CategorisationJobs, {
  readonly startCategorisationJob: (input: { id: CategorisationPreviewId }) => Effect.Effect<CategorisationJobSnapshot, CategorisationError>
  readonly getCategorisationJob: (input: { id: CategorisationPreviewId }) => Effect.Effect<CategorisationJobSnapshot, CategorisationError>
  readonly pauseCategorisationJob: (input: { id: CategorisationPreviewId }) => Effect.Effect<CategorisationJobSnapshot, CategorisationError>
}>()("reckon/CategorisationJobs") {}

export const CategorisationSelection = Schema.Struct({
  groupId: CategorisationGroupId,
  action: Schema.Literals(["apply", "skip"]),
  categoryName: Schema.NullOr(Schema.String),
  remember: Schema.Boolean,
})
export type CategorisationSelection = typeof CategorisationSelection.Type

export const CategorisationCapability = Schema.Struct({ available: Schema.Boolean, reason: Schema.NullOr(Schema.String) })
export const CategoryRuleReach = Schema.Struct({
  count: Schema.Int,
  outsideScopeCount: Schema.Int,
  totalAmount: Schema.String,
  currency: Schema.String,
})
export type CategoryRuleReach = typeof CategoryRuleReach.Type

export interface CategorisationSnapshot {
  readonly revision: number
  readonly transactions: ReadonlyArray<Transaction>
  readonly rules: ReadonlyArray<CategoryRule>
  readonly overrides: ReadonlyArray<TransactionOverride>
  readonly customCategories: ReadonlyArray<typeof BankCategory.Type>
}

export interface CategorisationCommit {
  readonly previewId: CategorisationPreviewId
  readonly revision: number
  readonly group: CategorisationGroup
  readonly transactionIds: ReadonlyArray<TransactionId>
  readonly customCategory: { readonly id: string; readonly name: string; readonly normalisedName: string } | null
  readonly rule: CategoryRule | null
}

export class CategorisationStore extends Context.Service<CategorisationStore, {
  readonly snapshot: () => Effect.Effect<CategorisationSnapshot, CategorisationError>
  readonly create: (preview: CategorisationPreview) => Effect.Effect<void, CategorisationError>
  readonly get: (id: CategorisationPreviewId) => Effect.Effect<CategorisationPreview, CategorisationError>
  /** Returns the most recently started categorisation preview, when one exists. */
  readonly getLatest: () => Effect.Effect<CategorisationPreview | null, CategorisationError>
  readonly claimBatch: (id: CategorisationPreviewId, token: string, now: number) => Effect.Effect<boolean, CategorisationError>
  readonly saveBatch: (id: CategorisationPreviewId, token: string, groups: ReadonlyArray<CategorisationGroup>) => Effect.Effect<void, CategorisationError>
  readonly releaseBatch: (id: CategorisationPreviewId, token: string) => Effect.Effect<void, CategorisationError>
  readonly commit: (input: CategorisationCommit) => Effect.Effect<void, CategorisationError>
}>()("reckon/CategorisationStore") {}

export class CategoryClassifier extends Context.Service<CategoryClassifier, {
  readonly model: string
  readonly available: boolean
  readonly classify: (groups: ReadonlyArray<CategorisationGroup>, categories: ReadonlyArray<typeof BankCategory.Type>) => Effect.Effect<{
    readonly suggestions: ReadonlyArray<CategorySuggestion>
    readonly inputTokens: number
    readonly outputTokens: number
  }, CategorisationError>
}>()("reckon/CategoryClassifier") {}

export class Categorisation extends Context.Service<Categorisation, {
  readonly categorisationCapability: () => Effect.Effect<typeof CategorisationCapability.Type>
  /** Reviews one transaction against existing categories without changing it. */
  readonly reviewTransactionCategory: (input: { readonly transactionId: TransactionId }) => Effect.Effect<TransactionCategoryReview, CategorisationError>
  readonly startCategorisation: (scope: CategorisationScope) => Effect.Effect<CategorisationPreview, CategorisationError>
  readonly getCategorisation: (input: { readonly id: CategorisationPreviewId }) => Effect.Effect<CategorisationPreview, CategorisationError>
  /** Returns the latest persisted categorisation run for status and resumption. */
  readonly getLatestCategorisation: () => Effect.Effect<CategorisationPreview | null, CategorisationError>
  readonly generateCategorisationBatch: (input: { readonly id: CategorisationPreviewId }) => Effect.Effect<CategorisationPreview, CategorisationError>
  readonly previewCategorisationRule: (input: { readonly id: CategorisationPreviewId; readonly groupId: CategorisationGroupId }) => Effect.Effect<CategoryRuleReach, CategorisationError>
  readonly applyCategorisation: (input: { readonly id: CategorisationPreviewId; readonly selections: ReadonlyArray<CategorisationSelection> }) => Effect.Effect<CategorisationPreview, CategorisationError>
}>()("reckon/Categorisation") {}

export const transactionFingerprint = (tx: Transaction): string => JSON.stringify([
  tx.id, tx.accountId, tx.date, tx.description, tx.merchant ?? null,
  tx.category ?? null, BigDecimal.format(tx.amount), tx.currency,
])

export const matchesCategorisationScope = (tx: Transaction, scope: CategorisationScope): boolean =>
  (!scope.from || tx.date >= scope.from) && (!scope.to || tx.date <= scope.to) &&
  (!scope.accountId || tx.accountId === scope.accountId) &&
  (!scope.query || [tx.description, tx.merchant, tx.category].some((v) =>
    v?.toLowerCase().includes(scope.query!.toLowerCase())))

// Ignore presentation and labelled terminal/reference suffixes, not different
// merchant words. The original variants remain the exact rule matches.
export const categorisationMatchKey = (text: string, kind: "merchant" | "description"): string => {
  let value = categoryNameKey(text).replace(/\s+(?:store|branch|terminal)\s*#?\s*\d+$/i, "")
  if (kind === "description") value = value
    .replace(/\s+(?:ref(?:erence)?|receipt|auth|txn)\s*[:#-]?\s*[a-z0-9-]*\d[a-z0-9-]*$/i, "")
  const key = value.replace(/&/g, "and").replace(/[\p{P}\p{S}\s]/gu, "")
  return key || categoryNameKey(text)
}

/** Groups transaction category candidates while retaining exact variants for remembered matches. */
export const groupCategorisationCandidates = (
  transactions: ReadonlyArray<Transaction>,
  newId: () => CategorisationGroupId,
  options: { readonly includeCategorised?: boolean } = {},
): ReadonlyArray<CategorisationGroup> => {
  const grouped = new Map<string, Array<Transaction>>()
  for (const tx of transactions) {
    if ((!options.includeCategorised && !isUncategorised(tx.category)) || BigDecimal.isZero(tx.amount)) continue
    const kind = tx.merchant?.trim() ? "merchant" : "description"
    const pattern = normaliseCategoryName(kind === "merchant" ? tx.merchant ?? "" : tx.description)
    const key = JSON.stringify([kind, categorisationMatchKey(pattern, kind), BigDecimal.sign(tx.amount), tx.currency])
    const group = grouped.get(key) ?? []
    group.push(tx)
    grouped.set(key, group)
  }
  return [...grouped.values()].map((rows) => {
    const first = rows[0]
    const matchKind = first.merchant?.trim() ? "merchant" : "description"
    const variants = new Map<string, Transaction>()
    for (const tx of rows) {
      const value = normaliseCategoryName(matchKind === "merchant" ? tx.merchant ?? "" : tx.description)
      if (!variants.has(value)) variants.set(value, tx)
    }
    const examples = new Map<string, Transaction>()
    for (const tx of [...variants.values(), ...rows]) {
      const key = JSON.stringify([tx.description, BigDecimal.format(tx.amount)])
      if (!examples.has(key)) examples.set(key, tx)
      if (examples.size === 3) break
    }
    return {
      id: newId(), matchKind,
      pattern: normaliseCategoryName(matchKind === "merchant" ? first.merchant ?? "" : first.description),
      matchPatterns: [...variants.keys()],
      direction: BigDecimal.sign(first.amount) < 0 ? "debit" : "credit",
      currency: first.currency,
      totalAmount: BigDecimal.format(rows.reduce((sum, tx) => BigDecimal.sum(sum, BigDecimal.abs(tx.amount)), BigDecimal.fromNumberUnsafe(0))),
      members: rows.map((tx) => ({ transactionId: tx.id, fingerprint: transactionFingerprint(tx) })),
      examples: [...examples.values()].map((tx) => ({ date: tx.date, description: tx.description, amount: BigDecimal.format(tx.amount) })),
      status: "pending", suggestion: null, categoryName: null, remembered: false, appliedCount: 0, skippedCount: 0,
    }
  })
}
