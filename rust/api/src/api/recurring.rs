use std::sync::{Mutex, MutexGuard};

use cash_core::{
    HybridTimestamp, RecurringFrequency as CoreRecurringFrequency, RecurringId,
    RecurringKind as CoreRecurringKind, RecurringUpsert, decode_recurring_log,
    encode_recurring_frame, fold_recurring, next_occurrence_millis,
};
use flutter_rust_bridge::frb;

use super::ledger::{PersonalLedger, folded_state};

/// Recurring rules are soft state, folded by last-writer-wins (see
/// `cash_core::recurring`), the same mechanism `BudgetBook`/`GoalBook` use.
/// Which occurrences are "upcoming" is never stored — `upcoming_occurrences`
/// computes it fresh by finding, per rule, the latest ledger transaction
/// tagged with that rule's ID and stepping forward from there.
#[frb(opaque)]
pub struct RecurringBook {
    data: Mutex<RecurringBookData>,
}

struct RecurringBookData {
    actor_id: String,
    upserts: Vec<RecurringUpsert>,
    last_timestamp: HybridTimestamp,
    recovered_upsert_count: u64,
    truncated_bytes: u64,
}

/// Mirrors `cash_core::RecurringKind` as a bridge-visible type (kept as its
/// own type for the same reason `goals::GoalKind` is: `rust/core` never
/// depends on `flutter_rust_bridge`).
pub enum RecurringKind {
    Expense,
    Income,
}

impl From<RecurringKind> for CoreRecurringKind {
    fn from(value: RecurringKind) -> Self {
        match value {
            RecurringKind::Expense => Self::Expense,
            RecurringKind::Income => Self::Income,
        }
    }
}

/// Mirrors `cash_core::RecurringFrequency`.
#[derive(Debug, PartialEq)]
pub enum RecurringFrequency {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

impl From<RecurringFrequency> for CoreRecurringFrequency {
    fn from(value: RecurringFrequency) -> Self {
        match value {
            RecurringFrequency::Daily => Self::Daily,
            RecurringFrequency::Weekly => Self::Weekly,
            RecurringFrequency::Monthly => Self::Monthly,
            RecurringFrequency::Yearly => Self::Yearly,
        }
    }
}

impl From<CoreRecurringFrequency> for RecurringFrequency {
    fn from(value: CoreRecurringFrequency) -> Self {
        match value {
            CoreRecurringFrequency::Daily => Self::Daily,
            CoreRecurringFrequency::Weekly => Self::Weekly,
            CoreRecurringFrequency::Monthly => Self::Monthly,
            CoreRecurringFrequency::Yearly => Self::Yearly,
        }
    }
}

pub struct RecurringMutation {
    pub appended_frame: Vec<u8>,
}

pub struct RecurringLoadReport {
    pub recovered_upsert_count: u64,
    pub truncated_bytes: u64,
}

/// One recurring rule's next due occurrence, computed fresh (see module
/// docs). `is_overdue` is true when the occurrence is at or before the
/// caller's `now_millis`.
#[derive(Debug, PartialEq)]
pub struct UpcomingView {
    pub recurring_id: String,
    pub title: String,
    pub is_expense: bool,
    pub amount_label: String,
    pub account_id: String,
    pub category_id: Option<String>,
    pub frequency: RecurringFrequency,
    pub occurrence_millis: i64,
    pub is_overdue: bool,
}

/// Opens a recurring-rule book by replaying a durable log's bytes. Pass an
/// empty `log_bytes` for a brand-new installation; matches
/// `ledger::load_personal_ledger`/`budgets::load_budget_book`/
/// `goals::load_goal_book`.
pub fn load_recurring_book(actor_id: String, log_bytes: Vec<u8>) -> Result<RecurringBook, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let decoded = decode_recurring_log(&log_bytes);
    let last_timestamp = decoded
        .upserts
        .iter()
        .map(|upsert| upsert.timestamp)
        .max()
        .unwrap_or(HybridTimestamp::new(0, 0));
    let recovered_upsert_count = decoded.upserts.len() as u64;

    Ok(RecurringBook {
        data: Mutex::new(RecurringBookData {
            actor_id,
            upserts: decoded.upserts,
            last_timestamp,
            recovered_upsert_count,
            truncated_bytes: decoded.trailing_garbage_bytes as u64,
        }),
    })
}

