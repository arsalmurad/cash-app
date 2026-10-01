use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::ledger::validate_deduplicate_and_sort;
use crate::{ActorId, Currency, Event, EventId, FoldError, HybridTimestamp, LedgerState, OrderKey};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Snapshot {
    pub state: LedgerState,
    /// Highest included HLC for every actor represented in the snapshot.
    pub causal_frontier: BTreeMap<ActorId, HybridTimestamp>,
    /// Retained until peers acknowledge the frontier; used for idempotency and
    /// to distinguish a replay from a genuinely late event.
    pub included_event_ids: BTreeSet<EventId>,
    /// Exact source events are retained until compaction is safe. An ID alone
    /// cannot distinguish an idempotent replay from conflicting immutable data.
    included_events: BTreeMap<EventId, Event>,
    pub maximum_order: Option<OrderKey>,
}

impl Snapshot {
    pub fn from_events(
        reporting_currency: Currency,
        events: impl IntoIterator<Item = Event>,
    ) -> Result<Self, SnapshotError> {
        let events = validate_deduplicate_and_sort(events)?;
        let mut state = LedgerState::empty(reporting_currency);
        let mut causal_frontier: BTreeMap<ActorId, HybridTimestamp> = BTreeMap::new();
        let mut included_event_ids = BTreeSet::new();
        let mut included_events = BTreeMap::new();
        let mut maximum_order = None;

        for event in &events {
            state.apply(event)?;
            causal_frontier
                .entry(event.actor_id.clone())
                .and_modify(|timestamp| *timestamp = (*timestamp).max(event.timestamp))
                .or_insert(event.timestamp);
            included_event_ids.insert(event.id.clone());
            included_events.insert(event.id.clone(), event.clone());
            maximum_order = Some(event.order_key());
        }

        Ok(Self {
            state,
            causal_frontier,
            included_event_ids,
            included_events,
            maximum_order,
        })
    }

    pub fn fold_forward(
        mut self,
        events: impl IntoIterator<Item = Event>,
    ) -> Result<Self, SnapshotError> {
        let events = validate_deduplicate_and_sort(events)?;
        for event in &events {
            if let Some(included) = self.included_events.get(&event.id) {
                if included != event {
                    return Err(FoldError::ConflictingDuplicateEvent(event.id.clone()).into());
                }
                continue;
            }
            if self
                .maximum_order
                .as_ref()
                .is_some_and(|maximum| event.order_key() <= *maximum)
            {
                return Err(SnapshotError::LateEventInvalidatesSnapshot(
                    event.id.clone(),
                ));
            }

            self.state.apply(event)?;
            self.causal_frontier
                .entry(event.actor_id.clone())
                .and_modify(|timestamp| *timestamp = (*timestamp).max(event.timestamp))
                .or_insert(event.timestamp);
            self.included_event_ids.insert(event.id.clone());
            self.included_events.insert(event.id.clone(), event.clone());
            self.maximum_order = Some(event.order_key());
        }
        Ok(self)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SnapshotError {
    Fold(FoldError),
    LateEventInvalidatesSnapshot(EventId),
}

impl From<FoldError> for SnapshotError {
    fn from(error: FoldError) -> Self {
        Self::Fold(error)
    }
}

impl fmt::Display for SnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for SnapshotError {}
