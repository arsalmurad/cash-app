//! Recurring transaction rules are soft state, exactly like categories,
//! budgets, and goals: a rule's title, amount, account, category, and
//! frequency settle by last-writer-wins. Which occurrences are "upcoming" is
//! never stored here — it is computed fresh from a rule's frequency and the
//! ledger's own transactions (see `rust/api/src/api/recurring.rs`), by
//! finding the latest transaction tagged with the rule's ID
//! (`EventKind::TransactionRecorded::recurring_id`) rather than maintaining
//! a separate "last generated" pointer that could drift from what was
//! actually recorded.

use std::collections::BTreeMap;

use crate::bytes_io::{Reader, write_bool, write_i64, write_string, write_u32};
use crate::calendar::{MILLIS_PER_DAY, add_months, civil_from_days, days_from_civil};
use crate::frame::{DecodedFrameLog, decode_frame_log, encode_frame};
use crate::{ActorId, EventId, HybridTimestamp};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct RecurringId(String);

impl RecurringId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecurringKind {
    Expense,
    Income,
}

/// How often a rule recurs. Unlike `budgets::BudgetPeriod`, there is no
/// `Custom { days }` variant here: a recurring bill's cadence is normally
/// one of these four, and the ambiguity a rolling window would introduce
/// (rolling from what anchor, once an occurrence is skipped?) isn't worth
/// it for this feature.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RecurringFrequency {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

/// One "set this rule's title, amount, account, category, frequency, and
/// start" write. Every write is an upsert; the highest `(timestamp,
/// actor_id)` writer for a given `recurring_id` wins, identically to
/// `budgets::BudgetUpsert`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecurringUpsert {
    pub id: EventId,
    pub actor_id: ActorId,
    pub timestamp: HybridTimestamp,
    pub recurring_id: RecurringId,
    pub title: String,
    pub kind: RecurringKind,
    pub amount_minor: i64,
    pub account_id: String,
    pub category_id: Option<String>,
    pub frequency: RecurringFrequency,
    /// The millisecond of the rule's first occurrence. Later occurrences are
    /// found by stepping forward from here by `frequency`, so a rule created
    /// today with a start date last month immediately has one or more
    /// overdue occurrences rather than waiting a full cycle.
    pub start_millis: i64,
}

