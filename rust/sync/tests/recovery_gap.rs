use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{MemoryRelay, Peer};

#[test]
fn an_old_backup_must_not_reuse_a_sender_ratchet_after_later_sends() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice", usd.clone()).unwrap();
    alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob", usd).unwrap();
    let request = bob.key_package().unwrap();
    let mailbox = alice.invite(&mut relay, &request).unwrap();
    bob.accept(&mut relay, &alice.group_id().unwrap(), &mailbox)
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
