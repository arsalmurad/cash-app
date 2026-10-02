//! Budgets are soft state, exactly like categories (see `categories.rs` and
//! build brief §2.5): a budget's name, limit, category, and period are fine
//! to settle with last-writer-wins. How much of a budget has been spent is
//! never stored here — it is always computed fresh from the ledger's
//! transactions (see `rust/api/src/api/budgets.rs`), so there is nothing in
//! this module that could drift out of sync with the financial source of
//! truth.

use std::collections::BTreeMap;

use crate::bytes_io::{Reader, write_bool, write_i64, write_string, write_u32};
use crate::calendar::{MILLIS_PER_DAY, civil_from_days, days_from_civil};
use crate::frame::{DecodedFrameLog, decode_frame_log, encode_frame};
use crate::{ActorId, EventId, HybridTimestamp};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct BudgetId(String);

impl BudgetId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// How a budget's spending window is chosen relative to a point in time.
/// `Weekly`/`Monthly`/`Yearly` are the calendar period containing that
/// instant (weeks start Monday, UTC); `Custom` is a rolling window of that
/// many days ending at that instant, for a period length that doesn't align
/// to a calendar unit.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BudgetPeriod {
    Weekly,
    Monthly,
    Yearly,
    Custom { days: u32 },
}

/// One "set this budget's name, limit, category, and period" write. Every
/// write is an upsert; the highest `(timestamp, actor_id)` writer for a given
/// `budget_id` wins, identically to `categories::CategoryUpsert`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BudgetUpsert {
    /// Immutable lifecycle write; previous definitions remain in the log.
    pub deleted: bool,
    pub id: EventId,
    pub actor_id: ActorId,
    pub timestamp: HybridTimestamp,
    pub budget_id: BudgetId,
    pub name: String,
    /// `None` means the budget covers every expense regardless of category.
    pub category_id: Option<String>,
    pub limit_minor: i64,
    pub period: BudgetPeriod,
}

