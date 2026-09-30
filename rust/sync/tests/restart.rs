//! A peer must survive its app being killed: group keys, what it has seen,
//! its place in the relay log, and anything it wrote but had not yet sent.

use cash_core::{AccountId, Currency, EventKind, FxRate, Money, TransactionId, TransactionKind};
use cash_sync::{MemoryRelay, Peer};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn account() -> EventKind {
    EventKind::AccountOpened {
        account_id: AccountId::new("joint"),
        name: "Joint".to_owned(),
        currency: usd(),
    }
}

fn expense(id: &str, minor: i64) -> EventKind {
    EventKind::TransactionRecorded {
        transaction_id: TransactionId::new(id),
        account_id: AccountId::new("joint"),
        kind: TransactionKind::Expense,
        original: Money::new(minor, usd()),
        reporting_fx: FxRate::identity(usd()),
        title: id.to_owned(),
        category_id: None,
        recurring_id: None,
    }
}

fn pair() -> (MemoryRelay, String, Peer, Peer) {
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice-laptop", usd()).unwrap();
    let mut bob = Peer::new("bob-phone", usd()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let key_package = bob.key_package().unwrap();
    let mailbox = alice.invite(&mut relay, &key_package).unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    (relay, group, alice, bob)
}

#[test]
fn a_restarted_peer_resumes_with_its_state_its_place_and_its_unsent_writes() {
    let (mut relay, _, mut alice, mut bob) = pair();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 90_000)).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();

    // Bob writes while offline, then his app is killed before he syncs.
    bob.write(3, expense("coffee", 450)).unwrap();
    let saved = bob.export().unwrap();
    drop(bob);
    let mut bob = Peer::import(&saved).unwrap();
    assert_eq!(bob.member_id(), "bob-phone");
    assert!(bob.is_member());
    assert_eq!(bob.state().ledger.transactions.len(), 2);

    // The unsent write survives and is delivered; new traffic is readable.
    alice.write(4, expense("lunch", 1_200)).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();

    assert_eq!(bob.state().ledger.transactions.len(), 3);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );

    // The hybrid clock also survives: Bob's next event sorts after
    // everything he has seen, even with a wall clock far in the past.
    let next = bob.write(0, expense("late", 1)).unwrap();
    assert!(next.event.timestamp.physical_millis >= 4);
}

#[test]
fn a_restart_between_every_step_changes_nothing() {
    let (mut relay, _, mut alice, mut bob) = pair();
    alice.write(1, account()).unwrap();
    for round in 0..10 {
        alice
            .write(10 + round, expense(&format!("a{round}"), 100))
            .unwrap();
        bob.write(10 + round, expense(&format!("b{round}"), 200))
            .unwrap();
        alice.sync(&mut relay).unwrap();
        bob = Peer::import(&bob.export().unwrap()).unwrap();
        bob.sync(&mut relay).unwrap();
        alice = Peer::import(&alice.export().unwrap()).unwrap();
    }
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    assert_eq!(alice.state().ledger.transactions.len(), 20);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
}

#[test]
fn a_removed_peer_stays_removed_after_a_restart() {
    let (mut relay, _, mut alice, mut bob) = pair();
    alice.remove(&mut relay, "bob-phone").unwrap();
    bob.sync(&mut relay).unwrap();
    assert!(!bob.is_member());

    let bob = Peer::import(&bob.export().unwrap()).unwrap();
    assert!(!bob.is_member());
}

#[test]
fn damaged_saved_state_is_rejected() {
    let (_, _, alice, _) = pair();
    let saved = alice.export().unwrap();
    assert!(Peer::import(b"nonsense").is_err());
    assert!(Peer::import(&saved[..saved.len() - 1]).is_err());
    let mut trailing = saved;
    trailing.push(0);
    assert!(Peer::import(&trailing).is_err());
}
