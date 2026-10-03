use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{MailboxItem, MemoryRelay, Peer, Relay, RelayError};

// Simulates an unavailable old prefix without deleting any real relay data or
// adding a production prune capability. Absolute sequence numbers stay intact.
struct MissingPrefixRelay {
    inner: MemoryRelay,
    floor: u64,
}

impl Relay for MissingPrefixRelay {
    fn append(&mut self, group: &str, tail: u64, blob: Vec<u8>) -> Result<u64, RelayError> {
        self.inner.append(group, tail, blob)
    }
    fn read_after(&self, group: &str, after: u64) -> Result<Vec<(u64, Vec<u8>)>, RelayError> {
        if after < self.floor {
            return Err(RelayError::Unavailable("old prefix unavailable".into()));
        }
        self.inner.read_after(group, after)
    }
    fn put_mailbox(&mut self, mailbox: &str, item: MailboxItem) -> Result<(), RelayError> {
        self.inner.put_mailbox(mailbox, item)
    }
    fn take_mailbox(&mut self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        self.inner.take_mailbox(mailbox)
    }
    fn peek_mailbox(&self, mailbox: &str) -> Result<Option<MailboxItem>, RelayError> {
        self.inner.peek_mailbox(mailbox)
    }
    fn acknowledge_mailbox(&mut self, mailbox: &str) -> Result<(), RelayError> {
        self.inner.acknowledge_mailbox(mailbox)
    }
}

#[test]
fn missing_relay_prefix_requires_fresh_keys_and_peer_signed_history_not_cursor_skipping() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MissingPrefixRelay {
        inner: MemoryRelay::default(),
        floor: 0,
    };
    let mut alice = Peer::new("alice", usd.clone()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob", usd.clone()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    bob.write(
        1,
        EventKind::AccountOpened {
            account_id: AccountId::new("early-offline"),
            name: "Signed early backup history".into(),
            currency: usd.clone(),
        },
    )
    .unwrap();
    let stale_backup = bob.export().unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    alice
        .write(
            1000,
            EventKind::AccountOpened {
                account_id: AccountId::new("later"),
                name: "Later retained history".into(),
                currency: usd.clone(),
            },
        )
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    // Exports model confirmed saves here, not OS-backed durability evidence.
    let receipts = vec![
        Peer::saved_state_receipt(&alice.export().unwrap()).unwrap(),
        Peer::saved_state_receipt(&bob.export().unwrap()).unwrap(),
    ];
    assert!(alice.retention_cutoff(&receipts[..1]).is_err());
    relay.floor = alice.retention_cutoff(&receipts).unwrap();
    let mut stale = Peer::import(&stale_backup).unwrap();
    assert!(stale.cursor() < relay.floor);
    let before = stale.export().unwrap();
    let tail = relay.inner.len(&group);
    assert!(stale.sync(&mut relay).is_err());
    assert_eq!(stale.export().unwrap(), before);
    assert_eq!(relay.inner.len(&group), tail);

    // A current peer retires the stale device, then sends a fresh Welcome and
    // original signed history in the new epoch. Never export Alice's keys.
    alice.remove(&mut relay, "bob").unwrap();
    let mut replacement = Peer::new("replacement", usd).unwrap();
    assert_ne!(replacement.public_key(), stale.public_key());
    let mailbox = alice
        .invite(&mut relay, &replacement.key_package().unwrap())
        .unwrap();
    replacement.accept(&mut relay, &group, &mailbox).unwrap();
    assert!(replacement.cursor() > relay.floor);
    assert!(alice.retention_cutoff(&receipts).is_err());
    replacement.merge_recovery_history(&stale_backup).unwrap();
    // Restart before the pending signed backfill is delivered.
    let mut alice = Peer::import(&alice.export().unwrap()).unwrap();
    let mut replacement = Peer::import(&replacement.export().unwrap()).unwrap();
    alice.sync(&mut relay).unwrap();
    replacement.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert_eq!(
        replacement.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
    assert_eq!(replacement.state().ledger.accounts.len(), 2);
    assert!(stale.sync(&mut relay).is_err());
}