impl BudgetUpsert {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        actor_id: impl Into<String>,
        physical_millis: i64,
        logical: u32,
        budget_id: BudgetId,
        name: impl Into<String>,
        category_id: Option<String>,
        limit_minor: i64,
        period: BudgetPeriod,
    ) -> Self {
        Self {
            deleted: false,
            id: EventId::new(id),
            actor_id: ActorId::new(actor_id),
            timestamp: HybridTimestamp::new(physical_millis, logical),
            budget_id,
            name: name.into(),
            category_id,
            limit_minor,
            period,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BudgetRecord {
    pub deleted: bool,
    pub name: String,
    pub category_id: Option<String>,
    pub limit_minor: i64,
    pub period: BudgetPeriod,
    last_writer: (HybridTimestamp, ActorId, EventId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BudgetBookState {
    pub budgets: BTreeMap<BudgetId, BudgetRecord>,
}

impl BudgetBookState {
    pub fn empty() -> Self {
        Self::default()
    }

    fn apply(&mut self, upsert: &BudgetUpsert) {
        let writer_key = (upsert.timestamp, upsert.actor_id.clone(), upsert.id.clone());
        let should_replace = match self.budgets.get(&upsert.budget_id) {
            Some(existing) => writer_key > existing.last_writer,
            None => true,
        };
        if should_replace {
            self.budgets.insert(
                upsert.budget_id.clone(),
                BudgetRecord {
                    deleted: upsert.deleted,
                    name: upsert.name.clone(),
                    category_id: upsert.category_id.clone(),
                    limit_minor: upsert.limit_minor,
                    period: upsert.period,
                    last_writer: writer_key,
                },
            );
        }
    }
}

/// Folds budget upserts into last-writer-wins state. Order of iteration does
/// not affect the result (identical reasoning to `categories::fold_categories`).
pub fn fold_budgets(upserts: impl IntoIterator<Item = BudgetUpsert>) -> BudgetBookState {
    let mut state = BudgetBookState::empty();
    for upsert in upserts {
        state.apply(&upsert);
    }
    state
}

/// Returns the millisecond a budget's current spending window started, given
/// `period` and the current wall-clock time `now_millis`.
pub fn period_start_millis(period: BudgetPeriod, now_millis: i64) -> i64 {
    let today = now_millis.div_euclid(MILLIS_PER_DAY);
    let start_day = match period {
        BudgetPeriod::Custom { days } => today - i64::from(days) + 1,
        BudgetPeriod::Weekly => {
            // 1970-01-01 (day 0) was a Thursday; Monday is weekday 0.
            let weekday = (today.rem_euclid(7) + 3).rem_euclid(7);
            today - weekday
        }
        BudgetPeriod::Monthly => {
            let (year, month, _) = civil_from_days(today);
            days_from_civil(year, month, 1)
        }
        BudgetPeriod::Yearly => {
            let (year, _, _) = civil_from_days(today);
            days_from_civil(year, 1, 1)
        }
    };
    start_day * MILLIS_PER_DAY
}

/// The result of decoding a durable budget log's bytes.
pub struct DecodedBudgetLog {
    pub upserts: Vec<BudgetUpsert>,
    pub trailing_garbage_bytes: usize,
}

impl From<DecodedFrameLog<BudgetUpsert>> for DecodedBudgetLog {
    fn from(decoded: DecodedFrameLog<BudgetUpsert>) -> Self {
        Self {
            upserts: decoded.items,
            trailing_garbage_bytes: decoded.trailing_garbage_bytes,
        }
    }
}

pub fn encode_budget_frame(upsert: &BudgetUpsert) -> Vec<u8> {
    encode_frame(&encode_upsert(upsert))
}

pub fn decode_budget_log(bytes: &[u8]) -> DecodedBudgetLog {
    decode_frame_log(bytes, decode_upsert).into()
}

const PERIOD_WEEKLY: u8 = 0;
const PERIOD_MONTHLY: u8 = 1;
const PERIOD_YEARLY: u8 = 2;
const PERIOD_CUSTOM: u8 = 3;

fn encode_upsert(upsert: &BudgetUpsert) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_string(&mut bytes, upsert.id.as_str());
    write_string(&mut bytes, upsert.actor_id.as_str());
    write_i64(&mut bytes, upsert.timestamp.physical_millis);
    write_u32(&mut bytes, upsert.timestamp.logical);
    write_string(&mut bytes, upsert.budget_id.as_str());
    write_string(&mut bytes, &upsert.name);
    match &upsert.category_id {
        Some(category_id) => {
            write_bool(&mut bytes, true);
            write_string(&mut bytes, category_id);
        }
        None => write_bool(&mut bytes, false),
    }
    write_i64(&mut bytes, upsert.limit_minor);
    match upsert.period {
        BudgetPeriod::Weekly => bytes.push(PERIOD_WEEKLY),
        BudgetPeriod::Monthly => bytes.push(PERIOD_MONTHLY),
        BudgetPeriod::Yearly => bytes.push(PERIOD_YEARLY),
        BudgetPeriod::Custom { days } => {
            bytes.push(PERIOD_CUSTOM);
            write_u32(&mut bytes, days);
        }
    }
    // Ordinary v1 frame bytes stay identical. Only tombstones append a
    // boolean extension; SQLite v2 rejects old readers before decoding.
    if upsert.deleted {
        write_bool(&mut bytes, true);
    }
    bytes
}

fn decode_upsert(payload: &[u8]) -> Option<BudgetUpsert> {
    let mut reader = Reader::new(payload);
    let id = reader.read_string()?;
    let actor_id = reader.read_string()?;
    let physical_millis = reader.read_i64()?;
    let logical = reader.read_u32()?;
    let budget_id = BudgetId::new(reader.read_string()?);
    let name = reader.read_string()?;
    let category_id = if reader.read_bool()? {
        Some(reader.read_string()?)
    } else {
        None
    };
    let limit_minor = reader.read_i64()?;
    let period = match reader.read_u8()? {
        PERIOD_WEEKLY => BudgetPeriod::Weekly,
        PERIOD_MONTHLY => BudgetPeriod::Monthly,
        PERIOD_YEARLY => BudgetPeriod::Yearly,
        PERIOD_CUSTOM => BudgetPeriod::Custom {
            days: reader.read_u32()?,
        },
        _ => return None,
    };
    let deleted = match reader.remaining() {
        0 => false,
        1 => reader.read_bool()?,
        _ => return None,
    };
    let mut upsert = BudgetUpsert::new(
        id,
        actor_id,
        physical_millis,
        logical,
        budget_id,
        name,
        category_id,
        limit_minor,
        period,
    );
    upsert.deleted = deleted;
    Some(upsert)
}

#[cfg(test)]
mod tests {
    use super::*;

    // This fixture intentionally mirrors every independently varied write field.
    #[allow(clippy::too_many_arguments)]
    fn upsert(
        id: &str,
        actor: &str,
        millis: i64,
        logical: u32,
        budget: &str,
        name: &str,
        category_id: Option<&str>,
        limit_minor: i64,
        period: BudgetPeriod,
    ) -> BudgetUpsert {
        BudgetUpsert::new(
            id,
            actor,
            millis,
            logical,
            BudgetId::new(budget),
            name,
            category_id.map(str::to_owned),
            limit_minor,
            period,
        )
    }

    #[test]
    fn a_later_write_wins_regardless_of_arrival_order() {
        let early = upsert(
            "e1",
            "alice",
            100,
            0,
            "food",
            "Food",
            Some("food"),
            10_000,
            BudgetPeriod::Monthly,
        );
        let late = upsert(
            "e2",
            "alice",
            200,
            0,
            "food",
            "Food (tighter)",
            Some("food"),
            8_000,
            BudgetPeriod::Weekly,
        );

        let forward = fold_budgets([early.clone(), late.clone()]);
        let backward = fold_budgets([late, early]);
        assert_eq!(forward, backward);

        let record = &forward.budgets[&BudgetId::new("food")];
        assert_eq!(record.name, "Food (tighter)");
        assert_eq!(record.limit_minor, 8_000);
        assert_eq!(record.period, BudgetPeriod::Weekly);
    }

    #[test]
    fn an_upsert_round_trips_through_a_frame() {
        for period in [
            BudgetPeriod::Weekly,
            BudgetPeriod::Monthly,
            BudgetPeriod::Yearly,
            BudgetPeriod::Custom { days: 45 },
        ] {
            let write = upsert(
                "e1",
                "alice",
                100,
                3,
                "food",
                "Food",
                Some("food"),
                10_000,
                period,
            );
            let frame = encode_budget_frame(&write);
            let decoded = decode_budget_log(&frame);
            assert_eq!(decoded.trailing_garbage_bytes, 0);
            assert_eq!(decoded.upserts, vec![write]);
        }
    }

    #[test]
    fn an_overall_budget_with_no_category_round_trips() {
        let write = upsert(
            "e1",
            "alice",
            100,
            0,
            "overall",
            "Everything",
            None,
            50_000,
            BudgetPeriod::Monthly,
        );
        let frame = encode_budget_frame(&write);
        let decoded = decode_budget_log(&frame);
        assert_eq!(decoded.upserts, vec![write]);
    }

    // 2026-03-18 is a Wednesday; its week starts Monday 2026-03-16, its month
    // starts 2026-03-01, its year starts 2026-01-01. Millis computed relative
    // to the Unix epoch independently of the calendar routines under test.
    fn millis_for(year: i64, month: u32, day: u32) -> i64 {
        days_from_civil(year, month, day) * 86_400_000
    }

    #[test]
    fn weekly_period_starts_on_monday() {
        let now = millis_for(2026, 3, 18) + 12 * 3_600_000;
        assert_eq!(
            period_start_millis(BudgetPeriod::Weekly, now),
            millis_for(2026, 3, 16)
        );
    }

    #[test]
    fn monthly_period_starts_on_the_first() {
        let now = millis_for(2026, 3, 18);
        assert_eq!(
            period_start_millis(BudgetPeriod::Monthly, now),
            millis_for(2026, 3, 1)
        );
    }

    #[test]
    fn yearly_period_starts_on_january_first() {
        let now = millis_for(2026, 3, 18);
        assert_eq!(
            period_start_millis(BudgetPeriod::Yearly, now),
            millis_for(2026, 1, 1)
        );
    }

    #[test]
    fn custom_period_is_a_rolling_window_including_today() {
        let now = millis_for(2026, 3, 18);
        // A 7-day window ending today includes today, so it starts 6 days
        // earlier.
        assert_eq!(
            period_start_millis(BudgetPeriod::Custom { days: 7 }, now),
            millis_for(2026, 3, 12)
        );
    }
}
