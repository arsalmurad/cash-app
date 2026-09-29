//! Goals are soft state, exactly like categories and budgets (see
//! `categories.rs`/`budgets.rs` and build brief §2.5): a goal's name, kind,
//! target, and optional deadline are fine to settle with last-writer-wins.
//! Progress toward a goal is never stored here — it is always computed
//! fresh from the ledger (see `rust/api/src/api/goals.rs`), so there is
//! nothing in this module that could drift out of sync with the financial
//! source of truth.

use std::collections::BTreeMap;

use crate::bytes_io::{Reader, write_bool, write_i64, write_string, write_u32};
use crate::frame::{DecodedFrameLog, decode_frame_log, encode_frame};
use crate::{ActorId, EventId, HybridTimestamp};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct GoalId(String);

impl GoalId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Whether a goal accumulates toward a target (a savings goal, tracked by a
/// linked account's balance) or caps total spend against one (a spending
/// goal, tracked the same way a budget's category spend is).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum GoalKind {
    Save,
    Spend,
}

/// One "set this goal's name, kind, target, and deadline" write. Every write
/// is an upsert; the highest `(timestamp, actor_id)` writer for a given
/// `goal_id` wins, identically to `categories::CategoryUpsert` and
/// `budgets::BudgetUpsert`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GoalUpsert {
    pub id: EventId,
    pub actor_id: ActorId,
    pub timestamp: HybridTimestamp,
    pub goal_id: GoalId,
    pub name: String,
    pub kind: GoalKind,
    pub target_minor: i64,
    /// Save goals only: the account whose balance counts toward the target.
    pub linked_account_id: Option<String>,
    /// Spend goals only: `None` means every expense counts toward the cap.
    pub category_id: Option<String>,
    /// `None` means the goal has no deadline (an open-ended target).
    pub deadline_millis: Option<i64>,
}

