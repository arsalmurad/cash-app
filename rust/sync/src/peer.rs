use std::collections::{BTreeSet, VecDeque};
use std::fmt;

use cash_core::{
    Currency, EditField, Event, EventId, EventKind, HybridTimestamp, SharedEvent, SharedState,
    decode_shared_event, encode_shared_event, fold_shared,
};
use cash_crypto::{Member, Received};

use crate::ids::random_id;
use crate::relay::{MailboxItem, Relay, RelayError};

const EXPORT_MAGIC: &[u8] = b"cash-app peer v1\0";

fn write_field(bytes: &mut Vec<u8>, field: &[u8]) {
    bytes.extend_from_slice(&(field.len() as u64).to_be_bytes());
    bytes.extend_from_slice(field);
}

struct Reader<'a> {
    bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        if self.bytes.len() < len {
            return None;
        }
        let (head, tail) = self.bytes.split_at(len);
        self.bytes = tail;
        Some(head)
    }

    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_be_bytes(self.take(8)?.try_into().ok()?))
    }

    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }

    fn field(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.u64()?).ok()?;
        self.take(len)
    }
}

/// How many times a write retries after losing the compare-and-swap before
/// giving up; each retry first catches up on what won.
const MAX_ATTEMPTS: usize = 64;

/// One entry the transport should append to the relay log, but only if the
/// log's tail is still `expected_tail`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub expected_tail: u64,
    pub blob: Vec<u8>,
}

/// A staged commit adding a member, and the welcome to leave for them. The
/// welcome is only for delivery once the commit is accepted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagedInvite {
    pub commit: Outgoing,
    pub welcome: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncError(pub String);

impl fmt::Display for SyncError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for SyncError {}

