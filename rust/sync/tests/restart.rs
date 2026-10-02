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
fn persisted_checkpoint_is_checked_and_previous_signed_archives_remain_readable() {
    let (mut relay, _, mut alice, _) = pair();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("checkpoint-rent", 123)).unwrap();
    alice.sync(&mut relay).unwrap();
    let saved = alice.export().unwrap();
    assert!(saved.starts_with(b"cash-app peer v4\0"));
    let restored = Peer::import(&saved).unwrap();
    assert_eq!(restored.state(), alice.state());
    let mut damaged = saved.clone();
    *damaged.last_mut().unwrap() ^= 1;
    assert!(
        Peer::import(&damaged).is_err(),
        "A cached state must not override signed history"
    );
    let marker = b"cash-app shared checkpoint v1\0";
    let offset = saved
        .windows(marker.len())
        .rposition(|window| window == marker)
        .unwrap();
    let mut wrong_frontier = saved.clone();
    // Descriptor magic, actor count, then the first actor's string length.
    let first_actor = offset + marker.len() + 8 + 8;
    wrong_frontier[first_actor] ^= 1;
    assert!(
        Peer::import(&wrong_frontier).is_err(),
        "A frontier must match authenticated retained events"
    );
    let mut v3 = saved[..offset - 8].to_vec();
    v3[..b"cash-app peer v3\0".len()].copy_from_slice(b"cash-app peer v3\0");
    assert_eq!(Peer::import(&v3).unwrap().state(), alice.state());
    // This fixture has no staged commit; v2 ended before that v3 flag.
    assert_eq!(v3.pop(), Some(0));
    v3[..b"cash-app peer v2\0".len()].copy_from_slice(b"cash-app peer v2\0");
    assert_eq!(Peer::import(&v3).unwrap().state(), alice.state());
}

#[test]
fn persisted_checkpoint_accepts_a_late_offline_peer_event_without_losing_history() {
    let (mut relay, _, mut alice, mut bob) = pair();
    alice.write(1, account()).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.write(1000, expense("alice-newer", 100)).unwrap();
    alice.sync(&mut relay).unwrap();
    alice = Peer::import(&alice.export().unwrap()).unwrap();
    let older = bob.write(20, expense("bob-offline", 200)).unwrap();
    assert_eq!(older.event.timestamp.physical_millis, 20);
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    assert_eq!(alice.state().ledger.reporting_balance_minor, -300);
    assert_eq!(alice.state(), bob.state());
    let restarted = Peer::import(&alice.export().unwrap()).unwrap();
    assert_eq!(restarted.state(), bob.state());
    assert_eq!(restarted.state().ledger.transactions.len(), 2);
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

#[test]
fn signed_v2_state_is_upgraded_without_changing_its_ledger() {
    let (_, _, mut alice, _) = pair();
    alice.write(1, account()).unwrap();
    let canonical = alice.state().canonical_bytes();
    let mut saved = alice.export().unwrap();
    let marker = b"cash-app shared checkpoint v1\0";
    let offset = saved
        .windows(marker.len())
        .rposition(|window| window == marker)
        .unwrap();
    saved.truncate(offset - 8); // v4's checked checkpoint field.
    assert_eq!(saved.pop(), Some(0)); // v3's absent pending-commit journal.
    saved[..b"cash-app peer v2\0".len()].copy_from_slice(b"cash-app peer v2\0");
    let upgraded = Peer::import(&saved).unwrap();
    assert_eq!(upgraded.state().canonical_bytes(), canonical);
    assert!(
        upgraded
            .export()
            .unwrap()
            .starts_with(b"cash-app peer v4\0")
    );
}

#[test]
fn a_lost_device_is_restored_from_the_sealed_backup_and_the_written_phrase() {
    use cash_crypto::RecoveryKey;

    let (mut relay, _, mut alice, mut bob) = pair();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 90_000)).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();

    // Bob writes the phrase down and the app stores a sealed backup in the
    // cloud. Then the phone is lost: only the phrase and the backup remain.
    let phrase = RecoveryKey::generate();
    let written_down = phrase.phrase();
    let backup = phrase.seal(&bob.export().unwrap()).unwrap();
    assert!(!backup.windows(9).any(|window| window == b"bob-phone"));
    drop(bob);

    // Meanwhile the household keeps going.
    alice.write(3, expense("groceries", 8_000)).unwrap();
    alice.sync(&mut relay).unwrap();

    // On a new phone: type the phrase, open the backup, carry on.
    let key = RecoveryKey::from_phrase(&written_down).unwrap();
    let mut bob = Peer::import(&key.open(&backup).unwrap()).unwrap();
    bob.sync(&mut relay).unwrap();
    bob.write(4, expense("coffee", 450)).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();

    assert_eq!(bob.state().ledger.transactions.len(), 3);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );

    // A wrong phrase opens nothing.
    assert!(RecoveryKey::generate().open(&backup).is_err());
}
