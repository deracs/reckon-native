use crate::bank_models::{BankTransaction, Money, RecurringCharge, TransactionId, zero_money};
use bigdecimal::{BigDecimal, Signed, ToPrimitive, Zero};
use chrono::{Duration, NaiveDate};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap, HashSet};

/// Match opposite decimal amounts across accounts within three days, keeping currencies separate.
pub(crate) fn filter_bank_transfers(
    transactions: &[BankTransaction],
    exclude: bool,
) -> Vec<BankTransaction> {
    if !exclude {
        return transactions.to_vec();
    }
    let mut groups: HashMap<(String, String), Vec<&BankTransaction>> = HashMap::new();
    for tx in transactions {
        if !tx.amount.0.is_zero() {
            groups
                .entry((
                    tx.currency.clone(),
                    tx.amount.0.abs().normalized().to_string(),
                ))
                .or_default()
                .push(tx);
        }
    }
    let mut transfers: HashSet<TransactionId> = HashSet::new();
    for bucket in groups.values_mut() {
        bucket.sort_by_key(|tx| tx.date);
        for (i, a) in bucket.iter().enumerate() {
            if transfers.contains(&a.id) {
                continue;
            }
            for b in &bucket[i + 1..] {
                if transfers.contains(&b.id) {
                    continue;
                }
                if (b.date - a.date).num_days().abs() > 3 {
                    break;
                }
                if a.account_id == b.account_id
                    || a.amount.0.is_positive() == b.amount.0.is_positive()
                {
                    continue;
                }
                transfers.insert(a.id.clone());
                transfers.insert(b.id.clone());
                break;
            }
        }
    }
    transactions
        .iter()
        .filter(|tx| !transfers.contains(&tx.id))
        .cloned()
        .collect()
}

/// Sum category outflows without converting currencies; ties retain first-seen order.
pub(crate) fn summarize_bank_spending(transactions: &[BankTransaction]) -> Value {
    let mut categories: Vec<(String, BigDecimal, usize)> = Vec::new();
    let mut indexes = HashMap::new();
    for tx in transactions.iter().filter(|tx| tx.amount.0.is_negative()) {
        let category = tx.category.as_deref().unwrap_or("uncategorized");
        let index = *indexes.entry(category).or_insert_with(|| {
            categories.push((category.to_string(), zero_money(), 0));
            categories.len() - 1
        });
        categories[index].1 += tx.amount.0.abs();
        categories[index].2 += 1;
    }
    categories.sort_by(|a, b| b.1.cmp(&a.1));
    json!(categories.into_iter().map(|(category, spent, count)| json!({"category":category,"spent":Money(spent).rounded(),"transactionCount":count})).collect::<Vec<_>>())
}

/// Group signed income and outflows by UTC calendar month.
pub(crate) fn summarize_bank_cashflow(transactions: &[BankTransaction]) -> Value {
    let mut months: BTreeMap<String, (BigDecimal, BigDecimal, usize)> = BTreeMap::new();
    for tx in transactions {
        let row = months
            .entry(tx.date.format("%Y-%m").to_string())
            .or_insert((zero_money(), zero_money(), 0));
        if tx.amount.0.is_negative() {
            row.1 += tx.amount.0.abs();
        } else {
            row.0 += &tx.amount.0;
        }
        row.2 += 1;
    }
    json!(months.into_iter().map(|(month,(income,spending,count))| json!({"month":month,"net":Money(&income-&spending).rounded(),"income":Money(income).rounded(),"spending":Money(spending).rounded(),"transactionCount":count})).collect::<Vec<_>>())
}

