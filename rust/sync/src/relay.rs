use std::collections::{BTreeMap, BTreeSet};

/// Why a relay call did not succeed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RelayError {
    /// An append was refused because the caller's view of the log was stale;
    /// `tail` is the current length.
    Conflict { tail: u64 },
    /// The relay could not be reached or answered nonsense. Nothing was
    /// changed that the caller can rely on; the request may have succeeded.
    Unavailable(String),
}

/// A welcome waiting for one invitee, found by an unguessable mailbox ID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MailboxItem {
    pub group: String,
    /// The log sequence number of the commit that added the invitee; the
    /// invitee only needs entries after it.
    pub joined_after: u64,
    pub welcome: Vec<u8>,
}

/// What the relay offers, and everything it is allowed to know: group and
/// mailbox identifiers (random, carrying no meaning), sequence numbers, and
/// opaque blobs. There is deliberately no field for a sender, a kind, an
/// amount, or a name.
pub trait Relay {
    /// Appends `blob` as entry `expected_tail + 1`, only if the log's tail is
    /// exactly `expected_tail`. Returns the new entry's sequence number.
    fn append(&mut self, group: &str, expected_tail: u64, blob: Vec<u8>)
    -> Result<u64, RelayError>;

    /// Entries with sequence number greater than `after`, in order.
    fn read_after(&self, group: &str, after: u64) -> Result<Vec<(u64, Vec<u8>)>, RelayError>;

    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem) -> Result<(), RelayError>;

    /// Removes and returns a mailbox's item (a welcome is single-use).
    fn take_mailbox(&mut self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError>;

    /// Read without consumption; durable clients acknowledge only after save.
    fn peek_mailbox(&self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError>;
    fn acknowledge_mailbox(&mut self, mailbox: &str) -> Result<(), RelayError>;
}

/// The reference relay: in memory, used by tests and as the behavioural
/// specification for the Cloudflare Durable Object implementation.
#[derive(Default)]
pub struct MemoryRelay {
    groups: BTreeMap<String, Vec<Vec<u8>>>,
    mailboxes: BTreeMap<String, MailboxItem>,
    consumed_mailboxes: BTreeSet<String>,
}

impl MemoryRelay {
    /// The current tail sequence number of `group` (0 for an empty log).
    pub fn len(&self, group: &str) -> u64 {
        self.groups.get(group).map_or(0, |log| log.len() as u64)
    }

    pub fn is_empty(&self, group: &str) -> bool {
        self.len(group) == 0
    }

    /// Every byte string this relay holds, keys and values alike, for
    /// tests that inspect storage directly for readable data.
    pub fn raw_storage(&self) -> Vec<Vec<u8>> {
        let mut bytes = Vec::new();
        for (group, log) in &self.groups {
            bytes.push(group.as_bytes().to_vec());
            bytes.extend(log.iter().cloned());
        }
        for (mailbox, item) in &self.mailboxes {
            bytes.push(mailbox.as_bytes().to_vec());
            bytes.push(item.group.as_bytes().to_vec());
            bytes.push(item.joined_after.to_be_bytes().to_vec());
            bytes.push(item.welcome.clone());
        }
        bytes
    }
}

impl Relay for MemoryRelay {
    fn append(
        &mut self,
        group: &str,
        expected_tail: u64,
        blob: Vec<u8>,
    ) -> Result<u64, RelayError> {
        let log = self.groups.entry(group.to_owned()).or_default();
        let tail = log.len() as u64;
        if tail != expected_tail {
            return Err(RelayError::Conflict { tail });
        }
        log.push(blob);
        Ok(tail + 1)
    }

    fn read_after(&self, group: &str, after: u64) -> Result<Vec<(u64, Vec<u8>)>, RelayError> {
        let Some(log) = self.groups.get(group) else {
            return Ok(Vec::new());
        };
        let skip = usize::try_from(after).unwrap_or(usize::MAX);
        Ok(log
            .iter()
            .enumerate()
            .skip(skip)
            .map(|(index, blob)| (index as u64 + 1, blob.clone()))
            .collect())
    }

    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem) -> Result<(), RelayError> {
        if let Some(stored) = self.mailboxes.get(mailbox) {
            return if *stored == item {
                Ok(())
            } else {
                Err(RelayError::Unavailable(
                    "mailbox already holds a different invite".to_owned(),
                ))
            };
        }
        self.mailboxes.insert(mailbox.to_owned(), item);
        Ok(())
    }

    fn take_mailbox(&mut self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        let Some(item) = self.mailboxes.get(mailbox) else {
            return Ok(None);
        };
        if !self.consumed_mailboxes.insert(mailbox.to_owned()) {
            return Ok(None);
        }
        Ok(Some(item.clone()))
    }

    fn peek_mailbox(&self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        Ok(if self.consumed_mailboxes.contains(mailbox) {
            None
        } else {
            self.mailboxes.get(mailbox).cloned()
        })
    }

    fn acknowledge_mailbox(&mut self, mailbox: &str) -> Result<(), RelayError> {
        if self.mailboxes.contains_key(mailbox) {
            self.consumed_mailboxes.insert(mailbox.to_owned());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_are_totally_ordered_and_compare_and_swap() {
        let mut relay = MemoryRelay::default();
        assert_eq!(relay.append("g", 0, b"a".to_vec()), Ok(1));
        assert_eq!(relay.append("g", 1, b"b".to_vec()), Ok(2));
        // A writer that still believes the tail is 1 is refused.
        assert_eq!(
            relay.append("g", 1, b"stale".to_vec()),
            Err(RelayError::Conflict { tail: 2 })
        );
        assert_eq!(
            relay.read_after("g", 0).unwrap(),
            vec![(1, b"a".to_vec()), (2, b"b".to_vec())]
        );
        assert_eq!(relay.read_after("g", 1).unwrap(), vec![(2, b"b".to_vec())]);
        assert!(relay.read_after("g", 2).unwrap().is_empty());
        assert!(relay.read_after("unknown", 0).unwrap().is_empty());
    }

    #[test]
    fn groups_are_independent() {
        let mut relay = MemoryRelay::default();
        relay.append("one", 0, b"x".to_vec()).unwrap();
        assert_eq!(relay.append("two", 0, b"y".to_vec()), Ok(1));
        assert_eq!(relay.len("one"), 1);
        assert_eq!(relay.len("two"), 1);
    }

    #[test]
    fn a_mailbox_item_can_be_taken_only_once() {
        let mut relay = MemoryRelay::default();
        let item = MailboxItem {
            group: "g".to_owned(),
            joined_after: 3,
            welcome: b"w".to_vec(),
        };
        assert_eq!(relay.take_mailbox("m").unwrap(), None);
        relay.put_mailbox("m", item.clone()).unwrap();
        relay.put_mailbox("m", item.clone()).unwrap();
        assert_eq!(relay.take_mailbox("m").unwrap(), Some(item.clone()));
        relay.put_mailbox("m", item.clone()).unwrap();
        assert_eq!(relay.take_mailbox("m").unwrap(), None);
        let mut changed = item;
        changed.joined_after += 1;
        assert!(relay.put_mailbox("m", changed).is_err());
    }

    #[test]
    fn welcome_reads_are_repeatable_until_idempotently_acknowledged() {
        let mut relay = MemoryRelay::default();
        let item = MailboxItem {
            group: "g".to_owned(),
            joined_after: 1,
            welcome: b"encrypted".to_vec(),
        };
        relay.acknowledge_mailbox("m").unwrap(); // Empty acknowledgements do not poison future delivery.
        relay.put_mailbox("m", item.clone()).unwrap();
        assert_eq!(relay.peek_mailbox("m").unwrap(), Some(item.clone()));
        assert_eq!(relay.peek_mailbox("m").unwrap(), Some(item.clone()));
        relay.acknowledge_mailbox("m").unwrap();
        relay.acknowledge_mailbox("m").unwrap();
        relay.put_mailbox("m", item).unwrap();
        assert_eq!(relay.peek_mailbox("m").unwrap(), None);
    }
}
