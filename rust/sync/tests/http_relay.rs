//! The real sync engine against the real Cloudflare Worker (running in
//! workerd via miniflare). Ignored by default because it needs the worker
//! running; `scripts/verify_relay.sh` starts it and runs this.

#![cfg(feature = "http")]

use cash_core::{
    AccountId, Currency, EditField, EventKind, FxRate, Money, TransactionId, TransactionKind,
    fold_shared,
};
use cash_sync::{HttpRelay, MailboxItem, Peer, Relay, RelayError};

fn usd() -> Currency {
    Currency::from_code("USD").unwrap()
}

fn relay() -> HttpRelay {
    HttpRelay::new(&std::env::var("RELAY_URL").expect("set RELAY_URL to the running relay"))
}

fn expense(id: &str, minor: i64) -> EventKind {
    EventKind::TransactionRecorded {
        transaction_id: TransactionId::new(id),
        account_id: AccountId::new("joint"),
        kind: TransactionKind::Expense,
        original: Money::new(minor, usd()),
        reporting_fx: FxRate::identity(usd()),
        title: format!("Secret {id}"),
        category_id: None,
        recurring_id: None,
    }
}

fn adjust(id: &str, minor: i64) -> EventKind {
    EventKind::AmountAdjusted {
        transaction_id: TransactionId::new(id),
        original: Money::new(minor, usd()),
        reporting_fx: FxRate::identity(usd()),
    }
}

#[test]
#[ignore = "needs the relay running: see scripts/verify_relay.sh"]
fn the_worker_honours_the_relay_contract() {
    let mut relay = relay();
    let group = "00000000000000000000000000000001";
    assert_eq!(relay.append(group, 0, b"a".to_vec()), Ok(1));
    assert_eq!(relay.append(group, 1, b"b".to_vec()), Ok(2));
    assert_eq!(
        relay.append(group, 1, b"stale".to_vec()),
        Err(RelayError::Conflict { tail: 2 })
    );
    assert_eq!(
        relay.read_after(group, 1).unwrap(),
        vec![(2, b"b".to_vec())]
    );

    let item = MailboxItem {
        group: group.to_owned(),
        joined_after: 2,
        welcome: b"welcome".to_vec(),
    };
    let mailbox = "00000000000000000000000000000002";
    relay.put_mailbox(mailbox, item.clone()).unwrap();
    assert_eq!(relay.take_mailbox(mailbox).unwrap(), Some(item));
    assert_eq!(relay.take_mailbox(mailbox).unwrap(), None);
    let acknowledged_mailbox = "00000000000000000000000000000003";
    let item = MailboxItem {
        group: group.to_owned(),
        joined_after: 2,
        welcome: b"retryable encrypted welcome".to_vec(),
    };
    relay
        .put_mailbox(acknowledged_mailbox, item.clone())
        .unwrap();
    assert_eq!(
        relay.peek_mailbox(acknowledged_mailbox).unwrap(),
        Some(item.clone())
    );
    assert_eq!(
        relay.peek_mailbox(acknowledged_mailbox).unwrap(),
        Some(item.clone())
    );
    relay.acknowledge_mailbox(acknowledged_mailbox).unwrap();
    relay.acknowledge_mailbox(acknowledged_mailbox).unwrap();
    relay.put_mailbox(acknowledged_mailbox, item).unwrap();
    assert_eq!(relay.peek_mailbox(acknowledged_mailbox).unwrap(), None);
}

#[test]
#[ignore = "needs the relay running: see scripts/verify_relay.sh"]
fn three_peers_converge_through_the_real_worker() {
    let mut relay = relay();
    let mut peers: Vec<_> = ["alice-laptop", "bob-phone", "carol-tablet"]
        .iter()
        .map(|name| Peer::new(name, usd()).unwrap())
        .collect();
    let group = peers[0].found(&mut relay).unwrap();
    for index in 1..3 {
        let key_package = peers[index].key_package().unwrap();
        let mailbox = peers[0].invite(&mut relay, &key_package).unwrap();
        peers[index].accept(&mut relay, &group, &mailbox).unwrap();
    }

    let mut written = Vec::new();
    let mut clock = 10_000;
    let mut write = |peer: &mut Peer, kind: EventKind| {
        clock += 1;
        written.push(peer.write(clock, kind).unwrap());
    };
    write(
        &mut peers[0],
        EventKind::AccountOpened {
            account_id: AccountId::new("joint"),
            name: "Joint".to_owned(),
            currency: usd(),
        },
    );
    peers[0].sync(&mut relay).unwrap();
    for peer in &mut peers {
        peer.sync(&mut relay).unwrap();
    }

    // Bob and Carol edit the same expense without seeing each other.
    write(&mut peers[0], expense("dinner", 4_000));
    for peer in &mut peers {
        peer.sync(&mut relay).unwrap();
    }
    write(&mut peers[1], adjust("dinner", 4_500));
    write(&mut peers[2], adjust("dinner", 4_200));
    for index in 0..20 {
        write(
            &mut peers[index % 3],
            expense(&format!("t{index}"), 100 + index as i64),
        );
    }
    for _ in 0..2 {
        for peer in &mut peers {
            peer.sync(&mut relay).unwrap();
        }
    }

    let reference = fold_shared(usd(), written.clone());
    assert_eq!(reference.conflicts.len(), 1);
    for peer in &peers {
        assert_eq!(peer.state().canonical_bytes(), reference.canonical_bytes());
    }
    assert_eq!(
        peers[0]
            .state()
            .edit_head(&TransactionId::new("dinner"), EditField::Amount),
        reference.edit_head(&TransactionId::new("dinner"), EditField::Amount)
    );
}
