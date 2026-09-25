use crate::{ActorId, Currency, EventId, FxRate, HybridTimestamp, Money, OrderKey};

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct AccountId(String);

impl AccountId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct TransactionId(String);

impl TransactionId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransactionKind {
    Expense,
    Income,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EventKind {
    AccountOpened {
        account_id: AccountId,
        name: String,
        currency: Currency,
    },
    TransactionRecorded {
        transaction_id: TransactionId,
        account_id: AccountId,
        kind: TransactionKind,
        original: Money,
        reporting_fx: FxRate,
        title: String,
        category_id: Option<String>,
    },
    AmountAdjusted {
        transaction_id: TransactionId,
        original: Money,
        reporting_fx: FxRate,
    },
    CategoryAssigned {
        transaction_id: TransactionId,
        category_id: Option<String>,
    },
    TransactionVoided {
        transaction_id: TransactionId,
    },
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Event {
    pub id: EventId,
    pub actor_id: ActorId,
    pub timestamp: HybridTimestamp,
    pub kind: EventKind,
}

impl Event {
    pub fn new(
        id: impl Into<String>,
        actor_id: impl Into<String>,
        physical_millis: i64,
        logical: u32,
        kind: EventKind,
    ) -> Self {
        Self {
            id: EventId::new(id),
            actor_id: ActorId::new(actor_id),
            timestamp: HybridTimestamp::new(physical_millis, logical),
            kind,
        }
    }

    pub fn order_key(&self) -> OrderKey {
        OrderKey {
            timestamp: self.timestamp,
            actor_id: self.actor_id.clone(),
            event_id: self.id.clone(),
        }
    }
}
