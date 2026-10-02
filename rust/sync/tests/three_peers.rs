//! The Phase 2 exit test (expense-app-build-brief.md section 6), run against
//! the in-memory reference relay: three peers, two offline for part of the
//! run, 1,000+ interleaved events including concurrent edits to one expense
//! and an edit racing a void, then full reconnection.

use cash_core::{
    AccountId, Currency, EditField, EventKind, FxRate, Money, SharedEvent, TransactionId,
    TransactionKind, fold_shared,
};
use cash_sync::{MemoryRelay, Peer, Relay};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn eur() -> Currency {
    Currency::from_code("EUR").unwrap()
}

struct Lcg(u64);

impl Lcg {
    fn next(&mut self, bound: usize) -> usize {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 33) as usize) % bound
    }
}

struct Household {
    relay: MemoryRelay,
    group: String,
    peers: Vec<Peer>,
    /// Every event any peer ever wrote: the independent reference log.
    written: Vec<SharedEvent>,
    clock: i64,
}

impl Household {
    /// Alice founds the group and invites the rest; everyone syncs.
    fn new(names: &[&str]) -> Self {
        let mut relay = MemoryRelay::default();
        let mut peers: Vec<_> = names
            .iter()
            .map(|name| Peer::new(name, usd()).unwrap())
            .collect();
        let group = peers[0].found(&mut relay).unwrap();
        for index in 1..peers.len() {
            let key_package = peers[index].key_package().unwrap();
            let mailbox = peers[0].invite(&mut relay, &key_package).unwrap();
            peers[index].accept(&mut relay, &group, &mailbox).unwrap();
        }
        for peer in &mut peers {
            peer.sync(&mut relay).unwrap();
        }
        Self {
            relay,
            group,
            peers,
            written: Vec::new(),
            clock: 1_000,
        }
    }

    fn write(&mut self, peer: usize, kind: EventKind) -> SharedEvent {
        self.clock += 1;
        let event = self.peers[peer].write(self.clock, kind).unwrap();
        self.written.push(event.clone());
        event
    }

    fn sync(&mut self, peer: usize) {
        self.peers[peer].sync(&mut self.relay).unwrap();
    }

    fn sync_everyone(&mut self) {
        // Two passes: the first may still be answering each other's writes.
        for _ in 0..2 {
            for index in 0..self.peers.len() {
                if self.peers[index].is_member() {
                    self.sync(index);
                }
            }
        }
    }
}

fn open_account(id: &str, currency: Currency) -> EventKind {
    EventKind::AccountOpened {
        account_id: AccountId::new(id),
        name: format!("{id}-account"),
        currency,
    }
}

fn expense(id: &str, account: &str, minor: i64, currency: Currency, fx: FxRate) -> EventKind {
    EventKind::TransactionRecorded {
        transaction_id: TransactionId::new(id),
        account_id: AccountId::new(account),
        kind: TransactionKind::Expense,
        original: Money::new(minor, currency),
        reporting_fx: fx,
        title: format!("Groceries {id}"),
        category_id: None,
        recurring_id: None,
    }
}

fn adjust(id: &str, minor: i64, currency: Currency, fx: FxRate) -> EventKind {
    EventKind::AmountAdjusted {
        transaction_id: TransactionId::new(id),
        original: Money::new(minor, currency),
        reporting_fx: fx,
    }
}

fn void(id: &str) -> EventKind {
    EventKind::TransactionVoided {
        transaction_id: TransactionId::new(id),
    }
}

