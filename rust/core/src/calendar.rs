//! Integer proleptic-Gregorian calendar math, shared by `budgets.rs` and
//! `recurring.rs`, neither of which pulls in a date/chrono dependency for it
//! (see `docs/BORROWED.md` and `docs/DECISIONS.md`).

pub const MILLIS_PER_DAY: i64 = 86_400_000;

/// Howard Hinnant's `civil_from_days`: the proleptic-Gregorian calendar date
/// for the day number `z` counted from the 1970-01-01 epoch. See
/// `docs/BORROWED.md`.
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d)
}

/// The inverse of [`civil_from_days`]: the day number counted from the
/// 1970-01-01 epoch for a proleptic-Gregorian calendar date.
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = i64::from(if m > 2 { m - 3 } else { m + 9 });
    let doy = (153 * mp + 2) / 5 + i64::from(d) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// Adds `months` (may be negative) to a calendar date, clamping the day to
/// the target month's length (e.g. Jan 31 + 1 month = Feb 28/29, not Mar 3).
pub fn add_months(y: i64, m: u32, d: u32, months: i64) -> (i64, u32, u32) {
    let zero_based_month = i64::from(m - 1) + months;
    let year = y + zero_based_month.div_euclid(12);
    let month = (zero_based_month.rem_euclid(12) + 1) as u32;
    let (next_year, next_month_num) = next_month(year, month);
    let days_in_month =
        days_from_civil(next_year, next_month_num, 1) - days_from_civil(year, month, 1);
    (year, month, d.min(days_in_month as u32))
}

fn next_month(year: i64, month: u32) -> (i64, u32) {
    if month == 12 { (year + 1, 1) } else { (year, month + 1) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_conversion_round_trips_across_a_leap_year_boundary() {
        for (year, month, day) in [
            (2024, 2, 29),
            (2024, 3, 1),
            (1970, 1, 1),
            (1969, 12, 31),
            (2000, 2, 29),
            (1900, 3, 1),
        ] {
            let days = days_from_civil(year, month, day);
            assert_eq!(civil_from_days(days), (year, month, day));
        }
    }

    #[test]
    fn add_months_clamps_to_the_shorter_target_month() {
        assert_eq!(add_months(2026, 1, 31, 1), (2026, 2, 28));
        assert_eq!(add_months(2024, 1, 31, 1), (2024, 2, 29));
        assert_eq!(add_months(2026, 12, 15, 1), (2027, 1, 15));
    }

    #[test]
    fn add_months_handles_a_full_year_rollover() {
        assert_eq!(add_months(2026, 6, 10, 12), (2027, 6, 10));
    }
}
