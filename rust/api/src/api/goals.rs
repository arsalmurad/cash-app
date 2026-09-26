use std::sync::{Mutex, MutexGuard};

use cash_core::{
    GoalId, GoalKind as CoreGoalKind, GoalUpsert, HybridTimestamp, TransactionKind,
    decode_goal_log, encode_goal_frame, fold_goals,
};
use flutter_rust_bridge::frb;

use super::ledger::{PersonalLedger, folded_state};

/// Goals are soft state, folded by last-writer-wins (see `cash_core::goals`),
/// the same mechanism `CategoryBook`/`BudgetBook` use and for the same
/// reason: a goal's name, kind, target, and deadline have no financial
/// invariant to protect. Progress toward a goal is never stored —
/// `goal_progress` computes it fresh from the ledger on every call, so it
/// can never drift from the financial source of truth.
#[frb(opaque)]
pub struct GoalBook {
    data: Mutex<GoalBookData>,
}

struct GoalBookData {
    actor_id: String,
    upserts: Vec<GoalUpsert>,
    last_timestamp: HybridTimestamp,
    recovered_upsert_count: u64,
    truncated_bytes: u64,
}

/// Mirrors `cash_core::GoalKind` as a bridge-visible type (kept as its own
/// type, rather than re-exporting the core enum, so `rust/core` never
/// depends on `flutter_rust_bridge`).
pub enum GoalKind {
    Save,
    Spend,
}

impl From<GoalKind> for CoreGoalKind {
    fn from(value: GoalKind) -> Self {
        match value {
            GoalKind::Save => Self::Save,
            GoalKind::Spend => Self::Spend,
        }
    }
}

pub struct GoalMutation {
    pub appended_frame: Vec<u8>,
}

pub struct GoalLoadReport {
    pub recovered_upsert_count: u64,
    pub truncated_bytes: u64,
}

/// A goal's current progress, computed fresh from the ledger (see module
/// docs). `percent_complete` can exceed 100 (over-saved, or over-spent past
/// a spending cap); it is never negative.
#[derive(Debug, PartialEq)]
pub struct GoalView {
    pub id: String,
    pub name: String,
    pub is_save: bool,
    pub linked_account_id: Option<String>,
    pub category_id: Option<String>,
    pub target_label: String,
    pub progress_label: String,
    pub percent_complete: i64,
    pub deadline_millis: Option<i64>,
}

/// Opens a goal book by replaying a durable log's bytes. Pass an empty
/// `log_bytes` for a brand-new installation; matches
/// `ledger::load_personal_ledger`/`categories::load_category_book`/
/// `budgets::load_budget_book`.
pub fn load_goal_book(actor_id: String, log_bytes: Vec<u8>) -> Result<GoalBook, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let decoded = decode_goal_log(&log_bytes);
    let last_timestamp = decoded
        .upserts
        .iter()
        .map(|upsert| upsert.timestamp)
        .max()
        .unwrap_or(HybridTimestamp::new(0, 0));
    let recovered_upsert_count = decoded.upserts.len() as u64;

    Ok(GoalBook {
        data: Mutex::new(GoalBookData {
            actor_id,
            upserts: decoded.upserts,
            last_timestamp,
            recovered_upsert_count,
            truncated_bytes: decoded.trailing_garbage_bytes as u64,
        }),
    })
}

pub fn goal_load_report(book: &GoalBook) -> Result<GoalLoadReport, String> {
    let data = lock(book)?;
    Ok(GoalLoadReport {
        recovered_upsert_count: data.recovered_upsert_count,
        truncated_bytes: data.truncated_bytes,
    })
}

/// Creates or updates a goal. A save goal must name the account whose
/// balance counts toward the target and must leave `category_id` unset; a
/// spend goal must leave `linked_account_id` unset (its cap can optionally
/// be scoped to one category). `target_amount`/`target_currency_code` must
/// use the same currency as whatever the goal is measured against (the
/// linked account for a save goal, the ledger's reporting currency for a
/// spend goal) — see `goal_progress` and `docs/DECISIONS.md`.
#[allow(clippy::too_many_arguments)]
pub fn upsert_goal(
    book: &GoalBook,
    goal_id: String,
    name: String,
    kind: GoalKind,
    target_amount: String,
    target_currency_code: String,
    linked_account_id: Option<String>,
    category_id: Option<String>,
    deadline_millis: Option<i64>,
    wall_clock_millis: i64,
) -> Result<GoalMutation, String> {
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err("goal name cannot be empty".to_owned());
    }
    if goal_id.trim().is_empty() {
        return Err("goal ID cannot be empty".to_owned());
    }
    let kind: CoreGoalKind = kind.into();
    match kind {
        CoreGoalKind::Save => {
            if linked_account_id.is_none() {
                return Err("a saving goal must link an account".to_owned());
            }
            if category_id.is_some() {
                return Err("a saving goal cannot have a category".to_owned());
            }
        }
        CoreGoalKind::Spend => {
            if linked_account_id.is_some() {
                return Err("a spending goal cannot link an account".to_owned());
            }
        }
    }
    let currency =
        cash_core::Currency::from_code(&target_currency_code).map_err(|error| error.to_string())?;
    let target_minor = currency
        .parse_major_units(&target_amount)
        .map_err(|error| error.to_string())?;
    if target_minor <= 0 {
        return Err("goal target must be greater than zero".to_owned());
    }

    let mut data = lock(book)?;
    let timestamp = data.next_timestamp(wall_clock_millis);
    let event_id = format!(
        "{}-{:016x}-{:08x}",
        data.actor_id, timestamp.physical_millis, timestamp.logical
    );
    let upsert = GoalUpsert::new(
        event_id,
        data.actor_id.clone(),
        timestamp.physical_millis,
        timestamp.logical,
        GoalId::new(goal_id),
        name,
        kind,
        target_minor,
        linked_account_id,
        category_id,
        deadline_millis,
    );
    let appended_frame = encode_goal_frame(&upsert);
    data.upserts.push(upsert);
    Ok(GoalMutation { appended_frame })
}