fn all_raw_bytes(relay: &MemoryRelay) -> Vec<Vec<u8>> {
    relay.raw_storage()
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

#[test]
fn three_peers_two_offline_a_thousand_events_converge_byte_identically() {
    let names = ["alice-laptop", "bob-phone", "carol-tablet"];
    let mut house = Household::new(&names);
    let eur_rate = FxRate::new(11, 10, usd()).unwrap();
    house.write(0, open_account("joint-usd", usd()));
    house.write(0, open_account("joint-eur", eur()));
    house.sync_everyone();

    let mut rng = Lcg(0xC0FFEE);
    let mut next_transaction = 0;
    let mut online = [true, true, true];

    // Scripted collisions, repeated every few rounds below.
    let mut scripted = 0;
    for round in 0..80 {
        // Two of three peers flip offline/online at random, but someone is
        // always online so the relay sees traffic.
        for is_online in online.iter_mut().skip(1) {
            if rng.next(3) == 0 {
                *is_online = !*is_online;
            }
        }

        // Every peer, online or not, keeps recording.
        for peer in 0..3 {
            for _ in 0..(2 + rng.next(4)) {
                next_transaction += 1;
                let id = format!("t{next_transaction}");
                if rng.next(2) == 0 {
                    house.write(
                        peer,
                        expense(
                            &id,
                            "joint-usd",
                            500 + rng.next(9_000) as i64,
                            usd(),
                            FxRate::identity(usd()),
                        ),
                    );
                } else {
                    house.write(
                        peer,
                        expense(
                            &id,
                            "joint-eur",
                            500 + rng.next(9_000) as i64,
                            eur(),
                            eur_rate.clone(),
                        ),
                    );
                }
            }
            // Edit or void something this peer currently knows about.
            let known: Vec<_> = house.peers[peer]
                .state()
                .ledger
                .transactions
                .iter()
                .filter(|(_, transaction)| !transaction.voided)
                .map(|(id, transaction)| (id.clone(), transaction.original.currency.clone()))
                .collect();
            if let Some((id, currency)) = known.get(rng.next(known.len().max(1))).cloned() {
                let fx = if currency == usd() {
                    FxRate::identity(usd())
                } else {
                    eur_rate.clone()
                };
                match rng.next(4) {
                    0 => {
                        house.write(peer, void(id.as_str()));
                    }
                    _ => {
                        house.write(
                            peer,
                            adjust(id.as_str(), 100 + rng.next(9_000) as i64, currency, fx),
                        );
                    }
                }
            }
        }

        // Guaranteed collisions on a transaction all three can see.
        if round % 10 == 5 {
            scripted += 1;
            house.sync_everyone();
            next_transaction += 1;
            let id = format!("shared-{scripted}");
            house.write(
                0,
                expense(&id, "joint-usd", 4_000, usd(), FxRate::identity(usd())),
            );
            house.sync_everyone();
            // Both edit from the same view: concurrent edits of one expense.
            house.write(1, adjust(&id, 4_500, usd(), FxRate::identity(usd())));
            house.write(2, adjust(&id, 4_200, usd(), FxRate::identity(usd())));
            // And a third transaction where one peer voids while another edits.
            let raced = format!("raced-{scripted}");
            house.write(
                0,
                expense(&raced, "joint-usd", 900, usd(), FxRate::identity(usd())),
            );
            house.sync_everyone();
            house.write(1, void(&raced));
            house.write(2, adjust(&raced, 1_100, usd(), FxRate::identity(usd())));
        }

        house.sync(0);
        for (index, is_online) in online.iter().enumerate().skip(1) {
            if *is_online {
                house.sync(index);
            }
        }
    }

    // Full reconnection.
    house.sync_everyone();

    assert!(
        house.written.len() >= 1_000,
        "only {} events written",
        house.written.len()
    );

    let reference = fold_shared(usd(), house.written.clone());
    assert!(
        !reference.conflicts.is_empty(),
        "the run produced no conflicts"
    );
    assert!(
        !reference.rejected.is_empty(),
        "the run produced no rejected edits"
    );
    for peer in &house.peers {
        let state = peer.state();
        assert_eq!(
            state.canonical_bytes(),
            reference.canonical_bytes(),
            "{} diverged from the reference fold",
            peer.member_id()
        );
        assert_eq!(
            state.ledger.reporting_balance_minor,
            reference.ledger.reporting_balance_minor
        );
    }

    // The relay never saw a readable field.
    let storage = all_raw_bytes(&house.relay);
    assert!(!storage.is_empty());
    let mut secrets: Vec<Vec<u8>> = names.iter().map(|name| name.as_bytes().to_vec()).collect();
    for shared in &house.written {
        secrets.push(shared.event.id.as_str().as_bytes().to_vec());
        secrets.push(shared.event.actor_id.as_str().as_bytes().to_vec());
    }
    secrets.extend(
        ["Groceries", "joint-usd", "joint-eur", "-account"]
            .iter()
            .map(|word| word.as_bytes().to_vec()),
    );
    for blob in &storage {
        for secret in &secrets {
            assert!(
                !contains(blob, secret),
                "relay storage contains the plaintext {:?}",
                String::from_utf8_lossy(secret)
            );
        }
    }
}

#[test]
fn a_removed_member_cannot_read_anything_after_removal() {
    let mut house = Household::new(&["alice-laptop", "bob-phone", "carol-tablet", "dave-watch"]);
    house.write(0, open_account("joint-usd", usd()));
    house.write(
        3,
        expense("before", "joint-usd", 700, usd(), FxRate::identity(usd())),
    );
    house.sync_everyone();
    let dave_before = house.peers[3].state().canonical_bytes();
    let frames_before = house.relay.len(&house.group);

    let dave_id = house.peers[3].member_id().to_owned();
    house.peers[0].remove(&mut house.relay, &dave_id).unwrap();
    house.sync(3);
    assert!(
        !house.peers[3].is_member(),
        "dave should learn he was removed"
    );

    house.write(
        1,
        expense("after", "joint-usd", 1_300, usd(), FxRate::identity(usd())),
    );
    house.write(2, adjust("before", 650, usd(), FxRate::identity(usd())));
    house.sync_everyone();
    house.sync(3);

    // Dave's view is frozen at removal; the others moved on.
    assert_eq!(house.peers[3].state().canonical_bytes(), dave_before);
    assert_ne!(house.peers[0].state().canonical_bytes(), dave_before);
    assert_eq!(
        house.peers[0].state().canonical_bytes(),
        house.peers[1].state().canonical_bytes()
    );

    // And the ciphertext he could fetch is undecryptable for him: feed him
    // every post-removal frame directly.
    let later = house
        .relay
        .read_after(&house.group, frames_before + 1)
        .unwrap();
    assert!(!later.is_empty());
    for (_, frame) in later {
        assert!(house.peers[3].try_decrypt(&frame).is_err());
    }
}

#[test]
fn edits_name_the_last_event_their_author_had_applied() {
    let mut house = Household::new(&["alice-laptop", "bob-phone"]);
    house.write(0, open_account("joint-usd", usd()));
    let created = house.write(
        0,
        expense("t1", "joint-usd", 1_000, usd(), FxRate::identity(usd())),
    );
    let edit = house.write(0, adjust("t1", 1_200, usd(), FxRate::identity(usd())));
    assert_eq!(edit.base, Some(created.event.id.clone()));
    let again = house.write(0, adjust("t1", 1_300, usd(), FxRate::identity(usd())));
    assert_eq!(again.base, Some(edit.event.id.clone()));
    assert_eq!(
        house.peers[0]
            .state()
            .edit_head(&TransactionId::new("t1"), EditField::Amount),
        Some(&again.event.id)
    );
}
