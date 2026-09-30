//! The step interface: what the app drives when the network lives in Dart.
//! These tests play the part of the transport with a bare vector, never
//! touching the `Relay` trait, so the state machine is checked on its own.

use cash_core::{AccountId, Currency, EventKind, FxRate, Money, TransactionId, TransactionKind};
use cash_sync::Peer;

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

/// The transport's whole job: an ordered log with compare-and-swap.
#[derive(Default)]
struct Log(Vec<Vec<u8>>);

impl Log {
    fn append(&mut self, expected_tail: u64, blob: Vec<u8>) -> Result<u64, u64> {
        if self.0.len() as u64 != expected_tail {
            return Err(self.0.len() as u64);
        }
        self.0.push(blob);
        Ok(self.0.len() as u64)
    }

    fn after(&self, cursor: u64) -> Vec<(u64, Vec<u8>)> {
        self.0
            .iter()
            .enumerate()
            .skip(cursor as usize)
            .map(|(index, blob)| (index as u64 + 1, blob.clone()))
            .collect()
    }
}

/// Push everything a peer has queued, the way the app's sync loop will.
fn flush(peer: &mut Peer, log: &mut Log) {
    peer.ingest(&log.after(peer.cursor())).unwrap();
    while let Some(out) = peer.next_outgoing().unwrap() {
        match log.append(out.expected_tail, out.blob) {
            Ok(sequence) => peer.outgoing_accepted(sequence).unwrap(),
            Err(_) => peer.ingest(&log.after(peer.cursor())).unwrap(),
        }
    }
}

fn household() -> (Log, Peer, Peer) {
    let mut log = Log::default();
    let mut alice = Peer::new("alice-laptop", usd()).unwrap();
    let mut bob = Peer::new("bob-phone", usd()).unwrap();
    let group = alice.found_group().unwrap();
    assert_eq!(alice.group_id(), Some(group.as_str()));

    let invite = alice.begin_invite(&bob.key_package().unwrap()).unwrap();
    let sequence = log
        .append(invite.commit.expected_tail, invite.commit.blob)
        .unwrap();
    alice.commit_accepted(sequence).unwrap();
    bob.join(&group, &invite.welcome, sequence).unwrap();
    (log, alice, bob)
}

#[test]
fn two_peers_converge_by_stepping_a_bare_log() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 90_000)).unwrap();
    bob.write(3, expense("coffee", 450)).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    flush(&mut alice, &mut log);

    assert_eq!(alice.state().ledger.transactions.len(), 2);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
    assert_eq!(alice.cursor(), bob.cursor());
}

#[test]
fn losing_the_append_race_means_ingest_then_try_again() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    bob.write(2, expense("coffee", 450)).unwrap();

    // Both encrypt against the same tail; Alice's lands first.
    let from_alice = alice.next_outgoing().unwrap().unwrap();
    let from_bob = bob.next_outgoing().unwrap().unwrap();
    assert_eq!(from_alice.expected_tail, from_bob.expected_tail);
    let sequence = log
        .append(from_alice.expected_tail, from_alice.blob)
        .unwrap();
    alice.outgoing_accepted(sequence).unwrap();
    assert!(log.append(from_bob.expected_tail, from_bob.blob).is_err());

    // Bob catches up and re-sends the same event; nothing is duplicated.
    bob.ingest(&log.after(bob.cursor())).unwrap();
    let retry = bob.next_outgoing().unwrap().unwrap();
    assert_eq!(retry.expected_tail, bob.cursor());
    let sequence = log.append(retry.expected_tail, retry.blob).unwrap();
    bob.outgoing_accepted(sequence).unwrap();
    assert!(bob.next_outgoing().unwrap().is_none());

    flush(&mut alice, &mut log);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
    assert_eq!(alice.state().ledger.transactions.len(), 1);
}

#[test]
fn a_rejected_commit_is_discarded_and_the_group_keeps_working() {
    let (mut log, mut alice, mut bob) = household();
    let carol = Peer::new("carol-tablet", usd()).unwrap();
    alice.write(1, account()).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);

    // Bob slips a message in first, so Alice's staged commit is stale.
    bob.write(2, expense("coffee", 450)).unwrap();
    flush(&mut bob, &mut log);
    let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    assert!(
        log.append(invite.commit.expected_tail, invite.commit.blob)
            .is_err()
    );
    alice.commit_rejected().unwrap();

    // Alice catches up and can still read and write.
    alice.ingest(&log.after(alice.cursor())).unwrap();
    assert_eq!(alice.state().ledger.transactions.len(), 1);
    alice.write(3, expense("lunch", 900)).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
}

#[test]
fn a_staged_commit_blocks_reads_and_writes_until_it_is_resolved() {
    let (log, mut alice, _bob) = household();
    let carol = Peer::new("carol-tablet", usd()).unwrap();
    alice.begin_invite(&carol.key_package().unwrap()).unwrap();

    assert!(alice.next_outgoing().unwrap_err().0.contains("pending"));
    assert!(alice.ingest(&log.after(alice.cursor())).is_err());
    assert!(alice.begin_removal("bob-phone").is_err());
    alice.commit_rejected().unwrap();
    assert!(alice.next_outgoing().unwrap().is_none());
}

#[test]
fn removal_is_a_staged_commit_too() {
    let (mut log, mut alice, mut bob) = household();
    let out = alice.begin_removal("bob-phone").unwrap();
    let sequence = log.append(out.expected_tail, out.blob).unwrap();
    alice.commit_accepted(sequence).unwrap();

    bob.ingest(&log.after(bob.cursor())).unwrap();
    assert!(!bob.is_member());
    assert!(bob.write(9, expense("nope", 1)).is_err());
}

#[test]
fn ingest_skips_what_it_has_seen_and_refuses_a_gap() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 1)).unwrap();
    flush(&mut alice, &mut log);

    let entries = log.after(bob.cursor());
    bob.ingest(&entries).unwrap();
    // Replaying the same entries is harmless.
    bob.ingest(&entries).unwrap();
    assert_eq!(bob.state().ledger.transactions.len(), 1);

    // Entries that skip a sequence number would desynchronise MLS: refused.
    alice.write(3, expense("more", 1)).unwrap();
    flush(&mut alice, &mut log);
    alice.write(4, expense("evenmore", 1)).unwrap();
    flush(&mut alice, &mut log);
    let gap = log.after(bob.cursor() + 1);
    assert!(bob.ingest(&gap).is_err());
    bob.ingest(&log.after(bob.cursor())).unwrap();
    assert_eq!(bob.state().ledger.transactions.len(), 3);
}

#[test]
fn staged_state_survives_nothing_but_a_clean_export_is_refused_while_staged() {
    let (_, mut alice, _) = household();
    let carol = Peer::new("carol-tablet", usd()).unwrap();
    alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    // Exporting mid-commit would persist a half-applied group; make the
    // caller resolve it first.
    assert!(alice.export().is_err());
    alice.commit_rejected().unwrap();
    assert!(alice.export().is_ok());
}
