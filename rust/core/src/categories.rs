//! Categories are soft state (build brief §2.5): unlike the financial
//! ledger, where a conflict must stay visible in history rather than
//! silently resolving, a category's name and icon are fine to settle with
//! last-writer-wins. This is deliberately a separate mechanism from
//! `event`/`ledger` — a different `EventKind` variant would blur the two
//! guarantees the brief says never to merge.
//!
//! Folding is commutative and idempotent by construction: applying the same
//! set of upserts in any order, any number of times, converges to the same
//! state, because each key only ever keeps the highest `(timestamp,
//! actor_id)` writer it has seen. There is nothing to reject, so unlike
//! `ledger::fold` this never returns an error.

use std::collections::BTreeMap;

use crate::bytes_io::{Reader, write_i64, write_string, write_u32};
use crate::frame::{DecodedFrameLog, decode_frame_log, encode_frame};
use crate::{ActorId, EventId, HybridTimestamp};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct CategoryId(String);

impl CategoryId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// One "set this category's name and icon" write. There is no separate
/// create/update distinction: every write is an upsert, and the highest
/// `(timestamp, actor_id)` writer for a given `category_id` wins.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CategoryUpsert {
    pub id: EventId,
    pub actor_id: ActorId,
    pub timestamp: HybridTimestamp,
    pub category_id: CategoryId,
    pub name: String,
    pub icon_key: String,
}

