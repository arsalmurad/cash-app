use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fmt;

use crate::authenticated_history::SignedEvent;
use cash_core::{
    Currency, EditField, Event, EventId, EventKind, HybridTimestamp, SharedEvent, SharedSnapshot,
    SharedState, decode_shared_event, encode_shared_event,
};
use cash_crypto::{Member, Received, author_id};

use crate::ids::random_id;
use crate::relay::{MailboxItem, Relay, RelayError};

const EXPORT_MAGIC: &[u8] = b"cash-app peer v5\0";
const SIGNED_V4_EXPORT_MAGIC: &[u8] = b"cash-app peer v4\0";
const SIGNED_V3_EXPORT_MAGIC: &[u8] = b"cash-app peer v3\0";
const SIGNED_V2_EXPORT_MAGIC: &[u8] = b"cash-app peer v2\0";
const LEGACY_EXPORT_MAGIC: &[u8] = b"cash-app peer v1\0";

pub(crate) fn write_field(bytes: &mut Vec<u8>, field: &[u8]) {
    bytes.extend_from_slice(&(field.len() as u64).to_be_bytes());
    bytes.extend_from_slice(field);
}

pub(crate) struct Reader<'a> {
    pub(crate) bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    pub(crate) fn take(&mut self, len: usize) -> Option<&'a [u8]> {
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

    pub(crate) fn field(&mut self) -> Option<&'a [u8]> {
        let len = usize::try_from(self.u64()?).ok()?;
        self.take(len)
    }
}

/// What is waiting to be sent, oldest first.
#[derive(Clone, Debug, Eq, PartialEq)]
enum Outbound {
    /// One locally written event.
    Event(EventId),
    /// The events known when a member was added, sent in batches: MLS gives
    /// a new member nothing written before their commit, so without this
    /// they would never see the household's history. Receivers that already
    /// have an event ignore it (events are idempotent by ID).
    Backfill { ids: Vec<EventId>, offset: usize },
}

const PAYLOAD_EVENT: u8 = 3;
const PAYLOAD_BATCH: u8 = 4;
const MAX_BATCH_EVENTS: usize = 200;
const MAX_BATCH_BYTES: usize = 48 * 1024;

fn encode_event_payload(event: &SignedEvent) -> Vec<u8> {
    let mut bytes = vec![PAYLOAD_EVENT];
    bytes.extend_from_slice(&event.encode());
    bytes
}

fn encode_batch_payload(events: &[&SignedEvent]) -> Vec<u8> {
    let mut bytes = vec![PAYLOAD_BATCH];
    bytes.extend_from_slice(&(events.len() as u64).to_be_bytes());
    for event in events {
        write_field(&mut bytes, &event.encode());
    }
    bytes
}

/// Decodes an application payload into the events it carries; `None` for
/// anything that is not a payload this version understands.
fn decode_payload(bytes: &[u8]) -> Option<Vec<SignedEvent>> {
    let (tag, rest) = bytes.split_first()?;
    match *tag {
        PAYLOAD_EVENT => Some(vec![SignedEvent::decode(rest)?]),
        PAYLOAD_BATCH => {
            let mut reader = Reader { bytes: rest };
            let count = reader.u64()?;
            if count > MAX_BATCH_EVENTS as u64 || bytes.len() > 65 * 1024 {
                return None;
            }
            let mut events = Vec::new();
            for _ in 0..count {
                events.push(SignedEvent::decode(reader.field()?)?);
            }
            reader.bytes.is_empty().then_some(events)
        }
        _ => None,
    }
}

/// How many events, starting at `offset`, fit in one backfill message.
fn batch_len(events: &[&SignedEvent]) -> usize {
    let mut size = 0;
    for (index, event) in events.iter().enumerate() {
        size += event.encode().len() + 8;
        if index >= MAX_BATCH_EVENTS || (index > 0 && size > MAX_BATCH_BYTES) {
            return index;
        }
    }
    events.len()
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
    snapshot: SharedSnapshot,
    proofs: BTreeMap<EventId, SignedEvent>,
    legacy_unverified: bool,
    known: BTreeSet<EventId>,
    outbox: VecDeque<Outbound>,
    removed: bool,
    /// A commit this peer created is awaiting the relay's verdict.
    staged: bool,
    staged_frame: Option<Outgoing>,
    /// The staged commit adds a member (rather than removes one), so
    /// accepting it owes them a history backfill.
    staged_adds_member: bool,
}

