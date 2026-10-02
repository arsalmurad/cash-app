use cash_core::{ChosenSummary, Currency, EventKind, encode_shared_event};
use cash_sync::{MemoryRelay, Peer};

fn summary(income: Option<i64>, expenses: Option<i64>) -> EventKind {
    EventKind::SummaryPublished {
        summary: ChosenSummary::new(
            Currency::from_code("JPY").unwrap(),
            100,
            200,
            income,
            expenses,
        )
        .unwrap(),
    }
}

#[test]
fn chosen_totals_use_signed_encrypted_history_backfill_restart_and_member_removal() {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice", usd.clone()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob", usd.clone()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    let mut carol = Peer::new("carol", usd.clone()).unwrap();
    let mailbox = alice
        .invite(&mut relay, &carol.key_package().unwrap())
        .unwrap();
    carol.accept(&mut relay, &group, &mailbox).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    // Both other peers remain offline while Alice publishes her exact preview.
    let published = alice
        .write(300, summary(None, Some(123_456_789_012_345)))
        .unwrap();
    let plaintext = encode_shared_event(&published);
    let saved = alice.export().unwrap();
    let amount_offset = saved
        .windows(8)
        .position(|bytes| bytes == 123_456_789_012_345_i64.to_be_bytes())
        .unwrap();
    let mut tampered = saved.clone();
    tampered[amount_offset..amount_offset + 8]
        .copy_from_slice(&123_456_789_012_346_i64.to_be_bytes());
    assert!(
        Peer::import(&tampered).is_err(),
        "a selected total must retain its original author's signature"
    );
    alice = Peer::import(&alice.export().unwrap()).unwrap();
    alice.sync(&mut relay).unwrap();
    for value in relay.raw_storage() {
        assert!(
            !value
                .windows(plaintext.len())
                .any(|bytes| bytes == plaintext)
        );
        assert!(
            !value
                .windows(8)
                .any(|bytes| bytes == 123_456_789_012_345_i64.to_be_bytes())
        );
    }
    bob.write(250, summary(Some(10), None)).unwrap();
    bob = Peer::import(&bob.export().unwrap()).unwrap();
    bob.sync(&mut relay).unwrap();
    carol.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    assert_eq!(
        alice.state().canonical_bytes(),
        bob.state().canonical_bytes()
    );
    assert_eq!(
        alice.state().canonical_bytes(),
        carol.state().canonical_bytes()
    );
    assert_eq!(alice.state().ledger.summaries.len(), 2);
    assert_eq!(alice.state().ledger.reporting_balance_minor, 0);
    assert!(alice.state().ledger.transactions.is_empty());
    // A newly invited peer receives original-author signed summary backfill.
    let mut dave = Peer::new("dave", usd).unwrap();
    let mailbox = alice
        .invite(&mut relay, &dave.key_package().unwrap())
        .unwrap();
    dave.accept(&mut relay, &group, &mailbox).unwrap();
    alice.sync(&mut relay).unwrap();
    dave.sync(&mut relay).unwrap();
    assert_eq!(
        dave.state().canonical_bytes(),
        alice.state().canonical_bytes()
    );
    alice.remove(&mut relay, "bob").unwrap();
    bob.sync(&mut relay).unwrap();
    assert!(!bob.is_member());
    alice.write(400, summary(Some(20), Some(30))).unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    dave.sync(&mut relay).unwrap();
    assert_eq!(bob.state().ledger.summaries.len(), 2);
    assert!(bob.write(500, summary(Some(100), None)).is_err());
    assert_eq!(dave.state().ledger.summaries.len(), 3);
    assert_eq!(
        Peer::import(&dave.export().unwrap()).unwrap().state(),
        dave.state()
    );
}