impl GoalUpsert {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        actor_id: impl Into<String>,
        physical_millis: i64,
        logical: u32,
        goal_id: GoalId,
        name: impl Into<String>,
        kind: GoalKind,
        target_minor: i64,
        linked_account_id: Option<String>,
        category_id: Option<String>,
        deadline_millis: Option<i64>,
    ) -> Self {
        Self {
            id: EventId::new(id),
            actor_id: ActorId::new(actor_id),
            timestamp: HybridTimestamp::new(physical_millis, logical),
            goal_id,
            name: name.into(),
            kind,
            target_minor,
            linked_account_id,
            category_id,
            deadline_millis,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GoalRecord {
    pub name: String,
    pub kind: GoalKind,
    pub target_minor: i64,
    pub linked_account_id: Option<String>,
    pub category_id: Option<String>,
    pub deadline_millis: Option<i64>,
    last_writer: (HybridTimestamp, ActorId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct GoalBookState {
    pub goals: BTreeMap<GoalId, GoalRecord>,
}

impl GoalBookState {
    pub fn empty() -> Self {
        Self::default()
    }

    fn apply(&mut self, upsert: &GoalUpsert) {
        let writer_key = (upsert.timestamp, upsert.actor_id.clone());
        let should_replace = match self.goals.get(&upsert.goal_id) {
            Some(existing) => writer_key > existing.last_writer,
            None => true,
        };
        if should_replace {
            self.goals.insert(
                upsert.goal_id.clone(),
                GoalRecord {
                    name: upsert.name.clone(),
                    kind: upsert.kind,
                    target_minor: upsert.target_minor,
                    linked_account_id: upsert.linked_account_id.clone(),
                    category_id: upsert.category_id.clone(),
                    deadline_millis: upsert.deadline_millis,
                    last_writer: writer_key,
                },
            );
        }
    }
}

/// Folds goal upserts into last-writer-wins state. Order of iteration does
/// not affect the result (identical reasoning to `categories::fold_categories`
/// and `budgets::fold_budgets`).
pub fn fold_goals(upserts: impl IntoIterator<Item = GoalUpsert>) -> GoalBookState {
    let mut state = GoalBookState::empty();
    for upsert in upserts {
        state.apply(&upsert);
    }
    state
}

/// The result of decoding a durable goal log's bytes.
pub struct DecodedGoalLog {
    pub upserts: Vec<GoalUpsert>,
    pub trailing_garbage_bytes: usize,
}

impl From<DecodedFrameLog<GoalUpsert>> for DecodedGoalLog {
    fn from(decoded: DecodedFrameLog<GoalUpsert>) -> Self {
        Self {
            upserts: decoded.items,
            trailing_garbage_bytes: decoded.trailing_garbage_bytes,
        }
    }
}

pub fn encode_goal_frame(upsert: &GoalUpsert) -> Vec<u8> {
    encode_frame(&encode_upsert(upsert))
}

pub fn decode_goal_log(bytes: &[u8]) -> DecodedGoalLog {
    decode_frame_log(bytes, decode_upsert).into()
}

const KIND_SAVE: u8 = 0;
const KIND_SPEND: u8 = 1;

fn encode_upsert(upsert: &GoalUpsert) -> Vec<u8> {
    let mut bytes = Vec::new();
    write_string(&mut bytes, upsert.id.as_str());
    write_string(&mut bytes, upsert.actor_id.as_str());
    write_i64(&mut bytes, upsert.timestamp.physical_millis);
    write_u32(&mut bytes, upsert.timestamp.logical);
    write_string(&mut bytes, upsert.goal_id.as_str());
    write_string(&mut bytes, &upsert.name);
    bytes.push(match upsert.kind {
        GoalKind::Save => KIND_SAVE,
        GoalKind::Spend => KIND_SPEND,
    });
    write_i64(&mut bytes, upsert.target_minor);
    match &upsert.linked_account_id {
        Some(account_id) => {
            write_bool(&mut bytes, true);
            write_string(&mut bytes, account_id);
        }
        None => write_bool(&mut bytes, false),
    }
    match &upsert.category_id {
        Some(category_id) => {
            write_bool(&mut bytes, true);
            write_string(&mut bytes, category_id);
        }
        None => write_bool(&mut bytes, false),
    }
    match upsert.deadline_millis {
        Some(millis) => {
            write_bool(&mut bytes, true);
            write_i64(&mut bytes, millis);
        }
        None => write_bool(&mut bytes, false),
    }
    bytes
}

fn decode_upsert(payload: &[u8]) -> Option<GoalUpsert> {
    let mut reader = Reader::new(payload);
    let id = reader.read_string()?;
    let actor_id = reader.read_string()?;
    let physical_millis = reader.read_i64()?;
    let logical = reader.read_u32()?;
    let goal_id = GoalId::new(reader.read_string()?);
    let name = reader.read_string()?;
    let kind = match reader.read_u8()? {
        KIND_SAVE => GoalKind::Save,
        KIND_SPEND => GoalKind::Spend,
        _ => return None,
    };
    let target_minor = reader.read_i64()?;
    let linked_account_id = if reader.read_bool()? {
        Some(reader.read_string()?)
    } else {
        None
    };
    let category_id = if reader.read_bool()? {
        Some(reader.read_string()?)
    } else {
        None
    };
    let deadline_millis = if reader.read_bool()? {
        Some(reader.read_i64()?)
    } else {
        None
    };
    if reader.remaining() != 0 {
        return None;
    }
    Some(GoalUpsert::new(
        id,
        actor_id,
        physical_millis,
        logical,
        goal_id,
        name,
        kind,
        target_minor,
        linked_account_id,
        category_id,
        deadline_millis,
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
        goal: &str,
        name: &str,
        kind: GoalKind,
        target_minor: i64,
        linked_account_id: Option<&str>,
        category_id: Option<&str>,
        deadline_millis: Option<i64>,
    ) -> GoalUpsert {
        GoalUpsert::new(
            id,
            actor,
            millis,
            logical,
            GoalId::new(goal),
            name,
            kind,
            target_minor,
            linked_account_id.map(str::to_owned),
            category_id.map(str::to_owned),
            deadline_millis,
        )
    }

    #[test]
    fn a_later_write_wins_regardless_of_arrival_order() {
        let early = upsert(
            "e1",
            "alice",
            100,
            0,
            "vacation",
            "Vacation",
            GoalKind::Save,
            100_000,
            Some("savings"),
            None,
            None,
        );
        let late = upsert(
            "e2",
            "alice",
            200,
            0,
            "vacation",
            "Vacation (bigger)",
            GoalKind::Save,
            150_000,
            Some("savings"),
            None,
            Some(1_000),
        );

        let forward = fold_goals([early.clone(), late.clone()]);
        let backward = fold_goals([late, early]);
        assert_eq!(forward, backward);

        let record = &forward.goals[&GoalId::new("vacation")];
        assert_eq!(record.name, "Vacation (bigger)");
        assert_eq!(record.target_minor, 150_000);
        assert_eq!(record.deadline_millis, Some(1_000));
    }

    #[test]
    fn a_save_goal_round_trips_through_a_frame() {
        let write = upsert(
            "e1",
            "alice",
            100,
            3,
            "vacation",
            "Vacation",
            GoalKind::Save,
            100_000,
            Some("savings"),
            None,
            Some(1_800_000_000_000),
        );
        let frame = encode_goal_frame(&write);
        let decoded = decode_goal_log(&frame);
        assert_eq!(decoded.trailing_garbage_bytes, 0);
        assert_eq!(decoded.upserts, vec![write]);
    }

    #[test]
    fn a_spend_goal_with_no_category_or_deadline_round_trips() {
        let write = upsert(
            "e1",
            "alice",
            100,
            0,
            "no-eating-out",
            "No eating out",
            GoalKind::Spend,
            5_000,
            None,
            None,
            None,
        );
        let frame = encode_goal_frame(&write);
        let decoded = decode_goal_log(&frame);
        assert_eq!(decoded.upserts, vec![write]);
    }

    #[test]
    fn a_spend_goal_with_a_category_round_trips() {
        let write = upsert(
            "e1",
            "alice",
            100,
            0,
            "less-takeout",
            "Less takeout",
            GoalKind::Spend,
            10_000,
            None,
            Some("food"),
            Some(2_000),
        );
        let frame = encode_goal_frame(&write);
        let decoded = decode_goal_log(&frame);
        assert_eq!(decoded.upserts, vec![write]);
    }
}
