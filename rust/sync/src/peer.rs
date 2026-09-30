use std::collections::{BTreeSet, VecDeque};
use std::fmt;

use cash_core::{
    Currency, EditField, Event, EventId, EventKind, HybridTimestamp, SharedEvent, SharedState,
    decode_shared_event, encode_shared_event, fold_shared,
};
use cash_crypto::{Member, Received};

use crate::ids::random_id;
use crate::relay::{AppendError, MailboxItem, Relay};

/// How many times a write retries after losing the compare-and-swap before
/// giving up; each retry first catches up on what won.
const MAX_ATTEMPTS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncError(pub String);

impl fmt::Display for SyncError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for SyncError {}

impl From<cash_crypto::Error> for SyncError {
    fn from(error: cash_crypto::Error) -> Self {
        Self(error.0)
    }
}

/// One device's participation in one household group.
///
/// Writes go to a local outbox first, so they work offline and show up in
/// [`Peer::state`] immediately; [`Peer::sync`] is what talks to the relay.
/// An event's `base` is computed at write time from this device's own view,
/// which is exactly what lets the shared fold tell a concurrent edit from a
/// sequential one after the fact.
pub struct Peer {
    member: Member,
    member_id: String,
    reporting_currency: Currency,
    group: Option<String>,
    /// Sequence number of the last relay entry this peer has processed.
    cursor: u64,
    last_timestamp: HybridTimestamp,
    events: Vec<SharedEvent>,
    known: BTreeSet<EventId>,
    outbox: VecDeque<SharedEvent>,
    removed: bool,
}

impl Peer {
    /// `member_id` is the identity inside the group's MLS credential, which
    /// every member learns. Use an opaque identifier, not a real name; show
    /// names from inside the encrypted stream.
    pub fn new(member_id: &str, reporting_currency: Currency) -> Result<Self, SyncError> {
        Ok(Self {
            member: Member::new(member_id)?,
            member_id: member_id.to_owned(),
            reporting_currency,
            group: None,
            cursor: 0,
            last_timestamp: HybridTimestamp::new(0, 0),
            events: Vec::new(),
            known: BTreeSet::new(),
            outbox: VecDeque::new(),
            removed: false,
        })
    }

    pub fn member_id(&self) -> &str {
        &self.member_id
    }

    /// A fresh single-use key package for someone to invite this peer with.
    pub fn key_package(&self) -> Result<Vec<u8>, SyncError> {
        Ok(self.member.key_package()?)
    }

    pub fn is_member(&self) -> bool {
        self.group.is_some() && !self.removed && self.member.is_active()
    }

    /// Public signing keys of the current members, by member ID, for
    /// comparing safety numbers out of band.
    pub fn member_keys(&self) -> Result<Vec<(String, Vec<u8>)>, SyncError> {
        Ok(self.member.member_keys()?)
    }

    pub fn public_key(&self) -> Vec<u8> {
        self.member.public_key()
    }

    /// Starts a new household group with this peer as its only member.
    pub fn found(&mut self, _relay: &mut impl Relay) -> Result<String, SyncError> {
        self.member.create_group()?;
        let group = random_id();
        self.group = Some(group.clone());
        self.cursor = 0;
        Ok(group)
    }

    fn group(&self) -> Result<String, SyncError> {
        self.group
            .clone()
            .ok_or_else(|| SyncError("this peer has not joined a group".to_owned()))
    }

    /// Adds the holder of `key_package` and leaves their welcome in a
    /// mailbox. Returns the mailbox ID to hand them out of band.
    pub fn invite(
        &mut self,
        relay: &mut impl Relay,
        key_package: &[u8],
    ) -> Result<String, SyncError> {
        let group = self.group()?;
        for _ in 0..MAX_ATTEMPTS {
            self.pull(relay)?;
            let invite = self.member.add(key_package)?;
            match relay.append(&group, self.cursor, invite.commit) {
                Ok(sequence) => {
                    self.member.confirm_commit()?;
                    self.cursor = sequence;
                    let mailbox = random_id();
                    relay.put_mailbox(
                        &mailbox,
                        MailboxItem {
                            group,
                            joined_after: sequence,
                            welcome: invite.welcome,
                        },
                    );
                    return Ok(mailbox);
                }
                Err(AppendError::Conflict { .. }) => self.member.discard_commit()?,
            }
        }
        Err(SyncError(
            "could not commit: the relay stayed busy".to_owned(),
        ))
    }

    /// Joins a group using the welcome an existing member left in `mailbox`.
    pub fn accept(
        &mut self,
        relay: &mut impl Relay,
        group: &str,
        mailbox: &str,
    ) -> Result<(), SyncError> {
        let item = relay
            .take_mailbox(mailbox)
            .ok_or_else(|| SyncError("no welcome waiting in that mailbox".to_owned()))?;
        if item.group != group {
            return Err(SyncError(
                "that welcome is for a different group".to_owned(),
            ));
        }
        self.member.join(&item.welcome)?;
        self.group = Some(group.to_owned());
        self.cursor = item.joined_after;
        Ok(())
    }

