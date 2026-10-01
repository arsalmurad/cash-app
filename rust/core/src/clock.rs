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

    /// Strictly advance after observed history, even with a stale wall clock.
    /// Carry an exhausted logical counter into the next physical millisecond;
    /// if both fields are exhausted, fail instead of reusing an order key.
    pub fn checked_next(self, wall_clock_millis: i64) -> Option<Self> {
        if wall_clock_millis > self.physical_millis {
            Some(Self::new(wall_clock_millis, 0))
        } else if let Some(logical) = self.logical.checked_add(1) {
            Some(Self::new(self.physical_millis, logical))
        } else {
            self.physical_millis
                .checked_add(1)
                .map(|physical| Self::new(physical, 0))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::HybridTimestamp;

    #[test]
    fn clock_advances_strictly_or_reports_exhaustion() {
        for (last, wall, expected) in [
            (
                HybridTimestamp::new(10, 9),
                11,
                Some(HybridTimestamp::new(11, 0)),
            ),
            (
                HybridTimestamp::new(10, 9),
                10,
                Some(HybridTimestamp::new(10, 10)),
            ),
            (
                HybridTimestamp::new(10, 9),
                -100,
                Some(HybridTimestamp::new(10, 10)),
            ),
            (
                HybridTimestamp::new(10, u32::MAX),
                1,
                Some(HybridTimestamp::new(11, 0)),
            ),
            (
                HybridTimestamp::new(i64::MAX, u32::MAX - 1),
                1,
                Some(HybridTimestamp::new(i64::MAX, u32::MAX)),
            ),
            (HybridTimestamp::new(i64::MAX, u32::MAX), i64::MAX, None),
        ] {
            let next = last.checked_next(wall);
            assert_eq!(next, expected);
            if let Some(next) = next {
                assert!(next > last);
            }
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
