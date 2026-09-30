//! The shared (household) ledger fold.
//!
//! A personal ledger is written by one trusted device, so `fold` treats any
//! invalid event as a hard error. A shared ledger is written by several
//! people's devices whose events can race each other, so its fold must be
//! total: every peer holding the same set of events reaches byte-identical
//! state no matter the arrival order, and an event that cannot apply (or
//! that overwrites a concurrent edit) stays visible in the state rather than
//! vanishing or aborting the fold.
//!
//! Concurrency is detected without vector clocks. Each edit records `base`,
//! the last event touching the same field of the same transaction that its
//! author had applied. Replaying the total order `(HLC, actor, event ID)`,
//! an edit whose `base` is not the field's current head was written without
//! seeing that head, so both events are reported as a [`Conflict`] and the
//! later one in the total order wins.

use std::collections::BTreeMap;
use std::collections::btree_map::Entry;

use crate::bytes_io::{Reader, write_bool, write_string, write_u64};
use crate::codec::{decode_event, encode_event};
use crate::{
    AccountState, Currency, Event, EventId, EventKind, FoldError, LedgerState, TransactionId,
};

/// An event plus what its author had seen when writing it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SharedEvent {
    pub event: Event,
    /// For an edit of an existing transaction: the last event touching the
    /// same field of that transaction which the author had applied. `None`
    /// for events that create something, or an author that saw nothing.
    pub base: Option<EventId>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RejectReason {
    /// The event is well-formed but could not apply to the state built from
    /// the events ordered before it (for example, an edit after a void).
    Fold(FoldError),
    /// Two different events carried the same ID; neither is trusted.
    ConflictingDuplicate,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Rejected {
    pub event_id: EventId,
    pub reason: RejectReason,
}

/// Two edits of one field that were written without seeing each other.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Conflict {
    pub transaction_id: TransactionId,
    /// The earlier edit, whose value the winner replaced.
    pub overwritten: EventId,
    pub winner: EventId,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SharedState {
    pub ledger: LedgerState,
    pub conflicts: Vec<Conflict>,
    pub rejected: Vec<Rejected>,
    /// The last applied event per (transaction, field); derived, so it is
    /// not part of `canonical_bytes`.
    heads: BTreeMap<(TransactionId, EditField), EventId>,
}

impl SharedState {
    /// The event a new edit of `field` on `transaction` should name as its
    /// `base`: the last one this state applied to that field.
    pub fn edit_head(&self, transaction: &TransactionId, field: EditField) -> Option<&EventId> {
        self.heads.get(&(transaction.clone(), field))
    }

    /// Canonical serialization: equal event sets give identical bytes.
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut bytes = self.ledger.canonical_bytes();
        write_u64(&mut bytes, self.conflicts.len() as u64);
        for conflict in &self.conflicts {
            write_string(&mut bytes, conflict.transaction_id.as_str());
            write_string(&mut bytes, conflict.overwritten.as_str());
            write_string(&mut bytes, conflict.winner.as_str());
        }
        write_u64(&mut bytes, self.rejected.len() as u64);
        for rejected in &self.rejected {
            write_string(&mut bytes, rejected.event_id.as_str());
            match &rejected.reason {
                RejectReason::ConflictingDuplicate => write_string(&mut bytes, "duplicate"),
                RejectReason::Fold(error) => write_string(&mut bytes, &format!("{error:?}")),
            }
        }
        bytes
    }
}

/// The independently editable parts of a transaction; concurrent edits are
/// only a conflict when they touch the same one.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum EditField {
    Amount,
    Category,
}

