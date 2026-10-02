//! Retention planning is not permission to prune. Receipts must come from
//! confirmed saved archives; persistence/transport integration is a later gate.
use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{MemoryRelay, Peer};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn account(id: &str) -> EventKind {
    EventKind::AccountOpened {
        account_id: AccountId::new(id),
        name: format!("Private fixture {id}"),
        currency: usd(),
    }
}

fn trio() -> (MemoryRelay, Peer, Peer, Peer) {
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice-device-001", usd()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob-device-002", usd()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    let mut carol = Peer::new("carol-device-003", usd()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &carol.key_package().unwrap())
        .unwrap();
    carol.accept(&mut relay, &group, &mailbox).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    (relay, alice, bob, carol)
}

fn receipt(peer: &Peer) -> Vec<u8> {
    Peer::saved_state_receipt(&peer.export().unwrap()).unwrap()
}

#[test]
fn every_current_member_must_confirm_the_same_saved_history() {
    let (mut relay, mut alice, mut bob, mut carol) = trio();
    alice.write(10, account("joint")).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    let first = receipt(&alice);
    let second = receipt(&bob);
    assert!(
        alice
            .retention_cutoff(&[first.clone(), second.clone()])
            .is_err()
    );
    assert!(
        alice
            .retention_cutoff(&[first.clone(), second.clone(), receipt(&carol)])
            .is_err()
    );
    carol.sync(&mut relay).unwrap();
    let receipts = vec![first, second, receipt(&carol)];
    assert_eq!(alice.retention_cutoff(&receipts).unwrap(), alice.cursor());
    assert_eq!(bob.retention_cutoff(&receipts).unwrap(), alice.cursor());
    assert_eq!(carol.retention_cutoff(&receipts).unwrap(), alice.cursor());
    assert_eq!(
        alice
            .retention_cutoff(&receipts.iter().rev().cloned().collect::<Vec<_>>())
            .unwrap(),
        alice.cursor()
    );
    let stored = alice.export().unwrap();
    let restarted = Peer::import(&stored).unwrap();
    assert_eq!(
        restarted.retention_cutoff(&receipts).unwrap(),
        alice.cursor()
    );
    assert_eq!(
        restarted.export().unwrap(),
        stored,
        "Planning cannot mutate keys or history"
    );
}

#[test]
fn a_saved_receipt_does_not_acknowledge_later_or_older_offline_events() {
    let (mut relay, mut alice, mut bob, mut carol) = trio();
    let old = vec![receipt(&alice), receipt(&bob), receipt(&carol)];
    // Bob's late event sorts before Alice's event, not after its high-water mark.
    bob.write(1, account("late")).unwrap();
    alice.write(100, account("new")).unwrap();
    alice.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    assert!(alice.retention_cutoff(&old).is_err());
    assert!(
        Peer::saved_state_receipt(&bob.export().unwrap()).is_err(),
        "Unsent history cannot acknowledge retention"
    );
    bob.sync(&mut relay).unwrap();
    let before_late = receipt(&alice);
    alice.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    assert!(
        alice
            .retention_cutoff(&[before_late, receipt(&bob), receipt(&carol)])
            .is_err()
    );
    assert_eq!(
        alice
            .retention_cutoff(&[receipt(&alice), receipt(&bob), receipt(&carol)])
            .unwrap(),
        alice.cursor()
    );
}

#[test]
fn invalid_replayed_or_foreign_receipts_cannot_authorize_a_cutoff() {
    let (_, alice, bob, carol) = trio();
    let good = vec![receipt(&alice), receipt(&bob), receipt(&carol)];
    for index in [0, good[1].len() / 2, good[1].len() - 1] {
        let mut bad = good.clone();
        bad[1][index] ^= 1;
        assert!(alice.retention_cutoff(&bad).is_err());
    }
    let mut truncated = good.clone();
    truncated[1].pop();
    assert!(alice.retention_cutoff(&truncated).is_err());
    let mut extended = good.clone();
    extended[1].push(0);
    assert!(alice.retention_cutoff(&extended).is_err());
    let mut other_relay = MemoryRelay::default();
    let mut outsider = Peer::new("alice", usd()).unwrap();
    outsider.found(&mut other_relay).unwrap();
    assert!(
        alice
            .retention_cutoff(&[good[0].clone(), good[1].clone(), receipt(&outsider)])
            .is_err()
    );
    assert!(outsider.retention_cutoff(&good).is_err());
    assert_eq!(
        alice
            .retention_cutoff(&[good.clone(), vec![good[1].clone()]].concat())
            .unwrap(),
        alice.cursor(),
        "Identical receipt replay is idempotent"
    );
    for private in [
        b"alice-device-001".as_slice(),
        b"bob-device-002",
        b"carol-device-003",
        b"Private fixture",
    ] {
        assert!(
            !good
                .iter()
                .any(|bytes| bytes.windows(private.len()).any(|part| part == private))
        );
    }
}

#[test]
fn membership_changes_invalidate_old_receipts_and_require_new_members() {
    let (mut relay, mut alice, mut bob, mut carol) = trio();
    let old = vec![receipt(&alice), receipt(&bob), receipt(&carol)];
    let group = alice.group_id().unwrap().to_owned();
    alice.write(10, account("before-invite")).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    let mut dave = Peer::new("dave-device-004", usd()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &dave.key_package().unwrap())
        .unwrap();
    assert!(
        Peer::saved_state_receipt(&alice.export().unwrap()).is_err(),
        "Queued backfill cannot be acknowledged"
    );
    dave.accept(&mut relay, &group, &mailbox).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    dave.sync(&mut relay).unwrap();
    assert!(alice.retention_cutoff(&old).is_err());
    let receipts = vec![receipt(&alice), receipt(&bob), receipt(&carol)];
    assert!(alice.retention_cutoff(&receipts).is_err());
    assert_eq!(
        alice
            .retention_cutoff(&[receipts, vec![receipt(&dave)]].concat())
            .unwrap(),
        alice.cursor()
    );
    alice.remove(&mut relay, "dave-device-004").unwrap();
    bob.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    dave.sync(&mut relay).unwrap();
    assert!(Peer::saved_state_receipt(&dave.export().unwrap()).is_err());
    let current = vec![receipt(&alice), receipt(&bob), receipt(&carol)];
    assert_eq!(alice.retention_cutoff(&current).unwrap(), alice.cursor());
    assert!(
        alice
            .retention_cutoff(&[current, vec![old[0].clone()]].concat())
            .is_err()
    );
}

#[test]
fn staged_membership_and_invalid_archives_cannot_create_receipts() {
    let (_, mut alice, _, _) = trio();
    alice.begin_removal("bob-device-002").unwrap();
    assert!(Peer::saved_state_receipt(&alice.export().unwrap()).is_err());
    assert!(alice.retention_cutoff(&[]).is_err());
    assert!(Peer::saved_state_receipt(b"not a saved peer").is_err());
    let new = Peer::new("unjoined", usd()).unwrap();
    assert!(Peer::saved_state_receipt(&new.export().unwrap()).is_err());
}
