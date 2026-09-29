use std::sync::{Mutex, MutexGuard};

use cash_core::{
    BudgetId, BudgetPeriod, BudgetUpsert, HybridTimestamp, TransactionKind, decode_budget_log,
    encode_budget_frame, fold_budgets, period_start_millis,
};
use flutter_rust_bridge::frb;

use super::ledger::{PersonalLedger, folded_state};

/// Budgets are soft state, folded by last-writer-wins (see
/// `cash_core::budgets`), the same mechanism `CategoryBook` uses and for the
/// same reason: a budget's name, limit, category, and period have no
/// financial invariant to protect. How much of a budget is spent is never
/// stored — `budget_progress` computes it fresh from the ledger on every
/// call, so it can never drift from the financial source of truth.
#[frb(opaque)]
pub struct BudgetBook {
    data: Mutex<BudgetBookData>,
}

struct BudgetBookData {
    actor_id: String,
    upserts: Vec<BudgetUpsert>,
    last_timestamp: HybridTimestamp,
    recovered_upsert_count: u64,
    truncated_bytes: u64,
}

/// Mirrors `cash_core::BudgetPeriod` as a bridge-visible type. Kept
/// field-less (unlike the core type's `Custom { days }`) with the day count
/// passed alongside as its own parameter in `upsert_budget`: a data-carrying
/// enum here would need `flutter_rust_bridge` to generate a `freezed` union
/// type on the Dart side, pulling in a code-generation dependency this
/// project otherwise has no use for, for one field.
pub enum BudgetPeriodKind {
    Weekly,
    Monthly,
    Yearly,
    Custom,
}

impl BudgetPeriodKind {
    fn resolve(self, custom_days: Option<u32>) -> Result<BudgetPeriod, String> {
        match self {
            Self::Weekly => Ok(BudgetPeriod::Weekly),
            Self::Monthly => Ok(BudgetPeriod::Monthly),
            Self::Yearly => Ok(BudgetPeriod::Yearly),
            Self::Custom => {
                let days = custom_days
                    .ok_or_else(|| "a custom period requires custom_days".to_owned())?;
                if days == 0 {
                    return Err("a custom period must be at least one day".to_owned());
                }
                Ok(BudgetPeriod::Custom { days })
            }
        }
    }
}

pub struct BudgetMutation {
    pub appended_frame: Vec<u8>,
}

pub struct BudgetLoadReport {
    pub recovered_upsert_count: u64,
    pub truncated_bytes: u64,
}

/// A budget's current progress, computed fresh from the ledger's expenses in
/// its period (see module docs). `percent_used` can exceed 100 when a budget
/// is overspent; it is never negative.
#[derive(Debug, PartialEq)]
pub struct BudgetView {
    pub id: String,
    pub name: String,
    pub category_id: Option<String>,
    pub period_label: String,
    pub limit_label: String,
    pub spent_label: String,
    pub percent_used: i64,
}

/// Opens a budget book by replaying a durable log's bytes. Pass an empty
/// `log_bytes` for a brand-new installation; matches
/// `ledger::load_personal_ledger`/`categories::load_category_book`.
pub fn load_budget_book(actor_id: String, log_bytes: Vec<u8>) -> Result<BudgetBook, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let decoded = decode_budget_log(&log_bytes);
    let last_timestamp = decoded
        .upserts
        .iter()
        .map(|upsert| upsert.timestamp)
        .max()
        .unwrap_or(HybridTimestamp::new(0, 0));
    let recovered_upsert_count = decoded.upserts.len() as u64;

    Ok(BudgetBook {
        data: Mutex::new(BudgetBookData {
            actor_id,
            upserts: decoded.upserts,
            last_timestamp,
            recovered_upsert_count,
            truncated_bytes: decoded.trailing_garbage_bytes as u64,
        }),
    })
}

pub fn budget_load_report(book: &BudgetBook) -> Result<BudgetLoadReport, String> {
    let data = lock(book)?;
    Ok(BudgetLoadReport {
        recovered_upsert_count: data.recovered_upsert_count,
        truncated_bytes: data.truncated_bytes,
    })
}