pub fn recurring_load_report(book: &RecurringBook) -> Result<RecurringLoadReport, String> {
    let data = lock(book)?;
    Ok(RecurringLoadReport {
        recovered_upsert_count: data.recovered_upsert_count,
        truncated_bytes: data.truncated_bytes,
    })
}

/// Creates or updates a recurring rule. `amount`/`currency_code` must use
/// `account_id`'s own currency, exactly like `ledger::record_transaction`,
/// since recording a due occurrence calls that same function with these
/// values.
#[allow(clippy::too_many_arguments)]
pub fn upsert_recurring(
    book: &RecurringBook,
    recurring_id: String,
    title: String,
    kind: RecurringKind,
    amount: String,
    currency_code: String,
    account_id: String,
    category_id: Option<String>,
    frequency: RecurringFrequency,
    start_millis: i64,
    wall_clock_millis: i64,
) -> Result<RecurringMutation, String> {
    let title = title.trim().to_owned();
    if title.is_empty() {
        return Err("recurring rule title cannot be empty".to_owned());
    }
    if recurring_id.trim().is_empty() {
        return Err("recurring rule ID cannot be empty".to_owned());
    }
    if account_id.trim().is_empty() {
        return Err("recurring rule must name an account".to_owned());
    }
    let currency = cash_core::Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    let amount_minor = currency
        .parse_major_units(&amount)
        .map_err(|error| error.to_string())?;
    if amount_minor <= 0 {
        return Err("recurring amount must be greater than zero".to_owned());
    }

    let mut data = lock(book)?;
    let timestamp = data.next_timestamp(wall_clock_millis);
    let event_id = format!(
        "{}-{:016x}-{:08x}",
        data.actor_id, timestamp.physical_millis, timestamp.logical
    );
    let upsert = RecurringUpsert::new(
        event_id,
        data.actor_id.clone(),
        timestamp.physical_millis,
        timestamp.logical,
        RecurringId::new(recurring_id),
        title,
        kind.into(),
        amount_minor,
        account_id,
        category_id,
        frequency.into(),
        start_millis,
    );
    let appended_frame = encode_recurring_frame(&upsert);
    data.upserts.push(upsert);
    Ok(RecurringMutation { appended_frame })
}

/// Every rule's next occurrence at or before `now_millis + horizon_days`.
/// For each rule, the anchor is the latest ledger transaction tagged with
/// its `recurring_id` (or the rule's own `start_millis`, if none has been
/// recorded yet); the occurrence returned is the first one strictly after
/// that anchor.
pub fn upcoming_occurrences(
    ledger: &PersonalLedger,
    book: &RecurringBook,
    now_millis: i64,
    horizon_days: u32,
) -> Result<Vec<UpcomingView>, String> {
    let state = folded_state(ledger)?;
    let rule_state = fold_recurring(lock(book)?.upserts.iter().cloned());
    let horizon_millis = now_millis
        .checked_add(i64::from(horizon_days) * 86_400_000)
        .ok_or_else(|| "horizon overflowed".to_owned())?;

    let mut views = Vec::with_capacity(rule_state.rules.len());
    for (id, record) in &rule_state.rules {
        let last_recorded = state
            .transactions
            .values()
            .filter(|transaction| transaction.recurring_id.as_deref() == Some(id.as_str()))
            .map(|transaction| transaction.recorded_at_millis)
            .max();
        let occurrence_millis =
            next_occurrence_millis(record.frequency, record.start_millis, last_recorded);
        if occurrence_millis > horizon_millis {
            continue;
        }
        let account = state
            .accounts
            .get(&cash_core::AccountId::new(&record.account_id))
            .ok_or_else(|| format!("account {} not found", record.account_id))?;
        views.push(UpcomingView {
            recurring_id: id.as_str().to_owned(),
            title: record.title.clone(),
            is_expense: record.kind == CoreRecurringKind::Expense,
            amount_label: account.currency.format_minor_units(record.amount_minor),
            account_id: record.account_id.clone(),
            category_id: record.category_id.clone(),
            frequency: record.frequency.into(),
            occurrence_millis,
            is_overdue: occurrence_millis <= now_millis,
        });
    }
    views.sort_by_key(|view| view.occurrence_millis);
    Ok(views)
}