impl RecurringUpsert {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        actor_id: impl Into<String>,
        physical_millis: i64,
        logical: u32,
        recurring_id: RecurringId,
        title: impl Into<String>,
        kind: RecurringKind,
        amount_minor: i64,
        account_id: impl Into<String>,
        category_id: Option<String>,
        frequency: RecurringFrequency,
        start_millis: i64,
    ) -> Self {
        Self {
            id: EventId::new(id),
            actor_id: ActorId::new(actor_id),
            timestamp: HybridTimestamp::new(physical_millis, logical),
            recurring_id,
            title: title.into(),
            kind,
            amount_minor,
            account_id: account_id.into(),
            category_id,
            frequency,
            start_millis,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecurringRecord {
    pub title: String,
    pub kind: RecurringKind,
    pub amount_minor: i64,
    pub account_id: String,
    pub category_id: Option<String>,
    pub frequency: RecurringFrequency,
    pub start_millis: i64,
    last_writer: (HybridTimestamp, ActorId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RecurringBookState {
    pub rules: BTreeMap<RecurringId, RecurringRecord>,
}

impl RecurringBookState {
    pub fn empty() -> Self {
        Self::default()
    }

    fn apply(&mut self, upsert: &RecurringUpsert) {
        let writer_key = (upsert.timestamp, upsert.actor_id.clone());
        let should_replace = match self.rules.get(&upsert.recurring_id) {
            Some(existing) => writer_key > existing.last_writer,
            None => true,
        };
        if should_replace {
            self.rules.insert(
                upsert.recurring_id.clone(),
                RecurringRecord {
                    title: upsert.title.clone(),
                    kind: upsert.kind,
                    amount_minor: upsert.amount_minor,
                    account_id: upsert.account_id.clone(),
                    category_id: upsert.category_id.clone(),
                    frequency: upsert.frequency,
                    start_millis: upsert.start_millis,
                    last_writer: writer_key,
                },
            );
        }
    }
}

/// Folds recurring upserts into last-writer-wins state. Order of iteration
/// does not affect the result (identical reasoning to
/// `budgets::fold_budgets`).
pub fn fold_recurring(upserts: impl IntoIterator<Item = RecurringUpsert>) -> RecurringBookState {
    let mut state = RecurringBookState::empty();
    for upsert in upserts {
        state.apply(&upsert);
    }
    state
}

/// The first occurrence strictly after `after_millis` (or exactly
/// `start_millis`, if `after_millis` is `None` and thus nothing has been
/// recorded yet). Monthly/yearly steps clamp the day to the target month's
/// length (see `calendar::add_months`), so a rule that starts on the 31st
/// keeps recurring near month's end instead of silently landing on the 1st.
pub fn next_occurrence_millis(
    frequency: RecurringFrequency,
    start_millis: i64,
    after_millis: Option<i64>,
) -> i64 {
    let Some(after) = after_millis else {
        return start_millis;
    };
    if after < start_millis {
        return start_millis;
    }
    match frequency {
        RecurringFrequency::Daily => {
            let step_days = 1;
            let start_day = start_millis.div_euclid(MILLIS_PER_DAY);
            let after_day = after.div_euclid(MILLIS_PER_DAY);
            let elapsed_steps = (after_day - start_day) / step_days + 1;
            (start_day + elapsed_steps * step_days) * MILLIS_PER_DAY
        }
        RecurringFrequency::Weekly => {
            let step_days = 7;
            let start_day = start_millis.div_euclid(MILLIS_PER_DAY);
            let after_day = after.div_euclid(MILLIS_PER_DAY);
            let elapsed_steps = (after_day - start_day) / step_days + 1;
            (start_day + elapsed_steps * step_days) * MILLIS_PER_DAY
        }
        RecurringFrequency::Monthly => {
            let start_day = start_millis.div_euclid(MILLIS_PER_DAY);
            let (year, month, day) = civil_from_days(start_day);
            let mut months = 1;
            loop {
                let (y, m, d) = add_months(year, month, day, months);
                let candidate = days_from_civil(y, m, d) * MILLIS_PER_DAY;
                if candidate > after {
                    return candidate;
                }
                months += 1;
            }
        }
        RecurringFrequency::Yearly => {
            let start_day = start_millis.div_euclid(MILLIS_PER_DAY);
            let (year, month, day) = civil_from_days(start_day);
            let mut years = 1;
            loop {
                let (y, m, d) = add_months(year, month, day, years * 12);
                let candidate = days_from_civil(y, m, d) * MILLIS_PER_DAY;
                if candidate > after {
                    return candidate;
                }
                years += 1;
            }
        }
    }
}

/// The result of decoding a durable recurring-rule log's bytes.
pub struct DecodedRecurringLog {
    pub upserts: Vec<RecurringUpsert>,
    pub trailing_garbage_bytes: usize,
}

impl From<DecodedFrameLog<RecurringUpsert>> for DecodedRecurringLog {
    fn from(decoded: DecodedFrameLog<RecurringUpsert>) -> Self {
        Self {
            upserts: decoded.items,
            trailing_garbage_bytes: decoded.trailing_garbage_bytes,
        }
    }
}

pub fn encode_recurring_frame(upsert: &RecurringUpsert) -> Vec<u8> {
    encode_frame(&encode_upsert(upsert))
}

pub fn decode_recurring_log(bytes: &[u8]) -> DecodedRecurringLog {
    decode_frame_log(bytes, decode_upsert).into()
}

const KIND_EXPENSE: u8 = 0;
const KIND_INCOME: u8 = 1;

const FREQUENCY_DAILY: u8 = 0;
const FREQUENCY_WEEKLY: u8 = 1;
const FREQUENCY_MONTHLY: u8 = 2;
const FREQUENCY_YEARLY: u8 = 3;

fn encode_upsert(upsert: &RecurringUpsert) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_string(&mut bytes, upsert.id.as_str());
    write_string(&mut bytes, upsert.actor_id.as_str());
    write_i64(&mut bytes, upsert.timestamp.physical_millis);
    write_u32(&mut bytes, upsert.timestamp.logical);
    write_string(&mut bytes, upsert.recurring_id.as_str());
    write_string(&mut bytes, &upsert.title);
    bytes.push(match upsert.kind {
        RecurringKind::Expense => KIND_EXPENSE,
        RecurringKind::Income => KIND_INCOME,
    });
    write_i64(&mut bytes, upsert.amount_minor);
    write_string(&mut bytes, &upsert.account_id);
    match &upsert.category_id {
        Some(category_id) => {
            write_bool(&mut bytes, true);
            write_string(&mut bytes, category_id);
        }
        None => write_bool(&mut bytes, false),
    }
    bytes.push(match upsert.frequency {
        RecurringFrequency::Daily => FREQUENCY_DAILY,
        RecurringFrequency::Weekly => FREQUENCY_WEEKLY,
        RecurringFrequency::Monthly => FREQUENCY_MONTHLY,
        RecurringFrequency::Yearly => FREQUENCY_YEARLY,
    });
    write_i64(&mut bytes, upsert.start_millis);
    bytes
}

fn decode_upsert(payload: &[u8]) -> Option<RecurringUpsert> {
    let mut reader = Reader::new(payload);
    let id = reader.read_string()?;
    let actor_id = reader.read_string()?;
    let physical_millis = reader.read_i64()?;
    let logical = reader.read_u32()?;
    let recurring_id = RecurringId::new(reader.read_string()?);
    let title = reader.read_string()?;
    let kind = match reader.read_u8()? {
        KIND_EXPENSE => RecurringKind::Expense,
        KIND_INCOME => RecurringKind::Income,
        _ => return None,
    };
    let amount_minor = reader.read_i64()?;
    let account_id = reader.read_string()?;
    let category_id = if reader.read_bool()? {
        Some(reader.read_string()?)
    } else {
        None
    };
    let frequency = match reader.read_u8()? {
        FREQUENCY_DAILY => RecurringFrequency::Daily,
        FREQUENCY_WEEKLY => RecurringFrequency::Weekly,
        FREQUENCY_MONTHLY => RecurringFrequency::Monthly,
        FREQUENCY_YEARLY => RecurringFrequency::Yearly,
        _ => return None,
    };
    let start_millis = reader.read_i64()?;
    if reader.remaining() != 0 {
        return None;
    }
    Some(RecurringUpsert::new(
        id,
        actor_id,
        physical_millis,
        logical,
        recurring_id,
        title,
        kind,
        amount_minor,
        account_id,
        category_id,
        frequency,
        start_millis,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[allow(clippy::too_many_arguments)]
    fn upsert(
        id: &str,
        actor: &str,
        millis: i64,
        logical: u32,
        rule: &str,
        title: &str,
        kind: RecurringKind,
        amount_minor: i64,
        account_id: &str,
        category_id: Option<&str>,
        frequency: RecurringFrequency,
        start_millis: i64,
    ) -> RecurringUpsert {
        RecurringUpsert::new(
            id,
            actor,
            millis,
            logical,
            RecurringId::new(rule),
            title,
            kind,
            amount_minor,
            account_id,
            category_id.map(str::to_owned),
            frequency,
            start_millis,
        )
    }

    fn millis_for(year: i64, month: u32, day: u32) -> i64 {
        days_from_civil(year, month, day) * MILLIS_PER_DAY
    }

    #[test]
    fn a_later_write_wins_regardless_of_arrival_order() {
        let early = upsert(
            "e1",
            "alice",
            100,
            0,
            "rent",
            "Rent",
            RecurringKind::Expense,
            100_000,
            "checking",
            None,
            RecurringFrequency::Monthly,
            millis_for(2026, 1, 1),
        );
        let late = upsert(
            "e2",
            "alice",
            200,
            0,
            "rent",
            "Rent (raised)",
            RecurringKind::Expense,
            120_000,
            "checking",
            None,
            RecurringFrequency::Monthly,
            millis_for(2026, 1, 1),
        );

        let forward = fold_recurring([early.clone(), late.clone()]);
        let backward = fold_recurring([late, early]);
        assert_eq!(forward, backward);

        let record = &forward.rules[&RecurringId::new("rent")];
        assert_eq!(record.title, "Rent (raised)");
        assert_eq!(record.amount_minor, 120_000);
    }

    #[test]
    fn a_rule_round_trips_through_a_frame() {
        for frequency in [
            RecurringFrequency::Daily,
            RecurringFrequency::Weekly,
            RecurringFrequency::Monthly,
            RecurringFrequency::Yearly,
        ] {
            let write = upsert(
                "e1",
                "alice",
                100,
                3,
                "rent",
                "Rent",
                RecurringKind::Expense,
                150_000,
                "checking",
                Some("housing"),
                frequency,
                millis_for(2026, 1, 31),
            );
            let frame = encode_recurring_frame(&write);
            let decoded = decode_recurring_log(&frame);
            assert_eq!(decoded.trailing_garbage_bytes, 0);
            assert_eq!(decoded.upserts, vec![write]);
        }
    }

    #[test]
    fn a_rule_with_no_category_round_trips() {
        let write = upsert(
            "e1",
            "alice",
            100,
            0,
            "salary",
            "Salary",
            RecurringKind::Income,
            500_000,
            "checking",
            None,
            RecurringFrequency::Monthly,
            millis_for(2026, 1, 1),
        );
        let frame = encode_recurring_frame(&write);
        let decoded = decode_recurring_log(&frame);
        assert_eq!(decoded.upserts, vec![write]);
    }

    #[test]
    fn the_first_occurrence_is_the_start_date_itself() {
        let start = millis_for(2026, 1, 15);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Monthly, start, None),
            start
        );
    }

    #[test]
    fn daily_steps_advance_by_exactly_one_day() {
        let start = millis_for(2026, 1, 15);
        let after = millis_for(2026, 1, 15);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Daily, start, Some(after)),
            millis_for(2026, 1, 16)
        );
    }

    #[test]
    fn weekly_steps_advance_by_seven_days() {
        let start = millis_for(2026, 1, 1);
        let after = millis_for(2026, 1, 1);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Weekly, start, Some(after)),
            millis_for(2026, 1, 8)
        );
    }

    #[test]
    fn monthly_steps_clamp_at_the_end_of_a_shorter_month() {
        let start = millis_for(2026, 1, 31);
        let after = millis_for(2026, 1, 31);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Monthly, start, Some(after)),
            millis_for(2026, 2, 28)
        );
    }

    #[test]
    fn yearly_steps_advance_by_one_year() {
        let start = millis_for(2026, 3, 18);
        let after = millis_for(2026, 3, 18);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Yearly, start, Some(after)),
            millis_for(2027, 3, 18)
        );
    }

    #[test]
    fn a_start_date_in_the_past_produces_the_next_occurrence_after_the_last_one_recorded() {
        // A rule created today with occurrences already due (e.g. imported
        // from another app) should resume exactly one step after whatever
        // was last recorded, not restart from `start_millis`.
        let start = millis_for(2025, 11, 1);
        let last_recorded = millis_for(2026, 1, 1);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Monthly, start, Some(last_recorded)),
            millis_for(2026, 2, 1)
        );
    }

    #[test]
    fn after_before_the_start_date_still_returns_the_start_date() {
        let start = millis_for(2026, 6, 1);
        let after = millis_for(2026, 1, 1);
        assert_eq!(
            next_occurrence_millis(RecurringFrequency::Monthly, start, Some(after)),
            start
        );
    }
}
