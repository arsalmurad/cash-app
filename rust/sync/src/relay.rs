use std::collections::BTreeMap;

/// Why an append was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppendError {
    /// The caller's view of the log was stale; `tail` is the current length.
    Conflict { tail: u64 },
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
    fn append(
        &mut self,
        group: &str,
        expected_tail: u64,
        blob: Vec<u8>,
    ) -> Result<u64, AppendError>;

    /// Entries with sequence number greater than `after`, in order.
    fn read_after(&self, group: &str, after: u64) -> Vec<(u64, Vec<u8>)>;

    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem);

    /// Removes and returns a mailbox's item (a welcome is single-use).
    fn take_mailbox(&mut self, mailbox: &str) -> Option<MailboxItem>;
}

/// The reference relay: in memory, used by tests and as the behavioural
/// specification for the Cloudflare Durable Object implementation.
#[derive(Default)]
pub struct MemoryRelay {
    groups: BTreeMap<String, Vec<Vec<u8>>>,
    mailboxes: BTreeMap<String, MailboxItem>,
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
    ) -> Result<u64, AppendError> {
        let log = self.groups.entry(group.to_owned()).or_default();
        let tail = log.len() as u64;
        if tail != expected_tail {
            return Err(AppendError::Conflict { tail });
        }
        log.push(blob);
        Ok(tail + 1)
    }

    fn read_after(&self, group: &str, after: u64) -> Vec<(u64, Vec<u8>)> {
        let Some(log) = self.groups.get(group) else {
            return Vec::new();
        };
        let skip = usize::try_from(after).unwrap_or(usize::MAX);
        log.iter()
            .enumerate()
            .skip(skip)
            .map(|(index, blob)| (index as u64 + 1, blob.clone()))
            .collect()
    }

    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem) {
        self.mailboxes.insert(mailbox.to_owned(), item);
    }

    fn take_mailbox(&mut self, mailbox: &str) -> Option<MailboxItem> {
        self.mailboxes.remove(mailbox)
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
            Err(AppendError::Conflict { tail: 2 })
        );
        assert_eq!(
            relay.read_after("g", 0),
            vec![(1, b"a".to_vec()), (2, b"b".to_vec())]
        );
        assert_eq!(relay.read_after("g", 1), vec![(2, b"b".to_vec())]);
        assert!(relay.read_after("g", 2).is_empty());
        assert!(relay.read_after("unknown", 0).is_empty());
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
        relay.put_mailbox("m", item.clone());
        assert_eq!(relay.take_mailbox("m"), Some(item));
        assert_eq!(relay.take_mailbox("m"), None);
    }
}
