//! Deterministic, append-only ledger core.
//!
//! This crate deliberately has no UI, database, network, or wall-clock
//! dependencies. Callers provide immutable events; the core validates,
//! orders, deduplicates, and folds them into canonical state.

mod budgets;
mod bytes_io;
mod calendar;
mod categories;
mod clock;
mod codec;
mod event;
mod frame;
mod goals;
mod ledger;
mod money;
mod recurring;
mod snapshot;

pub use budgets::{
    BudgetBookState, BudgetId, BudgetPeriod, BudgetRecord, BudgetUpsert, DecodedBudgetLog,
    decode_budget_log, encode_budget_frame, fold_budgets, period_start_millis,
};
pub use categories::{
    CategoryBookState, CategoryId, CategoryRecord, CategoryUpsert, DecodedCategoryLog,
    decode_category_log, encode_category_frame, fold_categories,
};
pub use clock::{ActorId, EventId, HybridTimestamp, OrderKey};
pub use codec::{DecodedLog, decode_event_log, encode_event_frame};
pub use event::{AccountId, Event, EventKind, TransactionId, TransactionKind};
pub use goals::{
    DecodedGoalLog, GoalBookState, GoalId, GoalKind, GoalRecord, GoalUpsert, decode_goal_log,
    encode_goal_frame, fold_goals,
};
pub use ledger::{AccountState, FoldError, LedgerState, TransactionState, fold};
pub use money::{Currency, FxRate, Money, MoneyError, RoundingRule};
pub use recurring::{
    DecodedRecurringLog, RecurringBookState, RecurringFrequency, RecurringId, RecurringKind,
    RecurringRecord, RecurringUpsert, decode_recurring_log, encode_recurring_frame, fold_recurring,
    next_occurrence_millis,
};
pub use snapshot::{Snapshot, SnapshotError};