impl Peer {
    /// `member_id` is the identity inside the group's MLS credential, which
    /// every member learns. Use an opaque identifier, not a real name; show
    /// names from inside the encrypted stream.
    pub fn new(member_id: &str, reporting_currency: Currency) -> Result<Self, SyncError> {
        Ok(Self {
            member: Member::new(member_id)?,
            member_id: member_id.to_owned(),
            snapshot: SharedSnapshot::from_events(reporting_currency.clone(), []),
            reporting_currency,
            group: None,
            cursor: 0,
            last_timestamp: HybridTimestamp::new(0, 0),
            events: Vec::new(),
            proofs: BTreeMap::new(),
            legacy_unverified: false,
            known: BTreeSet::new(),
            outbox: VecDeque::new(),
            removed: false,
            staged: false,
            staged_frame: None,
            staged_adds_member: false,
        })
    }

    /// Everything needed to resume after the app restarts: group keys,
    /// every event seen, the place in the relay log, and writes not yet
    /// sent. The bytes contain private keys; store them like a password.
    pub fn export(&self) -> Result<Vec<u8>, SyncError> {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(if self.legacy_unverified {
            LEGACY_EXPORT_MAGIC
        } else {
            EXPORT_MAGIC
        });
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
        if self.legacy_unverified {
            for event in &self.events {
                write_field(&mut bytes, &encode_shared_event(event));
            }
        } else {
            if self.proofs.len() != self.events.len() {
                return Err(SyncError("authenticated history is incomplete".to_owned()));
            }
            for proof in self.proofs.values() {
                write_field(&mut bytes, &proof.encode());
            }
        }
        bytes.extend_from_slice(&(self.outbox.len() as u64).to_be_bytes());
        for item in &self.outbox {
            match item {
                Outbound::Event(id) => {
                    bytes.push(0);
                    write_field(&mut bytes, id.as_str().as_bytes());
                }
                Outbound::Backfill { ids, offset } => {
                    bytes.push(1);
                    bytes.extend_from_slice(&(*offset as u64).to_be_bytes());
                    bytes.extend_from_slice(&(ids.len() as u64).to_be_bytes());
                    for id in ids {
                        write_field(&mut bytes, id.as_str().as_bytes());
                    }
                }
            }
        }
        write_field(&mut bytes, &self.member.export()?);
        if !self.legacy_unverified {
            match &self.staged_frame {
                None => bytes.push(0),
                Some(frame) => {
                    bytes.push(1);
                    bytes.push(u8::from(self.staged_adds_member));
                    bytes.extend_from_slice(&frame.expected_tail.to_be_bytes());
                    write_field(&mut bytes, &frame.blob);
                }
            }
            write_field(&mut bytes, &self.snapshot.checkpoint_bytes());
        }
        Ok(bytes)
    }