/// Every goal's current progress. A save goal's progress is its linked
/// account's current balance; a spend goal's progress is the total of its
/// matching (non-voided) expenses recorded since the goal was first created
/// (the earliest upsert for that `goal_id`) up to its deadline, if any. There
/// is no `now_millis` parameter (unlike `budget_progress`): a goal's window
/// starts at its own creation and never rolls forward, so nothing here
/// depends on the caller's wall clock.
pub fn goal_progress(ledger: &PersonalLedger, book: &GoalBook) -> Result<Vec<GoalView>, String> {
    let state = folded_state(ledger)?;
    let upserts = lock(book)?.upserts.clone();
    let goal_state = fold_goals(upserts.iter().cloned());

    let mut created_at_millis: std::collections::BTreeMap<GoalId, i64> =
        std::collections::BTreeMap::new();
    for upsert in &upserts {
        let entry = created_at_millis
            .entry(upsert.goal_id.clone())
            .or_insert(upsert.timestamp.physical_millis);
        if upsert.timestamp.physical_millis < *entry {
            *entry = upsert.timestamp.physical_millis;
        }
    }

    let mut views = Vec::with_capacity(goal_state.goals.len());
    for (id, record) in &goal_state.goals {
        let (progress_minor, progress_currency_label) = match record.kind {
            CoreGoalKind::Save => {
                let account_id = record
                    .linked_account_id
                    .as_deref()
                    .ok_or_else(|| "save goal missing its linked account".to_owned())?;
                let account = state
                    .accounts
                    .get(&cash_core::AccountId::new(account_id))
                    .ok_or_else(|| format!("linked account {account_id} not found"))?;
                (
                    account.native_balance_minor,
                    account.currency.format_minor_units(account.native_balance_minor),
                )
            }
            CoreGoalKind::Spend => {
                let start = created_at_millis
                    .get(id)
                    .copied()
                    .unwrap_or(i64::MIN);
                let end = record.deadline_millis.unwrap_or(i64::MAX);
                let mut spent_minor: i64 = 0;
                for transaction in state.transactions.values() {
                    let matches_category = match &record.category_id {
                        Some(wanted) => transaction.category_id.as_deref() == Some(wanted.as_str()),
                        None => true,
                    };
                    if transaction.voided
                        || transaction.kind != TransactionKind::Expense
                        || transaction.recorded_at_millis < start
                        || transaction.recorded_at_millis > end
                        || !matches_category
                    {
                        continue;
                    }
                    spent_minor = spent_minor
                        .checked_add(transaction.reporting_minor)
                        .ok_or_else(|| "goal spend overflowed".to_owned())?;
                }
                (
                    spent_minor,
                    state.reporting_currency.format_minor_units(spent_minor),
                )
            }
        };

        let target_label = match record.kind {
            CoreGoalKind::Save => {
                let account_id = record.linked_account_id.as_deref().unwrap_or_default();
                match state.accounts.get(&cash_core::AccountId::new(account_id)) {
                    Some(account) => account.currency.format_minor_units(record.target_minor),
                    None => state.reporting_currency.format_minor_units(record.target_minor),
                }
            }
            CoreGoalKind::Spend => state.reporting_currency.format_minor_units(record.target_minor),
        };

        let percent_complete = if record.target_minor > 0 {
            progress_minor
                .max(0)
                .checked_mul(100)
                .ok_or_else(|| "goal percentage overflowed".to_owned())?
                / record.target_minor
        } else {
            0
        };

        views.push(GoalView {
            id: id.as_str().to_owned(),
            name: record.name.clone(),
            is_save: record.kind == CoreGoalKind::Save,
            linked_account_id: record.linked_account_id.clone(),
            category_id: record.category_id.clone(),
            target_label,
            progress_label: progress_currency_label,
            percent_complete,
            deadline_millis: record.deadline_millis,
        });
    }
    Ok(views)
}