impl From<RelayError> for SyncError {
    fn from(error: RelayError) -> Self {
        match error {
            RelayError::Conflict { tail } => Self(format!("relay log moved on (tail {tail})")),
            RelayError::Unavailable(message) => Self(format!("relay unavailable: {message}")),
        }
    }
}

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
    /// A commit this peer created is awaiting the relay's verdict. Not
    /// persisted: it must be resolved before the peer is exported.
    staged: bool,
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
            staged: false,
        })
    }

    /// Everything needed to resume after the app restarts: group keys,
    /// every event seen, the place in the relay log, and writes not yet
    /// sent. The bytes contain private keys; store them like a password.
    pub fn export(&self) -> Result<Vec<u8>, SyncError> {
        if self.staged {
            return Err(SyncError(
                "a commit is pending; resolve it before exporting".to_owned(),
            ));
        }
        let mut bytes = Vec::new();
        bytes.extend_from_slice(EXPORT_MAGIC);
        write_field(&mut bytes, self.member_id.as_bytes());
        write_field(&mut bytes, self.reporting_currency.code().as_bytes());
        match &self.group {
            Some(group) => {
                bytes.push(1);
                write_field(&mut bytes, group.as_bytes());
            }
            None => bytes.push(0),
        }
        bytes.extend_from_slice(&self.cursor.to_be_bytes());
        bytes.extend_from_slice(&self.last_timestamp.physical_millis.to_be_bytes());
        bytes.extend_from_slice(&self.last_timestamp.logical.to_be_bytes());
        bytes.push(u8::from(self.removed));
        bytes.extend_from_slice(&(self.events.len() as u64).to_be_bytes());
        for event in &self.events {
            write_field(&mut bytes, &encode_shared_event(event));
        }
        bytes.extend_from_slice(&(self.outbox.len() as u64).to_be_bytes());
        for event in &self.outbox {
            write_field(&mut bytes, event.event.id.as_str().as_bytes());
        }
        write_field(&mut bytes, &self.member.export()?);
        Ok(bytes)
    }

    /// Restores a peer from [`Peer::export`]'s output.
    pub fn import(bytes: &[u8]) -> Result<Self, SyncError> {
        let malformed = || SyncError("malformed peer state".to_owned());
        let mut reader = Reader { bytes };
        if reader.take(EXPORT_MAGIC.len()) != Some(EXPORT_MAGIC) {
            return Err(malformed());
        }
        let text = |bytes: &[u8]| String::from_utf8(bytes.to_vec()).map_err(|_| malformed());
        let member_id = text(reader.field().ok_or_else(malformed)?)?;
        let currency = text(reader.field().ok_or_else(malformed)?)?;
        let reporting_currency = Currency::from_code(&currency).map_err(|_| malformed())?;
        let group = match reader.take(1).ok_or_else(malformed)?[0] {
            0 => None,
            1 => Some(text(reader.field().ok_or_else(malformed)?)?),
            _ => return Err(malformed()),
        };
        let cursor = reader.u64().ok_or_else(malformed)?;
        let physical = i64::from_be_bytes(reader.u64().ok_or_else(malformed)?.to_be_bytes());
        let logical = reader.u32().ok_or_else(malformed)?;
        let removed = match reader.take(1).ok_or_else(malformed)?[0] {
            0 => false,
            1 => true,
            _ => return Err(malformed()),
        };
        let mut events = Vec::new();
        let mut known = BTreeSet::new();
        for _ in 0..reader.u64().ok_or_else(malformed)? {
            let shared =
                decode_shared_event(reader.field().ok_or_else(malformed)?).ok_or_else(malformed)?;
            known.insert(shared.event.id.clone());
            events.push(shared);
        }
        let mut outbox = VecDeque::new();
        for _ in 0..reader.u64().ok_or_else(malformed)? {
            let id = EventId::new(text(reader.field().ok_or_else(malformed)?)?);
            let event = events
                .iter()
                .find(|shared| shared.event.id == id)
                .ok_or_else(malformed)?;
            outbox.push_back(event.clone());
        }
        let member = Member::import(reader.field().ok_or_else(malformed)?)?;
        if !reader.bytes.is_empty() {
            return Err(malformed());
        }
        Ok(Self {
            member,
            member_id,
            reporting_currency,
            group,
            cursor,
            last_timestamp: HybridTimestamp::new(physical, logical),
            events,
            known,
            outbox,
            removed,
            staged: false,
        })
    }

    /// How many locally written events are still waiting to be sent.
    pub fn pending_count(&self) -> usize {
        self.outbox.len()
    }

    pub fn reporting_currency(&self) -> &Currency {
        &self.reporting_currency
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

    /// Starts a new household group with this peer as its only member,
    /// returning the group's random ID.
    pub fn found_group(&mut self) -> Result<String, SyncError> {
        self.member.create_group()?;
        let group = random_id();
        self.group = Some(group.clone());
        self.cursor = 0;
        Ok(group)
    }

    pub fn group_id(&self) -> Option<&str> {
        self.group.as_deref()
    }

    /// Sequence number of the last relay entry this peer has processed.
    pub fn cursor(&self) -> u64 {
        self.cursor
    }

    fn group(&self) -> Result<String, SyncError> {
        self.group
            .clone()
            .ok_or_else(|| SyncError("this peer has not joined a group".to_owned()))
    }

    fn ensure_not_staged(&self) -> Result<(), SyncError> {
        if self.staged {
            Err(SyncError(
                "a commit is pending; accept or reject it first".to_owned(),
            ))
        } else {
            Ok(())
        }
    }

    // --- The step interface -------------------------------------------
    //
    // The app keeps its network in Dart, so the engine is also usable as a
    // state machine: the transport fetches entries and hands them to
    // `ingest`, asks `next_outgoing` what to send, and reports the relay's
    // verdict. `sync`, `invite`, and `remove` below are the same steps
    // driven through a `Relay`.

    /// Processes relay entries in order. Entries already seen are skipped;
    /// a gap is an error, since MLS needs every message in sequence.
    pub fn ingest(&mut self, entries: &[(u64, Vec<u8>)]) -> Result<(), SyncError> {
        self.ensure_not_staged()?;
        for (sequence, frame) in entries {
            if self.removed || *sequence <= self.cursor {
                continue;
            }
            if *sequence != self.cursor + 1 {
                return Err(SyncError(format!(
                    "entries skipped from {} to {sequence}",
                    self.cursor
                )));
            }
            match self.member.receive(frame)? {
                Received::Application(bytes) => {
                    // A frame that decrypts but is not a shared event came
                    // from a buggy or hostile member; skip it rather than
                    // stall everyone behind it.
                    if let Some(shared) = decode_shared_event(&bytes) {
                        self.observe(shared);
                    }
                }
                Received::Commit { .. } | Received::Own => {}
                Received::Removed => self.removed = true,
            }
            self.cursor = *sequence;
        }
        Ok(())
    }

    /// Encrypts the next queued event for the transport to append. The
    /// same event is returned again until [`Peer::outgoing_accepted`], so a
    /// refused append is retried after catching up.
    pub fn next_outgoing(&mut self) -> Result<Option<Outgoing>, SyncError> {
        self.ensure_not_staged()?;
        if !self.is_member() {
            return Ok(None);
        }
        let Some(next) = self.outbox.front() else {
            return Ok(None);
        };
        let blob = self.member.encrypt(&encode_shared_event(next))?;
        Ok(Some(Outgoing {
            expected_tail: self.cursor,
            blob,
        }))
    }

    /// The relay appended the entry from [`Peer::next_outgoing`] as
    /// `sequence`.
    pub fn outgoing_accepted(&mut self, sequence: u64) -> Result<(), SyncError> {
        if self.outbox.pop_front().is_none() {
            return Err(SyncError("nothing was waiting to be sent".to_owned()));
        }
        self.cursor = sequence;
        Ok(())
    }

    /// Stages adding the holder of `key_package`. The peer must be caught
    /// up; it then refuses everything except [`Peer::commit_accepted`] or
    /// [`Peer::commit_rejected`].
    pub fn begin_invite(&mut self, key_package: &[u8]) -> Result<StagedInvite, SyncError> {
        self.ensure_not_staged()?;
        let invite = self.member.add(key_package)?;
        self.staged = true;
        Ok(StagedInvite {
            commit: Outgoing {
                expected_tail: self.cursor,
                blob: invite.commit,
            },
            welcome: invite.welcome,
        })
    }

    /// Stages removing the member with `member_id`, rotating the group's
    /// keys so they cannot read anything written from now on.
    pub fn begin_removal(&mut self, member_id: &str) -> Result<Outgoing, SyncError> {
        self.ensure_not_staged()?;
        let commit = self.member.remove(member_id)?;
        self.staged = true;
        Ok(Outgoing {
            expected_tail: self.cursor,
            blob: commit,
        })
    }

    /// The relay appended the staged commit as `sequence`.
    pub fn commit_accepted(&mut self, sequence: u64) -> Result<(), SyncError> {
        if !self.staged {
            return Err(SyncError("no commit is pending".to_owned()));
        }
        self.member.confirm_commit()?;
        self.staged = false;
        self.cursor = sequence;
        Ok(())
    }

    /// The relay refused the staged commit (stale tail, or unreachable).
    pub fn commit_rejected(&mut self) -> Result<(), SyncError> {
        if !self.staged {
            return Err(SyncError("no commit is pending".to_owned()));
        }
        self.member.discard_commit()?;
        self.staged = false;
        Ok(())
    }

    /// Joins a group from a welcome. `joined_after` is the sequence number
    /// of the commit that added this peer.
    pub fn join(
        &mut self,
        group: &str,
        welcome: &[u8],
        joined_after: u64,
    ) -> Result<(), SyncError> {
        self.member.join(welcome)?;
        self.group = Some(group.to_owned());
        self.cursor = joined_after;
        Ok(())
    }

    // --- The same steps, driven through a `Relay` ----------------------

    /// Starts a new household group. The relay creates it on first append.
    pub fn found(&mut self, _relay: &mut impl Relay) -> Result<String, SyncError> {
        self.found_group()
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
            let invite = self.begin_invite(key_package)?;
            match relay.append(&group, invite.commit.expected_tail, invite.commit.blob) {
                Ok(sequence) => {
                    self.commit_accepted(sequence)?;
                    let mailbox = random_id();
                    relay.put_mailbox(
                        &mailbox,
                        MailboxItem {
                            group,
                            joined_after: sequence,
                            welcome: invite.welcome,
                        },
                    )?;
                    return Ok(mailbox);
                }
                Err(RelayError::Conflict { .. }) => self.commit_rejected()?,
                Err(error) => {
                    self.commit_rejected()?;
                    return Err(error.into());
                }
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
            .take_mailbox(mailbox)?
            .ok_or_else(|| SyncError("no welcome waiting in that mailbox".to_owned()))?;
        if item.group != group {
            return Err(SyncError(
                "that welcome is for a different group".to_owned(),
            ));
        }
        self.join(group, &item.welcome, item.joined_after)
    }

    /// Removes the member with `member_id`.
    pub fn remove(&mut self, relay: &mut impl Relay, member_id: &str) -> Result<(), SyncError> {
        let group = self.group()?;
        for _ in 0..MAX_ATTEMPTS {
            self.pull(relay)?;
            let commit = self.begin_removal(member_id)?;
            match relay.append(&group, commit.expected_tail, commit.blob) {
                Ok(sequence) => return self.commit_accepted(sequence),
                Err(RelayError::Conflict { .. }) => self.commit_rejected()?,
                Err(error) => {
                    self.commit_rejected()?;
                    return Err(error.into());
                }
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
        let group = self.group()?;
        let mut attempts = 0;
        loop {
            self.pull(relay)?;
            let Some(next) = self.next_outgoing()? else {
                return Ok(());
            };
            match relay.append(&group, next.expected_tail, next.blob) {
                Ok(sequence) => self.outgoing_accepted(sequence)?,
                Err(RelayError::Conflict { .. }) => {
                    attempts += 1;
                    if attempts >= MAX_ATTEMPTS {
                        return Err(SyncError("the relay stayed busy".to_owned()));
                    }
                }
                Err(error) => return Err(error.into()),
            }
        }
    }

    fn pull(&mut self, relay: &impl Relay) -> Result<(), SyncError> {
        let group = self.group()?;
        let entries = relay.read_after(&group, self.cursor)?;
        self.ingest(&entries)
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