/// Folds shared events into state. Never fails: see the module docs.
pub fn fold_shared(
    reporting_currency: Currency,
    events: impl IntoIterator<Item = SharedEvent>,
) -> SharedState {
    let mut rejected = Vec::new();
    let events = deduplicate(events, &mut rejected);

    let mut ledger = LedgerState::empty(reporting_currency);
    let mut conflicts = Vec::new();
    let mut heads: BTreeMap<(TransactionId, EditField), EventId> = BTreeMap::new();

    for shared in &events {
        let event = &shared.event;
        if let Err(error) = apply_atomically(&mut ledger, event) {
            rejected.push(Rejected {
                event_id: event.id.clone(),
                reason: RejectReason::Fold(error),
            });
            continue;
        }
        match &event.kind {
            EventKind::TransactionRecorded { transaction_id, .. } => {
                for field in [EditField::Amount, EditField::Category] {
                    heads.insert((transaction_id.clone(), field), event.id.clone());
                }
            }
            EventKind::AmountAdjusted { transaction_id, .. } => {
                note_edit(
                    &mut heads,
                    &mut conflicts,
                    transaction_id,
                    EditField::Amount,
                    shared,
                );
            }
            EventKind::CategoryAssigned { transaction_id, .. } => {
                note_edit(
                    &mut heads,
                    &mut conflicts,
                    transaction_id,
                    EditField::Category,
                    shared,
                );
            }
            _ => {}
        }
    }
    rejected.sort_by(|left, right| left.event_id.cmp(&right.event_id));
    SharedState {
        ledger,
        conflicts,
        rejected,
        heads,
    }
}

fn note_edit(
    heads: &mut BTreeMap<(TransactionId, EditField), EventId>,
    conflicts: &mut Vec<Conflict>,
    transaction_id: &TransactionId,
    field: EditField,
    edit: &SharedEvent,
) {
    let head = heads.insert((transaction_id.clone(), field), edit.event.id.clone());
    if let Some(head) = head
        && edit.base.as_ref() != Some(&head)
    {
        conflicts.push(Conflict {
            transaction_id: transaction_id.clone(),
            overwritten: head,
            winner: edit.event.id.clone(),
        });
    }
}

/// Identical copies of an event collapse to one; differently-valued events
/// sharing an ID are all dropped and reported, since no peer can tell which
/// is genuine. Returns the survivors in total order.
fn deduplicate(
    events: impl IntoIterator<Item = SharedEvent>,
    rejected: &mut Vec<Rejected>,
) -> Vec<SharedEvent> {
    let mut by_id: BTreeMap<EventId, Option<SharedEvent>> = BTreeMap::new();
    for shared in events {
        match by_id.entry(shared.event.id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(Some(shared));
            }
            Entry::Occupied(mut entry) => {
                if entry
                    .get()
                    .as_ref()
                    .is_some_and(|existing| existing != &shared)
                {
                    entry.insert(None);
                }
            }
        }
    }
    let mut survivors = Vec::new();
    for (id, shared) in by_id {
        match shared {
            Some(shared) => survivors.push(shared),
            None => rejected.push(Rejected {
                event_id: id,
                reason: RejectReason::ConflictingDuplicate,
            }),
        }
    }
    survivors.sort_by_key(|shared| shared.event.order_key());
    survivors
}

/// Applies `event`, leaving `ledger` exactly as it was if the event fails.
/// `apply` only inserts new records after its last fallible step and edits
/// records only after theirs, so restoring the accounts and the running
/// total is enough to undo a partial update.
fn apply_atomically(ledger: &mut LedgerState, event: &Event) -> Result<(), FoldError> {
    let accounts: BTreeMap<_, AccountState> = ledger.accounts.clone();
    let total = ledger.reporting_balance_minor;
    let result = ledger.apply(event);
    if result.is_err() {
        ledger.accounts = accounts;
        ledger.reporting_balance_minor = total;
    }
    result
}

/// Encodes a shared event for transport inside an encrypted group message.
/// The same event always encodes to the same bytes.
pub fn encode_shared_event(shared: &SharedEvent) -> Vec<u8> {
    let mut bytes = Vec::new();
    match &shared.base {
        Some(base) => {
            write_bool(&mut bytes, true);
            write_string(&mut bytes, base.as_str());
        }
        None => write_bool(&mut bytes, false),
    }
    bytes.extend_from_slice(&encode_event(&shared.event));
    bytes
}

/// Decodes [`encode_shared_event`]'s output; `None` for anything truncated,
/// malformed, or followed by extra bytes.
pub fn decode_shared_event(bytes: &[u8]) -> Option<SharedEvent> {
    let mut reader = Reader::new(bytes);
    let base = if reader.read_bool()? {
        Some(EventId::new(reader.read_string()?))
    } else {
        None
    };
    let rest = reader.read_bytes(reader.remaining())?;
    Some(SharedEvent {
        event: decode_event(rest)?,
        base,
    })
}