/// Creates or updates a budget. `limit_amount`/`limit_currency_code` must use
/// the ledger's reporting currency: budget progress is always computed and
/// displayed in that currency (see `budget_progress`), so a mismatched
/// currency here would silently compare unlike units.
#[allow(clippy::too_many_arguments)]
pub fn upsert_budget(
    book: &BudgetBook,
    budget_id: String,
    name: String,
    category_id: Option<String>,
    limit_amount: String,
    limit_currency_code: String,
    period: BudgetPeriodKind,
    custom_period_days: Option<u32>,
    wall_clock_millis: i64,
) -> Result<BudgetMutation, String> {
    let name = name.trim().to_owned();
    if name.is_empty() {
        return Err("budget name cannot be empty".to_owned());
    }
    if budget_id.trim().is_empty() {
        return Err("budget ID cannot be empty".to_owned());
    }
    let currency = cash_core::Currency::from_code(&limit_currency_code)
        .map_err(|error| error.to_string())?;
    let limit_minor = currency
        .parse_major_units(&limit_amount)
        .map_err(|error| error.to_string())?;
    if limit_minor <= 0 {
        return Err("budget limit must be greater than zero".to_owned());
    }
    let period = period.resolve(custom_period_days)?;

    let mut data = lock(book)?;
    let timestamp = data.next_timestamp(wall_clock_millis);
    let event_id = format!(
        "{}-{:016x}-{:08x}",
        data.actor_id, timestamp.physical_millis, timestamp.logical
    );
    let upsert = BudgetUpsert::new(
        event_id,
        data.actor_id.clone(),
        timestamp.physical_millis,
        timestamp.logical,
        BudgetId::new(budget_id),
        name,
        category_id,
        limit_minor,
        period,
    );
    let appended_frame = encode_budget_frame(&upsert);
    data.upserts.push(upsert);
    Ok(BudgetMutation { appended_frame })
}

/// Every budget's current progress, computed against `now_millis` (the
/// caller's wall clock — this crate has no wall-clock dependency of its own).
pub fn budget_progress(
    ledger: &PersonalLedger,
    book: &BudgetBook,
    now_millis: i64,
) -> Result<Vec<BudgetView>, String> {
    let state = folded_state(ledger)?;
    let budget_state = fold_budgets(lock(book)?.upserts.iter().cloned());

    let mut views = Vec::with_capacity(budget_state.budgets.len());
    for (id, record) in &budget_state.budgets {
        let period_start = period_start_millis(record.period, now_millis);
        let mut spent_minor: i64 = 0;
        for transaction in state.transactions.values() {
            let matches_category = match &record.category_id {
                Some(wanted) => transaction.category_id.as_deref() == Some(wanted.as_str()),
                None => true,
            };
            if transaction.voided
                || transaction.kind != TransactionKind::Expense
                || transaction.recorded_at_millis < period_start
                || !matches_category
            {
                continue;
            }
            spent_minor = spent_minor
                .checked_add(transaction.reporting_minor)
                .ok_or_else(|| "budget spend overflowed".to_owned())?;
        }

        let percent_used = if record.limit_minor > 0 {
            spent_minor
                .checked_mul(100)
                .ok_or_else(|| "budget percentage overflowed".to_owned())?
                / record.limit_minor
        } else {
            0
        };

        views.push(BudgetView {
            id: id.as_str().to_owned(),
            name: record.name.clone(),
            category_id: record.category_id.clone(),
            period_label: period_label(record.period),
            limit_label: state
                .reporting_currency
                .format_minor_units(record.limit_minor),
            spent_label: state.reporting_currency.format_minor_units(spent_minor),
            percent_used,
        });
    }
    Ok(views)
}

fn period_label(period: BudgetPeriod) -> String {
    match period {
        BudgetPeriod::Weekly => "This week".to_owned(),
        BudgetPeriod::Monthly => "This month".to_owned(),
        BudgetPeriod::Yearly => "This year".to_owned(),
        BudgetPeriod::Custom { days } => format!("Last {days} days"),
    }
}

fn lock(book: &BudgetBook) -> Result<MutexGuard<'_, BudgetBookData>, String> {
    book.data
        .lock()
        .map_err(|_| "budget book lock was poisoned".to_owned())
}

impl BudgetBookData {
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
    use crate::api::ledger::{EntryKind, LedgerMutation};

