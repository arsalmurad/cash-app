//! Deterministic, append-only ledger core.
//!
//! This crate deliberately has no UI, database, network, or wall-clock
//! dependencies. Callers provide immutable events; the core validates,
//! orders, deduplicates, and folds them into canonical state.

mod bytes_io;
mod clock;
mod codec;
mod event;
mod ledger;
mod money;
mod snapshot;

pub use clock::{ActorId, EventId, HybridTimestamp, OrderKey};
pub use codec::{DecodedLog, decode_event_log, encode_event_frame};
pub use event::{AccountId, Event, EventKind, TransactionId, TransactionKind};
pub use ledger::{AccountState, FoldError, LedgerState, TransactionState, fold};
pub use money::{Currency, FxRate, Money, MoneyError, RoundingRule};
pub use snapshot::{Snapshot, SnapshotError};