    /// Restores a peer from [`Peer::export`]'s output.
    pub fn import(bytes: &[u8]) -> Result<Self, SyncError> {
        let malformed = || SyncError("malformed peer state".to_owned());
        let mut reader = Reader { bytes };
        let magic = reader.take(EXPORT_MAGIC.len()).ok_or_else(malformed)?;
        let legacy_unverified = if magic == LEGACY_EXPORT_MAGIC {
            true
        } else if magic == EXPORT_MAGIC
            || magic == SIGNED_V4_EXPORT_MAGIC
            || magic == SIGNED_V3_EXPORT_MAGIC
            || magic == SIGNED_V2_EXPORT_MAGIC
        {
            false
        } else {
            return Err(malformed());
        };
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
        let mut proofs = BTreeMap::new();
        for _ in 0..reader.u64().ok_or_else(malformed)? {
            let encoded = reader.field().ok_or_else(malformed)?;
            if legacy_unverified {
                let shared = decode_shared_event(encoded).ok_or_else(malformed)?;
                known.insert(shared.event.id.clone());
                events.push(shared);
            } else {
                let proof = SignedEvent::decode(encoded).ok_or_else(malformed)?;
                let id = proof.proof_id();
                if !known.insert(id.clone()) {
                    return Err(malformed());
                }
                events.push(proof.shared.clone());
                proofs.insert(id, proof);
            }
        }
        let mut outbox = VecDeque::new();
        for _ in 0..reader.u64().ok_or_else(malformed)? {
            let read_id = |reader: &mut Reader<'_>| -> Result<EventId, SyncError> {
                let id = EventId::new(text(reader.field().ok_or_else(malformed)?)?);
                if known.contains(&id) {
                    Ok(id)
                } else {
                    Err(malformed())
                }
            };
            match reader.take(1).ok_or_else(malformed)?[0] {
                0 => outbox.push_back(Outbound::Event(read_id(&mut reader)?)),
                1 => {
                    let offset = usize::try_from(reader.u64().ok_or_else(malformed)?)
                        .map_err(|_| malformed())?;
                    let mut ids = Vec::new();
                    for _ in 0..reader.u64().ok_or_else(malformed)? {
                        ids.push(read_id(&mut reader)?);
                    }
                    if offset > ids.len() {
                        return Err(malformed());
                    }
                    outbox.push_back(Outbound::Backfill { ids, offset });
                }
                _ => return Err(malformed()),
            }
        }
        let member = Member::import(reader.field().ok_or_else(malformed)?)?;
        let mut staged_adds_member = false;
        let staged_frame = if magic == EXPORT_MAGIC
            || magic == SIGNED_V4_EXPORT_MAGIC
            || magic == SIGNED_V3_EXPORT_MAGIC
        {
            match reader.take(1).ok_or_else(malformed)?[0] {
                0 => None,
                1 => {
                    staged_adds_member = match reader.take(1).ok_or_else(malformed)?[0] {
                        0 => false,
                        1 => true,
                        _ => return Err(malformed()),
                    };
                    let expected_tail = reader.u64().ok_or_else(malformed)?;
                    let blob = reader.field().ok_or_else(malformed)?.to_vec();
                    if expected_tail != cursor || blob.is_empty() || blob.len() > 256 * 1024 {
                        return Err(malformed());
                    }
                    Some(Outgoing {
                        expected_tail,
                        blob,
                    })
                }
                _ => return Err(malformed()),
            }
        } else {
            None
        };
        let checkpoint = if magic == EXPORT_MAGIC || magic == SIGNED_V4_EXPORT_MAGIC {
            Some(reader.field().ok_or_else(malformed)?)
        } else {
            None
        };
        if !reader.bytes.is_empty() {
            return Err(malformed());
        }
        for proof in proofs.values() {
            proof.verify(&member)?;
        }
        // Derived state never substitutes for original-author verification.
        // Old signed archives gain a checkpoint on their next normal export.
        let snapshot =
            SharedSnapshot::from_events(reporting_currency.clone(), events.iter().cloned());
        if checkpoint.is_some_and(|bytes| bytes != snapshot.checkpoint_bytes()) {
            return Err(SyncError(
                "shared checkpoint does not match authenticated history".to_owned(),
            ));
        }
        Ok(Self {
            member,
            member_id,
            reporting_currency,
            group,
            cursor,
            last_timestamp: HybridTimestamp::new(physical, logical),
            events,
            snapshot,
            proofs,
            legacy_unverified,
            known,
            outbox,
            removed,
            staged: staged_frame.is_some(),
            staged_frame,
            staged_adds_member,
        })
    }

    /// How many locally written events are still waiting to be sent.
    pub fn pending_count(&self) -> usize {
        self.outbox.len() + usize::from(self.staged)
    }

    pub fn reporting_currency(&self) -> &Currency {
        &self.reporting_currency
    }

    pub fn member_id(&self) -> &str {
        &self.member_id
    }

    /// Old unsigned histories remain locally viewable/exportable, never
    /// silently re-signed as authenticated history or sent to another peer.
    pub fn legacy_unverified(&self) -> bool {
        self.legacy_unverified
    }

    /// A fresh single-use key package for someone to invite this peer with.
    pub fn key_package(&self) -> Result<Vec<u8>, SyncError> {
        self.ensure_not_staged()?;
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

    /// Recover authenticated history only, never an old MLS sender ratchet.
    /// The replacement must first be freshly invited to the same household.
    /// Validate every proof before changing state; preserve its original author.
    pub fn merge_recovery_history(&mut self, saved: &[u8]) -> Result<bool, SyncError> {
        self.ensure_not_staged()?;
        let archive = Self::import(saved)?;
        if !self.is_member()
            || archive.legacy_unverified
            || self.group.is_none()
            || self.group != archive.group
        {
            return Err(SyncError(
                "Join the original household with a fresh invite before recovering signed history."
                    .to_owned(),
            ));
        }
        // Even an empty archive must refer to this cryptographic MLS group,
        // not just a relay ID supplied by the invitation's text.
        if self.member.group_identifier() != archive.member.group_identifier() {
            return Err(SyncError(
                "The backup belongs to another cryptographic household.".to_owned(),
            ));
        }
        if self.public_key() == archive.public_key() {
            return Err(SyncError("Remove the old device before inviting its replacement; recovery must use fresh keys.".to_owned()));
        }
        for proof in archive.proofs.values() {
            proof.verify(&self.member)?;
        }
        // A correctly joined fresh identity can wait durably for retirement
        // rather than consume and then discard its single-use welcome.
        if self
            .member_keys()?
            .iter()
            .any(|(_, key)| key == &archive.public_key())
        {
            return Ok(false);
        }
        let mut ids = Vec::new();
        for (id, proof) in archive.proofs {
            if !self.known.contains(&id) {
                ids.push(id);
                self.observe(proof);
            }
        }
        if !ids.is_empty() {
            self.outbox.push_back(Outbound::Backfill { ids, offset: 0 });
        }
        Ok(true)
    }

    /// Starts a new household group with this peer as its only member,
    /// returning the group's random ID.
    pub fn found_group(&mut self) -> Result<String, SyncError> {
        self.ensure_not_staged()?;
        if self.group.is_some() {
            return Err(SyncError(
                "archive or leave the existing household before creating another".to_owned(),
            ));
        }
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
        if self.legacy_unverified {
            return Err(SyncError("This household has unsigned legacy history. Keep an archive and create a new household before sharing further.".to_owned()));
        }
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
        if self.legacy_unverified {
            self.ensure_not_staged()?;
        }
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
            let staged_before = if self.staged_frame.is_some() {
                Some(self.export()?)
            } else {
                None
            };
            if let Some(pending) = &self.staged_frame {
                if pending.blob == *frame {
                    self.commit_accepted(*sequence)?;
                    continue;
                }
                // Another entry won this exact compare-and-swap slot. Only
                // this ordered-log evidence, not a lost reply, rejects it.
                self.commit_rejected()?;
            }
            let (received, sender) = match self.member.receive_authenticated(frame) {
                Ok(received) => received,
                Err(error) => {
                    if let Some(saved) = staged_before {
                        *self = Self::import(&saved)?;
                    }
                    return Err(error.into());
                }
            };
            match received {
                Received::Application(bytes) => {
                    // A frame that decrypts but carries no shared events came
                    // from a buggy or hostile member; skip it rather than
                    // stall everyone behind it.
                    if let Some(proofs) = decode_payload(&bytes) {
                        let live = bytes.first() == Some(&PAYLOAD_EVENT);
                        let valid = proofs.iter().all(|proof| {
                            proof.verify(&self.member).is_ok()
                                && (!live
                                    || sender.as_ref().is_some_and(|sender| {
                                        sender.public_key == proof.public_key
                                    }))
                        });
                        // Validate the whole batch before changing the fold.
                        if valid {
                            for proof in proofs {
                                self.observe(proof);
                            }
                        }
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
        if let Some(pending) = &self.staged_frame {
            return Ok(Some(pending.clone()));
        }
        self.ensure_not_staged()?;
        if !self.is_member() {
            return Ok(None);
        }
        let payload = match self.outbox.front() {
            None => return Ok(None),
            Some(Outbound::Event(id)) => {
                let event = self.event(id)?;
                encode_event_payload(event)
            }
            Some(Outbound::Backfill { ids, offset }) => {
                let remaining = self.events_named(&ids[*offset..])?;
                let count = batch_len(&remaining);
                encode_batch_payload(&remaining[..count])
            }
        };
        let blob = self.member.encrypt(&payload)?;
        Ok(Some(Outgoing {
            expected_tail: self.cursor,
            blob,
        }))
    }

    /// The relay appended the entry from [`Peer::next_outgoing`] as
    /// `sequence`.
    pub fn outgoing_accepted(&mut self, sequence: u64) -> Result<(), SyncError> {
        if self.staged {
            return self.commit_accepted(sequence);
        }
        if sequence != self.cursor + 1 {
            return Err(SyncError(
                "outgoing acknowledgement skipped its log slot".to_owned(),
            ));
        }
        match self.outbox.front() {
            None => return Err(SyncError("nothing was waiting to be sent".to_owned())),
            Some(Outbound::Event(_)) => {
                self.outbox.pop_front();
            }
            Some(Outbound::Backfill { ids, offset }) => {
                let count = batch_len(&self.events_named(&ids[*offset..])?);
                let next = offset + count;
                if next >= ids.len() {
                    self.outbox.pop_front();
                } else if let Some(Outbound::Backfill { offset, .. }) = self.outbox.front_mut() {
                    *offset = next;
                }
            }
        }
        self.cursor = sequence;
        Ok(())
    }

    fn event(&self, id: &EventId) -> Result<&SignedEvent, SyncError> {
        self.proofs
            .get(id)
            .ok_or_else(|| SyncError(format!("queued event {} is missing", id.as_str())))
    }

    fn events_named(&self, ids: &[EventId]) -> Result<Vec<&SignedEvent>, SyncError> {
        ids.iter().map(|id| self.event(id)).collect()
    }

    /// Stages adding the holder of `key_package`. Persist the exported peer
    /// before submitting the commit; ingestion can reconcile a lost reply
    /// against its exact log slot, including after restart.
    pub fn begin_invite(&mut self, key_package: &[u8]) -> Result<StagedInvite, SyncError> {
        self.ensure_not_staged()?;
        let invite = self.member.add(key_package)?;
        self.staged = true;
        self.staged_adds_member = true;
        self.staged_frame = Some(Outgoing {
            expected_tail: self.cursor,
            blob: invite.commit.clone(),
        });
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
        self.staged_adds_member = false;
        self.staged_frame = Some(Outgoing {
            expected_tail: self.cursor,
            blob: commit.clone(),
        });
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
        if sequence != self.cursor + 1 {
            return Err(SyncError(
                "commit acknowledgement skipped its log slot".to_owned(),
            ));
        }
        self.member.confirm_commit()?;
        self.staged = false;
        self.staged_frame = None;
        self.cursor = sequence;
        if self.staged_adds_member && !self.events.is_empty() {
            // Sorted into the total order so the new member's first batches
            // are the oldest history.
            let mut ordered: Vec<_> = self.proofs.iter().collect();
            ordered.sort_by_key(|(id, proof)| (proof.shared.event.order_key(), (*id).clone()));
            let ids = ordered.into_iter().map(|(id, _)| id.clone()).collect();
            self.outbox.push_back(Outbound::Backfill { ids, offset: 0 });
        }
        self.staged_adds_member = false;
        Ok(())
    }

    /// The relay definitively refused the staged commit (stale tail).
    /// An unreachable relay or a lost response is not a rejection.
    pub fn commit_rejected(&mut self) -> Result<(), SyncError> {
        if !self.staged {
            return Err(SyncError("no commit is pending".to_owned()));
        }
        self.member.discard_commit()?;
        self.staged = false;
        self.staged_frame = None;
        self.staged_adds_member = false;
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
        self.ensure_not_staged()?;
        if self.group.is_some() {
            return Err(SyncError("this peer already has a household".to_owned()));
        }
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
                // Unavailability is indeterminate: retain the staged commit
                // for ordered-log reconciliation, never guess rejection.
                Err(error) => return Err(error.into()),
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
                Err(error) => return Err(error.into()),
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
        self.ensure_not_staged()?;
        if !self.is_member() {
            return Err(SyncError("this peer is not in the group".to_owned()));
        }
        let timestamp = self
            .last_timestamp
            .checked_next(wall_clock_millis)
            .ok_or_else(|| SyncError("hybrid clock exhausted".to_owned()))?;
        let actor = author_id(&self.member.public_key());
        // Restoring a backup on a second device must not reproduce event IDs
        // when both copies happen to write at the same hybrid timestamp.
        let id = format!("{actor}-{}", random_id());
        let base = self.base_for(&kind);
        let event = SharedEvent {
            event: Event::new(
                id,
                actor,
                timestamp.physical_millis,
                timestamp.logical,
                kind,
            ),
            base,
        };
        let proof = SignedEvent::sign(&self.member, event.clone())?;
        let id = proof.proof_id();
        self.observe(proof);
        self.outbox.push_back(Outbound::Event(id));
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
        self.snapshot.state().edit_head(transaction, field).cloned()
    }

    /// This peer's view of the shared ledger: everything it has written or
    /// received, folded.
    pub fn state(&self) -> SharedState {
        self.snapshot.state().clone()
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

    fn observe(&mut self, proof: SignedEvent) {
        self.last_timestamp = self.last_timestamp.max(proof.shared.event.timestamp);
        let id = proof.proof_id();
        if self.known.insert(id.clone()) {
            self.snapshot.extend([proof.shared.clone()]);
            self.events.push(proof.shared.clone());
            self.proofs.insert(id, proof);
        }
    }

    /// Tries to decrypt one relay frame without recording anything; for
    /// tests that check a removed member really is locked out.
    pub fn try_decrypt(&mut self, frame: &[u8]) -> Result<(), SyncError> {
        self.member.receive(frame).map(|_| ()).map_err(Into::into)
    }
}

#[cfg(test)]
mod authorship_tests {
    use super::*;
    use crate::authenticated_history::SignedEvent;
    use cash_core::AccountId;
    use cash_crypto::author_id;

    fn household() -> (Peer, Member) {
        let mut alice = Peer::new("alice", Currency::from_code("USD").unwrap()).unwrap();
        alice.found_group().unwrap();
        let mut bob = Member::new("bob").unwrap();
        let invite = alice.begin_invite(&bob.key_package().unwrap()).unwrap();
        alice.commit_accepted(1).unwrap();
        bob.join(&invite.welcome).unwrap();
        (alice, bob)
    }

    fn event(actor: &str) -> SharedEvent {
        SharedEvent {
            event: Event::new(
                format!("{actor}-event"),
                actor,
                1,
                0,
                EventKind::AccountOpened {
                    account_id: AccountId::new("joint"),
                    name: "Joint".to_owned(),
                    currency: Currency::from_code("USD").unwrap(),
                },
            ),
            base: None,
        }
    }

    #[test]
    fn observed_clock_overflow_carries_and_restart_preserves_causality() {
        let (mut alice, mut bob) = household();
        let mut incoming = event(&author_id(&bob.public_key()));
        incoming.event.timestamp = HybridTimestamp::new(100, u32::MAX);
        let proof = SignedEvent::sign(&bob, incoming).unwrap();
        let mut payload = vec![3];
        payload.extend_from_slice(&proof.encode());
        alice
            .ingest(&[(2, bob.encrypt(&payload).unwrap())])
            .unwrap();
        let written = alice.write(1, event("unused").event.kind).unwrap();
        assert_eq!(written.event.timestamp, HybridTimestamp::new(101, 0));
        let mut restarted = Peer::import(&alice.export().unwrap()).unwrap();
        let next = restarted.write(1, event("unused").event.kind).unwrap();
        assert_eq!(next.event.timestamp, HybridTimestamp::new(101, 1));
        assert_ne!(written.event.id, next.event.id);
    }

    #[test]
    fn exhausted_observed_clock_refuses_a_write_without_mutation() {
        let (mut alice, mut bob) = household();
        let mut incoming = event(&author_id(&bob.public_key()));
        incoming.event.timestamp = HybridTimestamp::new(i64::MAX, u32::MAX);
        let proof = SignedEvent::sign(&bob, incoming).unwrap();
        let mut payload = vec![3];
        payload.extend_from_slice(&proof.encode());
        alice
            .ingest(&[(2, bob.encrypt(&payload).unwrap())])
            .unwrap();
        let saved = alice.export().unwrap();
        assert!(alice.write(1, event("unused").event.kind).is_err());
        assert_eq!(alice.export().unwrap(), saved);
    }

    #[test]
    fn unsigned_legacy_frames_cannot_enter_authenticated_history() {
        let (mut alice, mut bob) = household();
        let mut payload = vec![1];
        payload.extend_from_slice(&encode_shared_event(&event("alice")));
        let frame = bob.encrypt(&payload).unwrap();
        alice.ingest(&[(2, frame)]).unwrap();
        assert!(alice.state().ledger.accounts.is_empty());
        assert_eq!(alice.cursor(), 2);
    }

    #[test]
    fn a_valid_author_proof_cannot_be_substituted_for_the_live_sender() {
        let (mut alice, mut bob) = household();
        let proof =
            SignedEvent::sign(&alice.member, event(&author_id(&alice.public_key()))).unwrap();
        let mut payload = vec![3];
        payload.extend_from_slice(&proof.encode());
        let frame = bob.encrypt(&payload).unwrap();
        alice.ingest(&[(2, frame)]).unwrap();
        assert!(alice.state().ledger.accounts.is_empty());
    }

    #[test]
    fn valid_original_proofs_can_be_forwarded_but_tampered_batches_are_atomic() {
        let (mut alice, mut bob) = household();
        let proof =
            SignedEvent::sign(&alice.member, event(&author_id(&alice.public_key()))).unwrap();
        let mut corrupt = proof.clone();
        corrupt.signature[0] ^= 1;
        let mut payload = vec![4];
        payload.extend_from_slice(&2_u64.to_be_bytes());
        write_field(&mut payload, &proof.encode());
        write_field(&mut payload, &corrupt.encode());
        alice
            .ingest(&[(2, bob.encrypt(&payload).unwrap())])
            .unwrap();
        assert!(alice.state().ledger.accounts.is_empty());
        let mut payload = vec![4];
        payload.extend_from_slice(&1_u64.to_be_bytes());
        write_field(&mut payload, &proof.encode());
        alice
            .ingest(&[(3, bob.encrypt(&payload).unwrap())])
            .unwrap();
        assert_eq!(alice.state().ledger.accounts.len(), 1);
    }

    #[test]
    fn legacy_unsigned_state_is_viewable_and_exportable_but_cannot_mutate_or_sync() {
        let (mut alice, _) = household();
        let old = event("alice");
        alice.events.push(old.clone());
        alice.snapshot.extend([old.clone()]);
        alice.known.insert(old.event.id.clone());
        alice.legacy_unverified = true;
        let archive = alice.export().unwrap();
        assert!(archive.starts_with(LEGACY_EXPORT_MAGIC));
        let mut restored = Peer::import(&archive).unwrap();
        assert!(restored.legacy_unverified());
        assert_eq!(
            restored.state().canonical_bytes(),
            alice.state().canonical_bytes()
        );
        assert_eq!(restored.export().unwrap(), archive);
        assert!(restored.write(2, old.event.kind.clone()).is_err());
        assert!(restored.ingest(&[]).is_err());
        assert!(restored.next_outgoing().is_err());
        assert!(restored.key_package().is_err());
        assert!(restored.found_group().is_err());
    }

    #[test]
    fn conflicting_authenticated_event_ids_survive_restart_and_backfill() {
        let (mut alice, mut bob) = household();
        let mut original = event(&author_id(&bob.public_key()));
        let first = SignedEvent::sign(&bob, original.clone()).unwrap();
        original.event.timestamp.physical_millis = 2;
        let second = SignedEvent::sign(&bob, original).unwrap();
        for (index, proof) in [first, second].iter().enumerate() {
            let mut payload = vec![PAYLOAD_EVENT];
            payload.extend_from_slice(&proof.encode());
            alice
                .ingest(&[(2 + index as u64, bob.encrypt(&payload).unwrap())])
                .unwrap();
        }
        assert_eq!(alice.state().rejected.len(), 1);
        let mut alice = Peer::import(&alice.export().unwrap()).unwrap();
        assert_eq!(alice.state().rejected.len(), 1);
        let mut carol = Peer::new("carol", Currency::from_code("USD").unwrap()).unwrap();
        let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();
        alice.commit_accepted(4).unwrap();
        carol
            .join(alice.group_id().unwrap(), &invite.welcome, 4)
            .unwrap();
        while let Some(outgoing) = alice.next_outgoing().unwrap() {
            let sequence = alice.cursor() + 1;
            carol.ingest(&[(sequence, outgoing.blob)]).unwrap();
            alice.outgoing_accepted(sequence).unwrap();
        }
        assert_eq!(
            alice.state().canonical_bytes(),
            carol.state().canonical_bytes()
        );
    }

    #[test]
    fn restored_signing_identities_still_generate_distinct_event_ids_at_the_same_clock() {
        let (alice, _) = household();
        let archive = alice.export().unwrap();
        let mut first = Peer::import(&archive).unwrap();
        let mut second = Peer::import(&archive).unwrap();
        let kind = event("unused").event.kind;
        let a = first.write(1, kind.clone()).unwrap();
        let b = second.write(1, kind).unwrap();
        assert_eq!(a.event.timestamp, b.event.timestamp);
        assert_ne!(a.event.id, b.event.id);
    }
}