fn lock(book: &RecurringBook) -> Result<MutexGuard<'_, RecurringBookData>, String> {
    book.data
        .lock()
        .map_err(|_| "recurring book lock was poisoned".to_owned())
}

impl RecurringBookData {
    fn next_timestamp(&mut self, wall_clock_millis: i64) -> HybridTimestamp {
        let timestamp = if wall_clock_millis > self.last_timestamp.physical_millis {
            HybridTimestamp::new(wall_clock_millis, 0)
        } else {
            HybridTimestamp::new(
                self.last_timestamp.physical_millis,
                self.last_timestamp.logical.saturating_add(1),
            )
        };
        self.last_timestamp = timestamp;
        timestamp
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::ledger::{add_account, load_personal_ledger, record_transaction};
    use crate::api::ledger::EntryKind;

    fn new_book(actor_id: &str) -> RecurringBook {
        load_recurring_book(actor_id.to_owned(), Vec::new()).unwrap()
    }

    fn new_ledger_with_checking(actor_id: &str) -> PersonalLedger {
        let ledger =
            load_personal_ledger(actor_id.to_owned(), "USD".to_owned(), Vec::new()).unwrap();
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        ledger
    }

    #[test]
    fn a_new_rule_is_upcoming_at_its_start_date() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        let start = 1_800_000_000_000;
        upsert_recurring(
            &book,
            "rent".to_owned(),
            "Rent".to_owned(),
            RecurringKind::Expense,
            "1500.00".to_owned(),
            "USD".to_owned(),
            "checking".to_owned(),
            None,
            RecurringFrequency::Monthly,
            start,
            1,
        )
        .unwrap();

        let upcoming = upcoming_occurrences(&ledger, &book, start, 0).unwrap();
        assert_eq!(upcoming.len(), 1);
        assert_eq!(upcoming[0].title, "Rent");
        assert_eq!(upcoming[0].amount_label, "USD 1500.00");
        assert_eq!(upcoming[0].occurrence_millis, start);
        assert!(upcoming[0].is_overdue);
    }

    #[test]
    fn a_rule_outside_the_horizon_is_not_returned() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        let start = 1_800_000_000_000 + 30 * 86_400_000; // 30 days from "now"
        upsert_recurring(
            &book,
            "rent".to_owned(),
            "Rent".to_owned(),
            RecurringKind::Expense,
            "1500.00".to_owned(),
            "USD".to_owned(),
            "checking".to_owned(),
            None,
            RecurringFrequency::Monthly,
            start,
            1,
        )
        .unwrap();

        let upcoming = upcoming_occurrences(&ledger, &book, 1_800_000_000_000, 7).unwrap();
        assert!(upcoming.is_empty());
    }

    #[test]
    fn recording_the_current_occurrence_advances_the_next_one() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        let start = 1_800_000_000_000;
        upsert_recurring(
            &book,
            "rent".to_owned(),
            "Rent".to_owned(),
            RecurringKind::Expense,
            "1500.00".to_owned(),
            "USD".to_owned(),
            "checking".to_owned(),
            None,
            RecurringFrequency::Monthly,
            start,
            1,
        )
        .unwrap();

        record_transaction(
            &ledger,
            "t1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "1500.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Rent".to_owned(),
            None,
            Some("rent".to_owned()),
            start,
        )
        .unwrap();

        let upcoming = upcoming_occurrences(&ledger, &book, start, 60).unwrap();
        assert_eq!(upcoming.len(), 1);
        assert!(upcoming[0].occurrence_millis > start);
    }

    #[test]
    fn restart_recovers_a_rule_from_its_persisted_frame() {
        let book = new_book("device-a");
        let frame = upsert_recurring(
            &book,
            "rent".to_owned(),
            "Rent".to_owned(),
            RecurringKind::Expense,
            "1500.00".to_owned(),
            "USD".to_owned(),
            "checking".to_owned(),
            None,
            RecurringFrequency::Monthly,
            1,
            1,
        )
        .unwrap()
        .appended_frame;

        let restarted = load_recurring_book("device-a".to_owned(), frame).unwrap();
        let report = recurring_load_report(&restarted).unwrap();
        assert_eq!(report.recovered_upsert_count, 1);
        assert_eq!(report.truncated_bytes, 0);
    }
}