fn normalize_bank_description(description: &str) -> String {
    description
        .chars()
        .filter(|c| !c.is_ascii_digit())
        .map(|c| {
            if c.is_ascii_alphabetic() || c.is_whitespace() {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Detect stable merchant amounts and cadence; retain the original 25% variation threshold.
pub(crate) fn detect_bank_recurring(
    transactions: &[BankTransaction],
    minimum: f64,
) -> Vec<RecurringCharge> {
    let mut groups: Vec<Vec<&BankTransaction>> = Vec::new();
    let mut indexes = HashMap::new();
    for tx in transactions.iter().filter(|tx| tx.amount.0.is_negative()) {
        let key = tx
            .merchant
            .clone()
            .unwrap_or_else(|| normalize_bank_description(&tx.description))
            .to_lowercase();
        if key.is_empty() {
            continue;
        }
        let index = *indexes.entry(key).or_insert_with(|| {
            groups.push(Vec::new());
            groups.len() - 1
        });
        groups[index].push(tx);
    }
    let mut results = Vec::new();
    for mut bucket in groups {
        if (bucket.len() as f64) < minimum.max(2.) {
            continue;
        }
        let amounts: Vec<_> = bucket.iter().map(|tx| tx.amount.0.abs()).collect();
        let total: BigDecimal = amounts.iter().sum();
        let average = &total / BigDecimal::from(amounts.len() as u64);
        let avg = average.to_f64().unwrap_or(f64::INFINITY);
        let variance = amounts
            .iter()
            .map(|amount| (amount.to_f64().unwrap_or(f64::INFINITY) - avg).powi(2))
            .sum::<f64>()
            / amounts.len() as f64;
        if average.is_zero() || variance.sqrt() / avg > 0.25 {
            continue;
        }
        bucket.sort_by_key(|tx| tx.date);
        let mut intervals: Vec<_> = bucket
            .windows(2)
            .map(|pair| (pair[1].date - pair[0].date).num_days() as f64)
            .collect();
        intervals.sort_by(f64::total_cmp);
        let mid = intervals.len() / 2;
        let interval = if intervals.len() % 2 == 1 {
            intervals[mid]
        } else {
            (intervals[mid - 1] + intervals[mid]) / 2.
        };
        let cadence = match interval {
            v if (5. ..=9.).contains(&v) => "weekly",
            v if (12. ..=17.).contains(&v) => "fortnightly",
            v if (26. ..=35.).contains(&v) => "monthly",
            v if (85. ..=100.).contains(&v) => "quarterly",
            _ => continue,
        };
        let first = bucket[0];
        let last = bucket[bucket.len() - 1];
        results.push(RecurringCharge {
            merchant: first
                .merchant
                .clone()
                .unwrap_or_else(|| first.description.clone()),
            category: first.category.clone(),
            cadence,
            occurrences: bucket.len(),
            average_amount: Money(average).rounded(),
            min_amount: Money(
                amounts
                    .iter()
                    .min()
                    .expect("Recurring amounts are nonempty")
                    .clone(),
            )
            .rounded(),
            max_amount: Money(
                amounts
                    .iter()
                    .max()
                    .expect("Recurring amounts are nonempty")
                    .clone(),
            )
            .rounded(),
            total_spent: Money(total).rounded(),
            first_date: first.date,
            last_date: last.date,
            last_amount: Money(last.amount.0.abs()).rounded(),
        });
    }
    results.sort_by(|a, b| b.total_spent.cmp(&a.total_spent));
    results
}

/// Forecast detected bills and income over a bounded horizon, excluding discretionary spending.
pub(crate) fn forecast_bank_cashflow(
    balance: BigDecimal,
    today: NaiveDate,
    days: f64,
    recurring: &[RecurringCharge],
    income: &[RecurringCharge],
) -> Value {
    // JS setUTCDate truncates fractional dates; the point loop includes floor(horizon).
    let horizon = days.clamp(1., 365.).floor() as i64;
    let end = today + Duration::days(horizon);
    let mut events: Vec<(NaiveDate, String, Money, &str)> = Vec::new();
    for (charges, kind) in [(recurring, "recurring_charge"), (income, "expected_income")] {
        for charge in charges {
            for date in charge.project_dates(today, end) {
                events.push((
                    date,
                    charge.merchant.clone(),
                    Money(if kind == "recurring_charge" {
                        -&charge.average_amount.0
                    } else {
                        charge.average_amount.0.clone()
                    }),
                    kind,
                ));
            }
        }
    }
    events.sort_by_key(|e| e.0);
    let starting = balance.clone();
    let mut balance = balance;
    let mut total_income = zero_money();
    let mut total_spending = zero_money();
    let mut points = Vec::new();
    let mut risks = Vec::new();
    let mut pointer = 0;
    for day in 0..=horizon {
        let date = today + Duration::days(day);
        while pointer < events.len() && events[pointer].0 <= date {
            let amount = &events[pointer].2.0;
            balance += amount;
            if amount.is_negative() {
                total_spending += amount.abs();
            } else {
                total_income += amount;
            }
            pointer += 1;
        }
        points.push(json!({"date":date,"projectedBalance":Money(balance.clone()).rounded()}));
        if balance.is_negative() {
            risks.push(json!({"date":date,"projectedBalance":Money(balance.clone()).rounded(),"reason":"Projected balance crosses zero"}));
        }
    }
    json!({"startDate":today,"endDate":end,"startingBalance":Money(starting.clone()).rounded(),"endingBalance":Money(balance.clone()).rounded(),"netChange":Money(balance-starting).rounded(),"totalIncome":Money(total_income).rounded(),"totalSpending":Money(total_spending).rounded(),"points":points,"events":events.into_iter().map(|(date,description,amount,kind)| json!({"date":date,"description":description,"amount":amount,"kind":kind})).collect::<Vec<_>>(),"risks":risks})
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bank_models::AccountId;
    use std::str::FromStr;

    fn transaction(
        id: &str,
        account: &str,
        date: &str,
        amount: &str,
        currency: &str,
    ) -> BankTransaction {
        BankTransaction {
            source: crate::bank_models::BankTransactionSource::Posted,
            id: TransactionId(id.to_string()),
            account_id: AccountId(account.to_string()),
            date: NaiveDate::parse_from_str(date, "%Y-%m-%d").unwrap(),
            description: "Fixture bill".to_string(),
            merchant: None,
            merchant_logo: None,
            category: None,
            amount: Money(BigDecimal::from_str(amount).unwrap()),
            currency: currency.to_string(),
        }
    }

    #[test]
    fn transfer_pairs_preserve_currency_account_and_three_day_boundary() {
        let rows = vec![
            transaction("out", "a", "2024-02-28", "-25.50", "NZD"),
            transaction("usd", "b", "2024-02-29", "25.5", "USD"),
            transaction("same", "a", "2024-02-29", "25.5", "NZD"),
            transaction("in", "b", "2024-03-02", "25.5", "NZD"),
            transaction("late", "c", "2024-03-03", "25.5", "NZD"),
        ];
        let remaining = filter_bank_transfers(&rows, true);
        assert_eq!(
            remaining
                .iter()
                .map(|tx| tx.id.0.as_str())
                .collect::<Vec<_>>(),
            vec!["usd", "same", "late"]
        );
    }

    #[test]
    fn decimal_sums_and_half_away_from_zero_rounding_remain_exact() {
        let rows = vec![
            transaction("a", "a", "2024-03-01", "-0.1", "NZD"),
            transaction("b", "a", "2024-03-02", "-0.2", "NZD"),
        ];
        assert_eq!(summarize_bank_spending(&rows)[0]["spent"], "0.3");
        assert_eq!(
            serde_json::to_value(Money(BigDecimal::from_str("-1.005").unwrap()).rounded()).unwrap(),
            "-1.01"
        );
    }

    #[test]
    fn recurring_and_forecast_keep_projection_behavior_after_detection() {
        let rows = ["2024-02-15", "2024-02-22", "2024-02-29"]
            .iter()
            .enumerate()
            .map(|(i, date)| transaction(&i.to_string(), "a", date, "-25.5", "NZD"))
            .collect::<Vec<_>>();
        let recurring = detect_bank_recurring(&rows, 3.);
        assert_eq!(recurring.len(), 1);
        let today = NaiveDate::from_ymd_opt(2024, 3, 1).unwrap();
        let forecast = forecast_bank_cashflow(BigDecimal::from(100), today, 14., &recurring, &[]);
        assert_eq!(forecast["events"][0]["date"], "2024-03-07");
        assert_eq!(forecast["events"][1]["date"], "2024-03-14");
        assert_eq!(forecast["endingBalance"], "49");
        assert_eq!(forecast["points"].as_array().unwrap().len(), 15);
    }

    #[test]
    fn projected_dates_cover_generated_inclusive_windows_and_fixed_cadences() {
        let last = NaiveDate::from_ymd_opt(2024, 1, 31).unwrap();
        for (cadence, interval) in [
            ("weekly", 7),
            ("fortnightly", 14),
            ("monthly", 30),
            ("quarterly", 91),
        ] {
            let charge = RecurringCharge {
                merchant: "Fixture".to_string(),
                category: None,
                cadence,
                occurrences: 3,
                average_amount: Money::default(),
                min_amount: Money::default(),
                max_amount: Money::default(),
                total_spent: Money::default(),
                first_date: last,
                last_date: last,
                last_amount: Money::default(),
            };
            for start in (0..730).step_by(11) {
                for width in [0, 1, 7, 30, 91, 365] {
                    let from = last + Duration::days(start);
                    let to = from + Duration::days(width);
                    let expected = (start..=start + width)
                        .filter(|day| *day > 0 && day % interval == 0)
                        .map(|day| last + Duration::days(day))
                        .collect::<Vec<_>>();
                    assert_eq!(charge.project_dates(from, to), expected);
                }
            }
        }
    }
}