#[test]
fn an_old_backup_must_not_reuse_a_sender_ratchet_after_later_sends() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice", usd.clone()).unwrap();
    alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob", usd).unwrap();
    let request = bob.key_package().unwrap();
    let mailbox = alice.invite(&mut relay, &request).unwrap();
    bob.accept(&mut relay, alice.group_id().unwrap(), &mailbox)
        .unwrap();
    let backup = bob.export().unwrap();
    bob.write(
        1,
        EventKind::AccountOpened {
            account_id: AccountId::new("later"),
            name: "After backup".into(),
            currency: Currency::from_code("USD").unwrap(),
        },
    )
    .unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    drop(bob);
    let mut stale = Peer::import(&backup).unwrap();
    // Never skip own ciphertext or rewind its sender ratchet. Recover using
    // a newly invited identity, after retiring the old device.
    assert!(stale.sync(&mut relay).is_err());
    assert!(stale.merge_recovery_history(&backup).is_err());
    let mut replacement = Peer::new("replacement", Currency::from_code("USD").unwrap()).unwrap();
    assert_ne!(replacement.public_key(), stale.public_key());
    assert!(replacement.merge_recovery_history(&backup).is_err());
    alice.remove(&mut relay, "bob").unwrap();
    let request = replacement.key_package().unwrap();
    let mailbox = alice.invite(&mut relay, &request).unwrap();
    replacement
        .accept(&mut relay, alice.group_id().unwrap(), &mailbox)
        .unwrap();
    replacement.merge_recovery_history(&backup).unwrap();
    alice.sync(&mut relay).unwrap(); // Fresh invitation's queued history backfill.
    replacement.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert_eq!(
        replacement.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
}

#[test]
fn recovery_preserves_unsent_signed_history_and_refuses_an_unretired_device() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice", usd.clone()).unwrap();
    alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob", usd.clone()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, alice.group_id().unwrap(), &mailbox)
        .unwrap();
    bob.write(
        10,
        EventKind::AccountOpened {
            account_id: AccountId::new("offline"),
            name: "Only in backup".into(),
            currency: usd.clone(),
        },
    )
    .unwrap();
    let backup = bob.export().unwrap();
    let mut too_early = Peer::new("early-replacement", usd.clone()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &too_early.key_package().unwrap())
        .unwrap();
    too_early
        .accept(&mut relay, alice.group_id().unwrap(), &mailbox)
        .unwrap();
    let unchanged = too_early.state().canonical_bytes();
    assert!(!too_early.merge_recovery_history(&backup).unwrap());
    assert_eq!(too_early.state().canonical_bytes(), unchanged);
    alice.remove(&mut relay, "bob").unwrap();
    let mut replacement = Peer::new("replacement", usd).unwrap();
    let mailbox = alice
        .invite(&mut relay, &replacement.key_package().unwrap())
        .unwrap();
    replacement
        .accept(&mut relay, alice.group_id().unwrap(), &mailbox)
        .unwrap();
    replacement.merge_recovery_history(&backup).unwrap();
    assert_eq!(replacement.pending_count(), 1);
    replacement.merge_recovery_history(&backup).unwrap();
    assert_eq!(replacement.pending_count(), 1);
    let mut replacement = Peer::import(&replacement.export().unwrap()).unwrap();
    replacement.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert_eq!(
        replacement.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
    assert_eq!(replacement.state().ledger.accounts.len(), 1);
    let mut damaged = backup.clone();
    damaged[0] ^= 1;
    let before = replacement.export().unwrap();
    assert!(replacement.merge_recovery_history(&damaged).is_err());
    assert_eq!(replacement.export().unwrap(), before);
}

#[test]
fn matching_relay_labels_cannot_move_recovery_history_between_mls_groups() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut original = Peer::new("original", usd.clone()).unwrap();
    let label = original.found(&mut relay).unwrap();
    let archive = original.export().unwrap();
    let mut other = Peer::new("other", usd.clone()).unwrap();
    other.found(&mut relay).unwrap();
    let mut replacement = Peer::new("replacement", usd).unwrap();
    let invite = other
        .begin_invite(&replacement.key_package().unwrap())
        .unwrap();
    replacement.join(&label, &invite.welcome, 0).unwrap();
    let before = replacement.export().unwrap();
    assert!(replacement.merge_recovery_history(&archive).is_err());
    assert_eq!(replacement.export().unwrap(), before);
}
