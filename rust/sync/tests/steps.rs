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
fn a_staged_commit_allows_reconciliation_but_blocks_new_mutations() {
    let (log, mut alice, _bob) = household();
    let carol = Peer::new("carol-tablet", usd()).unwrap();
    let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();

    assert_eq!(alice.next_outgoing().unwrap(), Some(invite.commit));
    assert!(alice.ingest(&log.after(alice.cursor())).is_ok());
    assert!(alice.begin_removal("bob-phone").is_err());
    alice.commit_rejected().unwrap();
    assert!(alice.next_outgoing().unwrap().is_none());
}

#[test]
fn malformed_log_evidence_does_not_discard_a_pending_commit() {
    let (_, mut alice, _) = household();
    let carol = Peer::new("carol", usd()).unwrap();
    let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    assert!(
        alice
            .ingest(&[(alice.cursor() + 1, b"garbage".to_vec())])
            .is_err()
    );
    assert_eq!(alice.next_outgoing().unwrap(), Some(invite.commit));
}

#[test]
fn a_commit_ack_cannot_skip_its_reserved_slot() {
    let (_, mut alice, _) = household();
    let pending = alice.begin_removal("bob-phone").unwrap();
    assert!(alice.commit_accepted(pending.expected_tail + 2).is_err());
    assert_eq!(alice.next_outgoing().unwrap(), Some(pending));
}

#[test]
fn a_removal_with_a_lost_reply_survives_restart_and_rotates_keys() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    let pending = alice.begin_removal("bob-phone").unwrap();
    let saved = alice.export().unwrap();
    log.append(pending.expected_tail, pending.blob).unwrap();
    alice = Peer::import(&saved).unwrap();
    alice.ingest(&log.after(alice.cursor())).unwrap();
    alice.write(2, expense("after removal", 100)).unwrap();
    flush(&mut alice, &mut log);
    bob.ingest(&log.after(bob.cursor())).unwrap();
    assert!(!bob.is_member());
    assert!(bob.try_decrypt(log.0.last().unwrap()).is_err());
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
fn a_staged_commit_survives_restart_before_submission() {
    let (_, mut alice, _) = household();
    let carol = Peer::new("carol-tablet", usd()).unwrap();
    let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    alice = Peer::import(&alice.export().unwrap()).unwrap();
    assert_eq!(alice.next_outgoing().unwrap(), Some(invite.commit));
    alice.commit_rejected().unwrap();
    assert!(alice.export().is_ok());
}

#[test]
fn a_lost_commit_ack_is_resolved_from_the_log_after_restart() {
    let (mut log, mut alice, mut bob) = household();
    let mut carol = Peer::new("carol", usd()).unwrap();
    let group = alice.group_id().unwrap().to_owned();
    let invite = alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    let saved = alice.export().unwrap();
    let sequence = log
        .append(invite.commit.expected_tail, invite.commit.blob)
        .unwrap();
    // Response lost: restore the exact pre-submit journal, not a merged epoch.
    alice = Peer::import(&saved).unwrap();
    alice.ingest(&log.after(alice.cursor())).unwrap();
    carol.join(&group, &invite.welcome, sequence).unwrap();
    alice.write(1, account()).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    flush(&mut carol, &mut log);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
    assert_eq!(
        alice.state().canonical_bytes(),
        carol.state().canonical_bytes()
    );
}

#[test]
fn a_competing_frame_resolves_a_saved_unaccepted_commit() {
    let (mut log, mut alice, mut bob) = household();
    let carol = Peer::new("carol", usd()).unwrap();
    alice.begin_invite(&carol.key_package().unwrap()).unwrap();
    let saved = alice.export().unwrap();
    bob.write(1, account()).unwrap();
    flush(&mut bob, &mut log);
    alice = Peer::import(&saved).unwrap();
    alice.ingest(&log.after(alice.cursor())).unwrap();
    alice.write(2, expense("after conflict", 100)).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
    assert_eq!(alice.member_keys().unwrap().len(), 2);
}