fn lock(book: &GoalBook) -> Result<MutexGuard<'_, GoalBookData>, String> {
    book.data
        .lock()
        .map_err(|_| "goal book lock was poisoned".to_owned())
}

impl GoalBookData {
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
    use crate::api::ledger::{EntryKind, LedgerMutation, add_account, load_personal_ledger, record_transaction};

    fn new_book(actor_id: &str) -> GoalBook {
        load_goal_book(actor_id.to_owned(), Vec::new()).unwrap()
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

    fn spend(
        ledger: &PersonalLedger,
        id: &str,
        amount: &str,
        category_id: Option<&str>,
        wall_clock_millis: i64,
    ) -> LedgerMutation {
        record_transaction(
            ledger,
            id.to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            amount.to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Spend".to_owned(),
            category_id.map(str::to_owned),
            None,
            wall_clock_millis,
        )
        .unwrap()
    }

    fn earn(ledger: &PersonalLedger, id: &str, amount: &str, wall_clock_millis: i64) {
        record_transaction(
            ledger,
            id.to_owned(),
            "checking".to_owned(),
            EntryKind::Income,
            amount.to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Paycheck".to_owned(),
            None,
            None,
            wall_clock_millis,
        )
        .unwrap();
    }

    #[test]
    fn a_save_goal_tracks_its_linked_account_balance() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        upsert_goal(
            &book,
            "vacation".to_owned(),
            "Vacation".to_owned(),
            GoalKind::Save,
            "1000.00".to_owned(),
            "USD".to_owned(),
            Some("checking".to_owned()),
            None,
            None,
            1,
        )
        .unwrap();
        earn(&ledger, "t1", "250.00", 2);

        let progress = goal_progress(&ledger, &book).unwrap();
        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].name, "Vacation");
        assert_eq!(progress[0].target_label, "USD 1000.00");
        assert_eq!(progress[0].progress_label, "USD 250.00");
        assert_eq!(progress[0].percent_complete, 25);
    }

    #[test]
    fn a_spend_goal_sums_matching_expenses_since_creation() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        let created_at = 1_800_000_000_000;
        upsert_goal(
            &book,
            "less-takeout".to_owned(),
            "Less takeout".to_owned(),
            GoalKind::Spend,
            "100.00".to_owned(),
            "USD".to_owned(),
            None,
            Some("food".to_owned()),
            None,
            created_at,
        )
        .unwrap();
        spend(&ledger, "t1", "40.00", Some("food"), created_at + 1);
        spend(&ledger, "t2", "10.00", Some("transport"), created_at + 1);

        let progress = goal_progress(&ledger, &book).unwrap();
        assert_eq!(progress[0].progress_label, "USD 40.00");
        assert_eq!(progress[0].percent_complete, 40);
    }

    #[test]
    fn a_spend_goal_ignores_expenses_before_it_was_created() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        spend(&ledger, "t1", "40.00", Some("food"), 1);
        let created_at = 1_800_000_000_000;
        upsert_goal(
            &book,
            "less-takeout".to_owned(),
            "Less takeout".to_owned(),
            GoalKind::Spend,
            "100.00".to_owned(),
            "USD".to_owned(),
            None,
            Some("food".to_owned()),
            None,
            created_at,
        )
        .unwrap();

        let progress = goal_progress(&ledger, &book).unwrap();
        assert_eq!(progress[0].progress_label, "USD 0.00");
    }

    #[test]
    fn a_save_goal_must_link_an_account() {
        let book = new_book("device-a");
        let result = upsert_goal(
            &book,
            "vacation".to_owned(),
            "Vacation".to_owned(),
            GoalKind::Save,
            "1000.00".to_owned(),
            "USD".to_owned(),
            None,
            None,
            None,
            1,
        );
        assert!(result.is_err());
    }

    #[test]
    fn a_spend_goal_cannot_link_an_account() {
        let book = new_book("device-a");
        let result = upsert_goal(
            &book,
            "less-takeout".to_owned(),
            "Less takeout".to_owned(),
            GoalKind::Spend,
            "100.00".to_owned(),
            "USD".to_owned(),
            Some("checking".to_owned()),
            None,
            None,
            1,
        );
        assert!(result.is_err());
    }

    #[test]
    fn restart_recovers_a_goal_from_its_persisted_frame() {
        let book = new_book("device-a");
        let frame = upsert_goal(
            &book,
            "vacation".to_owned(),
            "Vacation".to_owned(),
            GoalKind::Save,
            "1000.00".to_owned(),
            "USD".to_owned(),
            Some("checking".to_owned()),
            None,
            None,
            1,
        )
        .unwrap()
        .appended_frame;

        let restarted = load_goal_book("device-a".to_owned(), frame).unwrap();
        let report = goal_load_report(&restarted).unwrap();
        assert_eq!(report.recovered_upsert_count, 1);
        assert_eq!(report.truncated_bytes, 0);
    }
}
