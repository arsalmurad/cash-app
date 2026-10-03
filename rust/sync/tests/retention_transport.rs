//! Explicit receipt exchange only: no automatic ACK loop or relay deletion.
use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{MemoryRelay, Peer};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn pair() -> (MemoryRelay, Peer, Peer) {
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice-private-device", usd()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob-private-device", usd()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    (relay, alice, bob)
}

#[test]
fn encrypted_receipts_confirm_saved_history_without_changing_money_or_looping() {
    let (mut relay, mut alice, mut bob) = pair();
    alice
        .write(
            10,
            EventKind::AccountOpened {
                account_id: AccountId::new("shared"),
                name: "Only household members read this".into(),
                currency: usd(),
            },
        )
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    let before = alice.state().canonical_bytes();
    let cursor = alice.cursor();
    let saved_alice = alice.export().unwrap();
    let saved_bob = bob.export().unwrap();
    let receipt = Peer::saved_state_receipt(&saved_alice).unwrap();
    alice.enqueue_saved_state_receipt(&saved_alice).unwrap();
    bob.enqueue_saved_state_receipt(&saved_bob).unwrap();
    assert!(
        alice
            .retention_cutoff(&alice.received_retention_receipts())
            .is_err()
    );
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    for peer in [&alice, &bob] {
        assert_eq!(peer.state().canonical_bytes(), before);
        assert_eq!(peer.pending_count(), 0);
        let receipts = peer.received_retention_receipts();
        assert_eq!(receipts.len(), 2);
        assert_eq!(peer.retention_cutoff(&receipts).unwrap(), cursor);
    }
    let tail = relay.len(alice.group_id().unwrap());
    for _ in 0..3 {
        alice.sync(&mut relay).unwrap();
        bob.sync(&mut relay).unwrap();
    }
    assert_eq!(
        relay.len(alice.group_id().unwrap()),
        tail,
        "No ACK-of-ACK loop"
    );
    assert!(
        relay
            .raw_storage()
            .iter()
            .all(|blob| !blob.windows(receipt.len()).any(|part| part == receipt))
    );
}

#[test]
fn a_queued_receipt_survives_restart_but_collected_receipts_fail_closed_on_restart() {
    let (mut relay, mut alice, mut bob) = pair();
    let saved_alice = alice.export().unwrap();
    alice.enqueue_saved_state_receipt(&saved_alice).unwrap();
    let queued = alice.export().unwrap();
    assert!(queued.starts_with(b"cash-app peer v6\0"));
    alice = Peer::import(&queued).unwrap();
    assert_eq!(alice.pending_count(), 1);
    assert_eq!(alice.export().unwrap(), queued);
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    let checkpoint = alice.export().unwrap();
    assert!(
        checkpoint.starts_with(b"cash-app peer v5\0"),
        "Normal archives retain the existing format"
    );
    alice = Peer::import(&checkpoint).unwrap();
    assert!(alice.received_retention_receipts().is_empty());
    assert!(
        alice
            .retention_cutoff(&alice.received_retention_receipts())
            .is_err()
    );
    // Collect fresh explicit receipts rather than infer them from a cursor.
    alice.enqueue_saved_state_receipt(&checkpoint).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert!(
        alice
            .retention_cutoff(&alice.received_retention_receipts())
            .is_ok()
    );
}

#[test]
fn live_unsaved_work_and_another_devices_archive_cannot_queue_a_receipt() {
    let (_, mut alice, bob) = pair();
    let saved = alice.export().unwrap();
    assert!(
        alice
            .enqueue_saved_state_receipt(&bob.export().unwrap())
            .is_err()
    );
    alice
        .write(
            1,
            EventKind::AccountOpened {
                account_id: AccountId::new("offline"),
                name: "Not saved or sent".into(),
                currency: usd(),
            },
        )
        .unwrap();
    let before = alice.export().unwrap();
    assert!(alice.enqueue_saved_state_receipt(&saved).is_err());
    assert_eq!(alice.export().unwrap(), before);
}

#[test]
fn membership_changes_clear_collections_and_old_saved_checkpoints_cannot_be_queued() {
    let (mut relay, mut alice, mut bob) = pair();
    let old = alice.export().unwrap();
    bob.write(
        1,
        EventKind::AccountOpened {
            account_id: AccountId::new("new-history"),
            name: "Changed checkpoint".into(),
            currency: usd(),
        },
    )
    .unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    let before = alice.export().unwrap();
    assert!(alice.enqueue_saved_state_receipt(&old).is_err());
    assert_eq!(alice.export().unwrap(), before);
    alice.enqueue_saved_state_receipt(&before).unwrap();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    let receipts = alice.received_retention_receipts();
    assert_eq!(receipts.len(), 2);
    alice.remove(&mut relay, bob.member_id()).unwrap();
    bob.sync(&mut relay).unwrap();
    assert!(alice.received_retention_receipts().is_empty());
    assert!(bob.received_retention_receipts().is_empty());
    assert!(alice.retention_cutoff(&receipts).is_err());
}

#[test]
fn queued_receipt_tampering_and_format_downgrade_fail_closed() {
    let (_, mut alice, _) = pair();
    let saved = alice.export().unwrap();
    let receipt = Peer::saved_state_receipt(&saved).unwrap();
    alice.enqueue_saved_state_receipt(&saved).unwrap();
    let queued = alice.export().unwrap();
    let start = queued
        .windows(receipt.len())
        .position(|part| part == receipt)
        .unwrap();
    let mut tampered = queued.clone();
    tampered[start + receipt.len() - 1] ^= 1;
    assert!(Peer::import(&tampered).is_err());
    let mut downgrade = queued;
    let header = b"cash-app peer v5\0";
    downgrade[..header.len()].copy_from_slice(header);
    assert!(Peer::import(&downgrade).is_err());
}

#[test]
fn an_old_saved_ratchet_cannot_be_queued_even_when_financial_history_matches() {
    let (mut relay, mut alice, mut bob) = pair();
    let old = alice.export().unwrap();
    let state = alice.state().canonical_bytes();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert_eq!(alice.state().canonical_bytes(), state);
    let current = alice.export().unwrap();
    assert_ne!(
        current, old,
        "Only control traffic advanced the receiver state"
    );
    assert!(alice.enqueue_saved_state_receipt(&old).is_err());
    assert_eq!(alice.export().unwrap(), current);
}