/// Adds `joiner` to an existing household the way the app does, returning
/// nothing: the commit is appended and the welcome consumed.
fn add_member(log: &mut Log, adder: &mut Peer, joiner: &mut Peer, group: &str) {
    let invite = adder.begin_invite(&joiner.key_package().unwrap()).unwrap();
    let sequence = log
        .append(invite.commit.expected_tail, invite.commit.blob)
        .unwrap();
    adder.commit_accepted(sequence).unwrap();
    joiner.join(group, &invite.welcome, sequence).unwrap();
}

#[test]
fn a_member_added_later_receives_the_history_written_before_they_joined() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 90_000)).unwrap();
    bob.write(3, expense("coffee", 450)).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    flush(&mut alice, &mut log);
    assert_eq!(alice.state().ledger.transactions.len(), 2);

    // Carol joins afterwards. MLS gives her nothing written before her
    // commit, so the inviter must backfill it.
    let mut carol = Peer::new("carol-tablet", usd()).unwrap();
    let group = alice.group_id().unwrap().to_owned();
    add_member(&mut log, &mut alice, &mut carol, &group);
    flush(&mut alice, &mut log);
    flush(&mut carol, &mut log);
    flush(&mut bob, &mut log);

    assert_eq!(carol.state().ledger.transactions.len(), 2);
    assert_eq!(carol.state().ledger.accounts.len(), 1);
    for peer in [&alice, &bob] {
        assert_eq!(
            peer.state().canonical_bytes(),
            carol.state().canonical_bytes()
        );
    }

    // And Carol can write on top of that history: her edit finds the
    // account and the expense it refers to.
    carol
        .write(
            4,
            EventKind::AmountAdjusted {
                transaction_id: TransactionId::new("rent"),
                original: Money::new(91_000, usd()),
                reporting_fx: FxRate::identity(usd()),
            },
        )
        .unwrap();
    flush(&mut carol, &mut log);
    flush(&mut alice, &mut log);
    assert_eq!(
        alice.state().canonical_bytes(),
        carol.state().canonical_bytes()
    );
    assert!(alice.state().rejected.is_empty());
}

#[test]
fn a_long_history_is_backfilled_in_batches_with_nothing_missing() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    for index in 0..700 {
        alice
            .write(2 + index, expense(&format!("t{index}"), 100 + index))
            .unwrap();
    }
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);

    let before = log.0.len();
    let mut carol = Peer::new("carol-tablet", usd()).unwrap();
    let group = alice.group_id().unwrap().to_owned();
    add_member(&mut log, &mut alice, &mut carol, &group);
    flush(&mut alice, &mut log);
    flush(&mut carol, &mut log);

    assert_eq!(carol.state().ledger.transactions.len(), 700);
    assert_eq!(
        carol.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
    // Batching: the commit plus a handful of batches, not one entry per
    // event (701 events in batches of at most 200).
    let added = log.0.len() - before;
    assert!(added <= 10, "{added} log entries for the backfill");
}

#[test]
fn a_pending_backfill_survives_a_restart_of_the_inviter() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    alice.write(2, expense("rent", 90_000)).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);

    let mut carol = Peer::new("carol-tablet", usd()).unwrap();
    let group = alice.group_id().unwrap().to_owned();
    add_member(&mut log, &mut alice, &mut carol, &group);

    // Alice's app dies after adding Carol but before sending the backfill.
    let mut alice = Peer::import(&alice.export().unwrap()).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut carol, &mut log);
    assert_eq!(carol.state().ledger.transactions.len(), 1);
    assert_eq!(
        carol.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
}

#[test]
fn removing_a_member_does_not_backfill_anything() {
    let (mut log, mut alice, mut bob) = household();
    alice.write(1, account()).unwrap();
    flush(&mut alice, &mut log);
    flush(&mut bob, &mut log);
    let before = log.0.len();
    let out = alice.begin_removal("bob-phone").unwrap();
    let sequence = log.append(out.expected_tail, out.blob).unwrap();
    alice.commit_accepted(sequence).unwrap();
    assert!(alice.next_outgoing().unwrap().is_none());
    assert_eq!(log.0.len(), before + 1);
}