    /// Removes the member with `member_id`, rotating the group's keys so
    /// they cannot read anything written from now on.
    pub fn remove(&mut self, relay: &mut impl Relay, member_id: &str) -> Result<(), SyncError> {
        let group = self.group()?;
        for _ in 0..MAX_ATTEMPTS {
            self.pull(relay)?;
            let commit = self.member.remove(member_id)?;
            match relay.append(&group, self.cursor, commit) {
                Ok(sequence) => {
                    self.member.confirm_commit()?;
                    self.cursor = sequence;
                    return Ok(());
                }
                Err(AppendError::Conflict { .. }) => self.member.discard_commit()?,
            }
        }
        Err(SyncError(
            "could not commit: the relay stayed busy".to_owned(),
        ))
    }

    /// Records a new shared event locally (offline-safe) and queues it for
    /// the next [`Peer::sync`]. `wall_clock_millis` feeds the hybrid clock,
    /// which never moves backwards and always exceeds every timestamp this
    /// peer has seen.
    pub fn write(
        &mut self,
        wall_clock_millis: i64,
        kind: EventKind,
    ) -> Result<SharedEvent, SyncError> {
        if !self.is_member() {
            return Err(SyncError("this peer is not in the group".to_owned()));
        }
        let timestamp = if wall_clock_millis > self.last_timestamp.physical_millis {
            HybridTimestamp::new(wall_clock_millis, 0)
        } else {
            HybridTimestamp::new(
                self.last_timestamp.physical_millis,
                self.last_timestamp.logical.saturating_add(1),
            )
        };
        self.last_timestamp = timestamp;
        let id = format!(
            "{}-{:016x}-{:08x}",
            self.member_id, timestamp.physical_millis, timestamp.logical
        );
        let base = self.base_for(&kind);
        let event = SharedEvent {
            event: Event::new(
                id,
                self.member_id.clone(),
                timestamp.physical_millis,
                timestamp.logical,
                kind,
            ),
            base,
        };
        self.known.insert(event.event.id.clone());
        self.events.push(event.clone());
        self.outbox.push_back(event.clone());
        Ok(event)
    }

    fn base_for(&self, kind: &EventKind) -> Option<EventId> {
        let (transaction, field) = match kind {
            EventKind::AmountAdjusted { transaction_id, .. }
            | EventKind::TransactionVoided { transaction_id } => {
                (transaction_id, EditField::Amount)
            }
            EventKind::CategoryAssigned { transaction_id, .. } => {
                (transaction_id, EditField::Category)
            }
            _ => return None,
        };
        self.state().edit_head(transaction, field).cloned()
    }

    /// This peer's view of the shared ledger: everything it has written or
    /// received, folded.
    pub fn state(&self) -> SharedState {
        fold_shared(self.reporting_currency.clone(), self.events.iter().cloned())
    }

    /// Sends everything queued and pulls everything new, in the relay's
    /// order. A no-op for a peer that has been removed.
    pub fn sync(&mut self, relay: &mut impl Relay) -> Result<(), SyncError> {
        if !self.is_member() {
            return Ok(());
        }
        let group = self.group()?;
        let mut attempts = 0;
        loop {
            self.pull(relay)?;
            if !self.is_member() {
                return Ok(());
            }
            let Some(next) = self.outbox.front() else {
                return Ok(());
            };
            let ciphertext = self.member.encrypt(&encode_shared_event(next))?;
            match relay.append(&group, self.cursor, ciphertext) {
                Ok(sequence) => {
                    self.cursor = sequence;
                    self.outbox.pop_front();
                }
                Err(AppendError::Conflict { .. }) => {
                    attempts += 1;
                    if attempts >= MAX_ATTEMPTS {
                        return Err(SyncError("the relay stayed busy".to_owned()));
                    }
                }
            }
        }
    }

    fn pull(&mut self, relay: &impl Relay) -> Result<(), SyncError> {
        let group = self.group()?;
        for (sequence, frame) in relay.read_after(&group, self.cursor) {
            match self.member.receive(&frame)? {
                Received::Application(bytes) => {
                    // A frame that decrypts but is not a shared event came
                    // from a buggy or hostile member; skip it rather than
                    // stall everyone behind it.
                    if let Some(shared) = decode_shared_event(&bytes) {
                        self.observe(shared);
                    }
                }
                Received::Commit { .. } | Received::Own => {}
                Received::Removed => {
                    self.removed = true;
                    self.cursor = sequence;
                    return Ok(());
                }
            }
            self.cursor = sequence;
        }
        Ok(())
    }

    fn observe(&mut self, shared: SharedEvent) {
        self.last_timestamp = self.last_timestamp.max(shared.event.timestamp);
        if self.known.insert(shared.event.id.clone()) {
            self.events.push(shared);
        }
    }

    /// Tries to decrypt one relay frame without recording anything; for
    /// tests that check a removed member really is locked out.
    pub fn try_decrypt(&mut self, frame: &[u8]) -> Result<(), SyncError> {
        self.member.receive(frame).map(|_| ()).map_err(Into::into)
    }
}