    fn new_book(actor_id: &str) -> BudgetBook {
        load_budget_book(actor_id.to_owned(), Vec::new()).unwrap()
    }

    fn new_ledger_with_checking(actor_id: &str) -> PersonalLedger {
        let ledger = load_personal_ledger(actor_id.to_owned(), "USD".to_owned(), Vec::new())
            .unwrap();
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

    #[test]
    fn upserting_a_budget_makes_it_listable_with_zero_progress() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        upsert_budget(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            Some("food".to_owned()),
            "300.00".to_owned(),
            "USD".to_owned(),
            BudgetPeriodKind::Monthly,
            None,
            1,
        )
        .unwrap();

        let progress = budget_progress(&ledger, &book, 1_000).unwrap();
        assert_eq!(progress.len(), 1);
        assert_eq!(progress[0].name, "Food");
        assert_eq!(progress[0].limit_label, "USD 300.00");
        assert_eq!(progress[0].spent_label, "USD 0.00");
        assert_eq!(progress[0].percent_used, 0);
    }

    #[test]
    fn spending_in_the_budgets_category_advances_its_progress() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        // A period start comfortably within the current month for any test
        // run date: pin `now` far in the future instead of relying on the
        // real wall clock, so the budget's monthly window always contains
        // both the budget's creation and the spend below.
        let now = 1_800_000_000_000; // 2027-01-15, well clear of month edges
        upsert_budget(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            Some("food".to_owned()),
            "300.00".to_owned(),
            "USD".to_owned(),
            BudgetPeriodKind::Monthly,
            None,
            now,
        )
        .unwrap();
        spend(&ledger, "t1", "75.00", Some("food"), now);
        spend(&ledger, "t2", "50.00", Some("transport"), now);

        let progress = budget_progress(&ledger, &book, now).unwrap();
        assert_eq!(progress[0].spent_label, "USD 75.00");
        assert_eq!(progress[0].percent_used, 25);
    }

    #[test]
    fn a_budget_with_no_category_covers_every_expense() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        let now = 1_800_000_000_000;
        upsert_budget(
            &book,
            "overall".to_owned(),
            "Everything".to_owned(),
            None,
            "1000.00".to_owned(),
            "USD".to_owned(),
            BudgetPeriodKind::Monthly,
            None,
            now,
        )
        .unwrap();
        spend(&ledger, "t1", "75.00", Some("food"), now);
        spend(&ledger, "t2", "50.00", Some("transport"), now);
        spend(&ledger, "t3", "10.00", None, now);

        let progress = budget_progress(&ledger, &book, now).unwrap();
        assert_eq!(progress[0].spent_label, "USD 135.00");
    }

    #[test]
    fn spending_before_the_period_start_does_not_count() {
        let ledger = new_ledger_with_checking("device-a");
        let book = new_book("device-a");
        // Spend on 2027-01-01 (before the period start), then create a
        // weekly budget as of 2027-01-15: the old spend must not count.
        let old_spend_time = 1_798_761_600_000; // 2027-01-01T00:00:00Z
        let now = 1_800_000_000_000; // 2027-01-15
        spend(&ledger, "t1", "75.00", Some("food"), old_spend_time);
        upsert_budget(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            Some("food".to_owned()),
            "300.00".to_owned(),
            "USD".to_owned(),
            BudgetPeriodKind::Weekly,
            None,
            now,
        )
        .unwrap();

        let progress = budget_progress(&ledger, &book, now).unwrap();
        assert_eq!(progress[0].spent_label, "USD 0.00");
    }

    #[test]
    fn restart_recovers_a_budget_from_its_persisted_frame() {
        let book = new_book("device-a");
        let frame = upsert_budget(
            &book,
            "food".to_owned(),
            "Food".to_owned(),
            Some("food".to_owned()),
            "300.00".to_owned(),
            "USD".to_owned(),
            BudgetPeriodKind::Monthly,
            None,
            1,
        )
        .unwrap()
        .appended_frame;

        let restarted = load_budget_book("device-a".to_owned(), frame).unwrap();
        let report = budget_load_report(&restarted).unwrap();
        assert_eq!(report.recovered_upsert_count, 1);
        assert_eq!(report.truncated_bytes, 0);
    }
}
