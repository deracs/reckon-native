import { bankApi } from "@reckon/api";
import { BankData } from "@reckon/domain";
import { Effect } from "effect";
import { HttpApiBuilder } from "effect/unstable/httpapi";

export const BankHandlers = HttpApiBuilder.group(bankApi, "bank", (handlers) =>
  Effect.gen(function* () {
    const bank = yield* BankData;
    return handlers
      .handle("listAccounts", () => bank.listAccounts())
      .handle("searchTransactions", ({ query }) =>
        bank.searchTransactions(query),
      )
      .handle("summarizeSpending", ({ query }) => bank.summarizeSpending(query))
      .handle("summarizeCashflow", ({ query }) => bank.summarizeCashflow(query))
      .handle("listRecurringCharges", ({ query }) =>
        bank.listRecurringCharges(query),
      )
      .handle("findUnusualTransactions", ({ query }) =>
        bank.findUnusualTransactions(query),
      )
      .handle("topMerchants", ({ query }) => bank.topMerchants(query))
      .handle("summarizeRoundUps", ({ query }) => bank.summarizeRoundUps(query))
      .handle("listCategories", () => bank.listCategories())
      .handle("getDataFreshness", () => bank.getDataFreshness())
      .handle("refresh", () => bank.refresh().pipe(Effect.as({ ok: true })))
      .handle("budgetStatus", ({ query }) => bank.budgetStatus(query))
      .handle("forecastCashflow", ({ query }) => bank.forecastCashflow(query))
      .handle("listGoals", () => bank.listGoals())
      .handle("goalStatus", () => bank.goalStatus())
      .handle("foundMoney", () => bank.foundMoney())
      .handle("upsertGoal", ({ payload }) => bank.upsertGoal(payload))
      .handle("deleteGoal", ({ params }) => bank.deleteGoal({ id: params.id }));
  }),
);
