//! Collection persistence is metadata only; the financial event set is unchanged.
use cash_core::Currency;
use cash_sync::{MemoryRelay, Peer};

fn confirmed_pair() -> (Peer, Peer) {
    let usd = Currency::from_code("USD").unwrap();
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("alice-private-device", usd.clone()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("bob-private-device", usd).unwrap();
    let mailbox = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &mailbox).unwrap();
    alice
        .enqueue_saved_state_receipt(&alice.export().unwrap())
        .unwrap();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    (alice, bob)
}

#[test]
fn verified_collections_restart_with_the_same_conservative_cutoff() {
    let (alice, bob) = confirmed_pair();
    for peer in [alice, bob] {
        let receipts = peer.received_retention_receipts();
        let cutoff = peer.retention_cutoff(&receipts).unwrap();
        let state = peer.state().canonical_bytes();
        let saved = peer.export().unwrap();
        assert!(saved.starts_with(b"cash-app peer v7\0"));
        let restarted = Peer::import(&saved).unwrap();
        assert_eq!(restarted.received_retention_receipts(), receipts);
        assert_eq!(restarted.retention_cutoff(&receipts).unwrap(), cutoff);
        assert_eq!(restarted.state().canonical_bytes(), state);
        assert_eq!(restarted.export().unwrap(), saved);
    }
}

#[test]
fn corrupted_collection_signatures_and_schema_downgrade_fail_closed() {
    let (alice, _) = confirmed_pair();
    let receipt = alice.received_retention_receipts().remove(0);
    let saved = alice.export().unwrap();
    let start = saved
        .windows(receipt.len())
        .position(|part| part == receipt)
        .expect("Verified receipt bytes must be included in the archive");
    let mut bad = saved.clone();
    bad[start + receipt.len() - 1] ^= 1;
    assert!(Peer::import(&bad).is_err());
    let mut downgrade = saved;
    let old = b"cash-app peer v6\0";
    downgrade[..old.len()].copy_from_slice(old);
    assert!(Peer::import(&downgrade).is_err());
}

#[test]
fn collection_lengths_truncation_duplicates_and_reordering_fail_closed() {
    let (alice, _) = confirmed_pair();
    let receipts = alice.received_retention_receipts();
    assert_eq!(receipts.len(), 2);
    let saved = alice.export().unwrap();
    let collection_len = 8 + receipts.iter().map(|row| 8 + row.len()).sum::<usize>();
    let start = saved.len() - collection_len;
    for count in [0_u64, 5, u64::MAX] {
        let mut bad = saved.clone();
        bad[start..start + 8].copy_from_slice(&count.to_be_bytes());
        assert!(Peer::import(&bad).is_err());
    }
    for end in start..saved.len() {
        assert!(Peer::import(&saved[..end]).is_err());
    }
    for rows in [
        vec![&receipts[0], &receipts[0]],
        vec![&receipts[1], &receipts[0]],
    ] {
        let mut bad = saved[..start].to_vec();
        bad.extend_from_slice(&2_u64.to_be_bytes());
        for row in rows {
            bad.extend_from_slice(&(row.len() as u64).to_be_bytes());
            bad.extend_from_slice(row);
        }
        assert!(Peer::import(&bad).is_err());
    }
    let mut bad = saved.clone();
    bad[start + 8..start + 16].copy_from_slice(&u64::MAX.to_be_bytes());
    assert!(Peer::import(&bad).is_err());
    let mut trailing = saved;
    trailing.push(0);
    assert!(Peer::import(&trailing).is_err());
}
