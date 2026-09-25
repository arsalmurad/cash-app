use std::cmp::Ordering;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ActorId(String);

impl ActorId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct EventId(String);

impl EventId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct HybridTimestamp {
    pub physical_millis: i64,
    pub logical: u32,
}

impl HybridTimestamp {
    pub const fn new(physical_millis: i64, logical: u32) -> Self {
        Self {
            physical_millis,
            logical,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OrderKey {
    pub timestamp: HybridTimestamp,
    pub actor_id: ActorId,
    pub event_id: EventId,
}

impl Ord for OrderKey {
    fn cmp(&self, other: &Self) -> Ordering {
        self.timestamp
            .cmp(&other.timestamp)
            .then_with(|| self.actor_id.cmp(&other.actor_id))
            .then_with(|| self.event_id.cmp(&other.event_id))
    }
}

impl PartialOrd for OrderKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
