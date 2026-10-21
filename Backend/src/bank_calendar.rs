use chrono::{Datelike, Duration, NaiveDate, Utc};

/// Report dates use Pacific/Auckland, independent of the process timezone.
pub(crate) fn bank_today() -> NaiveDate {
    Utc::now()
        .with_timezone(&chrono_tz::Pacific::Auckland)
        .date_naive()
}

/// Calendar month shifts retain JavaScript's UTC month-end rollover behavior.
pub(crate) fn add_bank_months(date: NaiveDate, months: i32) -> NaiveDate {
    let month = date.year() * 12 + date.month0() as i32 + months;
    NaiveDate::from_ymd_opt(month.div_euclid(12), month.rem_euclid(12) as u32 + 1, 1)
        .expect("Bank calendar month is in range")
        + Duration::days(date.day0() as i64)
}

/// Query dates must be real ISO calendar dates, without a time or rollover.
pub(crate) fn parse_bank_date(raw: &str) -> Option<NaiveDate> {
    if raw.len() != 10 || raw.starts_with("0000") {
        return None;
    }
    let date = NaiveDate::parse_from_str(raw, "%Y-%m-%d").ok()?;
    (date.to_string() == raw).then_some(date)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn month_end_rollover_and_calendar_parsing_match_the_existing_backend() {
        assert_eq!(
            add_bank_months(parse_bank_date("2024-08-31").unwrap(), -6).to_string(),
            "2024-03-02"
        );
        for invalid in [
            "0000-01-01",
            "2026-02-30",
            "2026-2-03",
            "2026-10-20T00:00:00Z",
        ] {
            assert!(parse_bank_date(invalid).is_none());
        }
        assert!(parse_bank_date("2024-02-29").is_some());
    }
}