impl CategoryUpsert {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        actor_id: impl Into<String>,
        physical_millis: i64,
        logical: u32,
        category_id: CategoryId,
        name: impl Into<String>,
        icon_key: impl Into<String>,
    ) -> Self {
        Self {
            id: EventId::new(id),
            actor_id: ActorId::new(actor_id),
            timestamp: HybridTimestamp::new(physical_millis, logical),
            category_id,
            name: name.into(),
            icon_key: icon_key.into(),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CategoryRecord {
    pub name: String,
    pub icon_key: String,
    last_writer: (HybridTimestamp, ActorId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CategoryBookState {
    pub categories: BTreeMap<CategoryId, CategoryRecord>,
}

impl CategoryBookState {
    pub fn empty() -> Self {
        Self::default()
    }

    fn apply(&mut self, upsert: &CategoryUpsert) {
        let writer_key = (upsert.timestamp, upsert.actor_id.clone());
        let should_replace = match self.categories.get(&upsert.category_id) {
            Some(existing) => writer_key > existing.last_writer,
            None => true,
        };
        if should_replace {
            self.categories.insert(
                upsert.category_id.clone(),
                CategoryRecord {
                    name: upsert.name.clone(),
                    icon_key: upsert.icon_key.clone(),
                    last_writer: writer_key,
                },
            );
        }
    }
}

/// Folds category upserts into last-writer-wins state. Order of iteration
/// does not affect the result (see module docs), so callers need not
/// deduplicate or sort first.
pub fn fold_categories(upserts: impl IntoIterator<Item = CategoryUpsert>) -> CategoryBookState {
    let mut state = CategoryBookState::empty();
    for upsert in upserts {
        state.apply(&upsert);
    }
    state
}

/// The result of decoding a durable category log's bytes.
pub struct DecodedCategoryLog {
    pub upserts: Vec<CategoryUpsert>,
    /// Bytes at the tail of the log that were not a complete, checksum-valid
    /// frame (same recovery story as the financial event log's
    /// `trailing_garbage_bytes`).
    pub trailing_garbage_bytes: usize,
}

impl From<DecodedFrameLog<CategoryUpsert>> for DecodedCategoryLog {
    fn from(decoded: DecodedFrameLog<CategoryUpsert>) -> Self {
        Self {
            upserts: decoded.items,
            trailing_garbage_bytes: decoded.trailing_garbage_bytes,
        }
    }
}

/// Encodes one upsert as a self-contained, checksummed frame ready to append
/// to a durable log. The same upsert always encodes to the same bytes.
pub fn encode_category_frame(upsert: &CategoryUpsert) -> Vec<u8> {
    encode_frame(&encode_upsert(upsert))
}

/// Decodes a byte buffer made of zero or more frames written by
/// [`encode_category_frame`], back-to-back, in append order.
pub fn decode_category_log(bytes: &[u8]) -> DecodedCategoryLog {
    decode_frame_log(bytes, decode_upsert).into()
}

fn encode_upsert(upsert: &CategoryUpsert) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_string(&mut bytes, upsert.id.as_str());
    write_string(&mut bytes, upsert.actor_id.as_str());
    write_i64(&mut bytes, upsert.timestamp.physical_millis);
    write_u32(&mut bytes, upsert.timestamp.logical);
    write_string(&mut bytes, upsert.category_id.as_str());
    write_string(&mut bytes, &upsert.name);
    write_string(&mut bytes, &upsert.icon_key);
    bytes
}

fn decode_upsert(payload: &[u8]) -> Option<CategoryUpsert> {
    let mut reader = Reader::new(payload);
    let id = reader.read_string()?;
    let actor_id = reader.read_string()?;
    let physical_millis = reader.read_i64()?;
    let logical = reader.read_u32()?;
    let category_id = CategoryId::new(reader.read_string()?);
    let name = reader.read_string()?;
    let icon_key = reader.read_string()?;
    if reader.remaining() != 0 {
        return None;
    }
    Some(CategoryUpsert::new(
        id,
        actor_id,
        physical_millis,
        logical,
        category_id,
        name,
        icon_key,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn upsert(
        id: &str,
        actor: &str,
        millis: i64,
        logical: u32,
        category: &str,
        name: &str,
        icon: &str,
    ) -> CategoryUpsert {
        CategoryUpsert::new(id, actor, millis, logical, CategoryId::new(category), name, icon)
    }

    #[test]
    fn a_later_write_wins_regardless_of_arrival_order() {
        let early = upsert("e1", "alice", 100, 0, "food", "Food", "restaurant");
        let late = upsert("e2", "alice", 200, 0, "food", "Groceries", "shopping_cart");

        let forward = fold_categories([early.clone(), late.clone()]);
        let backward = fold_categories([late, early]);

        assert_eq!(forward, backward);
        let record = &forward.categories[&CategoryId::new("food")];
        assert_eq!(record.name, "Groceries");
        assert_eq!(record.icon_key, "shopping_cart");
    }

    #[test]
    fn replaying_the_same_upsert_is_a_no_op() {
        let write = upsert("e1", "alice", 100, 0, "food", "Food", "restaurant");
        let once = fold_categories([write.clone()]);
        let twice = fold_categories([write.clone(), write]);
        assert_eq!(once, twice);
    }

    #[test]
    fn different_categories_do_not_interfere() {
        let state = fold_categories([
            upsert("e1", "alice", 100, 0, "food", "Food", "restaurant"),
            upsert("e2", "alice", 100, 0, "transport", "Transport", "directions_car"),
        ]);
        assert_eq!(state.categories.len(), 2);
        assert_eq!(state.categories[&CategoryId::new("food")].name, "Food");
        assert_eq!(
            state.categories[&CategoryId::new("transport")].name,
            "Transport"
        );
    }

    #[test]
    fn an_upsert_round_trips_through_a_frame() {
        let write = upsert("e1", "alice", 100, 3, "food", "Food", "restaurant");
        let frame = encode_category_frame(&write);
        let decoded = decode_category_log(&frame);
        assert_eq!(decoded.trailing_garbage_bytes, 0);
        assert_eq!(decoded.upserts, vec![write]);
    }

    #[test]
    fn a_truncated_frame_recovers_the_prefix() {
        let first = upsert("e1", "alice", 100, 0, "food", "Food", "restaurant");
        let second = upsert("e2", "alice", 200, 0, "transport", "Transport", "directions_car");
        let mut log = encode_category_frame(&first);
        let complete_len = log.len();
        let mut torn = encode_category_frame(&second);
        torn.truncate(torn.len() / 2);
        log.extend(&torn);

        let decoded = decode_category_log(&log);
        assert_eq!(decoded.upserts, vec![first]);
        assert_eq!(decoded.trailing_garbage_bytes, log.len() - complete_len);
    }
}
