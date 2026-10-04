#![cfg(feature = "relay-auth")]
use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{MemoryRelay, Peer, PrefixConsentRequest};

fn pair() -> (MemoryRelay, Peer, Peer) {
    let mut relay = MemoryRelay::default();
    let mut alice = Peer::new("opaque-a", Currency::from_code("USD").unwrap()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("opaque-b", Currency::from_code("USD").unwrap()).unwrap();
    let invite = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &invite).unwrap();
    alice
        .write(
            1,
            EventKind::AccountOpened {
                account_id: AccountId::new("private"),
                name: "Private consent financial marker".into(),
                currency: Currency::from_code("USD").unwrap(),
            },
        )
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    (relay, alice, bob)
}

fn exchange(relay: &mut MemoryRelay, alice: &mut Peer, bob: &mut Peer) {
    alice
        .enqueue_saved_state_receipt(&alice.export().unwrap())
        .unwrap();
    alice.sync(relay).unwrap();
    bob.sync(relay).unwrap();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    bob.sync(relay).unwrap();
    alice.sync(relay).unwrap();
}

fn request(peer: &Peer) -> PrefixConsentRequest {
    PrefixConsentRequest {
        origin: "http://127.0.0.1".into(),
        policy_epoch: 1,
        through: peer
            .retention_cutoff(&peer.received_retention_receipts())
            .unwrap(),
        recovery_holder: peer.public_key(),
        now: 1000,
        expires: 51000,
    }
}

#[test]
fn consent_requires_all_receipts_and_exact_latest_save_without_advancing_keys() {
    let (mut relay, mut alice, mut bob) = pair();
    let incomplete = PrefixConsentRequest {
        origin: "http://127.0.0.1".into(),
        policy_epoch: 1,
        through: 1,
        recovery_holder: alice.public_key(),
        now: 1000,
        expires: 51000,
    };
    assert!(
        alice
            .sign_prefix_consent(&alice.export().unwrap(), &incomplete)
            .is_err()
    );
    exchange(&mut relay, &mut alice, &mut bob);
    let saved = alice.export().unwrap();
    let request = request(&alice);
    let consent = alice.sign_prefix_consent(&saved, &request).unwrap();
    assert!(consent.starts_with(b"cash-app prefix retention consent v1\0"));
    assert!(!consent.windows(16).any(|part| part == b"Private consent "));
    assert_eq!(alice.export().unwrap(), saved);
    let restored = Peer::import(&saved).unwrap();
    assert_eq!(
        restored.sign_prefix_consent(&saved, &request).unwrap(),
        consent
    );
    alice
        .write(
            2,
            EventKind::AccountOpened {
                account_id: AccountId::new("unsent"),
                name: "Not confirmed".into(),
                currency: Currency::from_code("USD").unwrap(),
            },
        )
        .unwrap();
    assert!(alice.sign_prefix_consent(&saved, &request).is_err());
    assert!(
        alice
            .sign_prefix_consent(&alice.export().unwrap(), &request)
            .is_err()
    );
}

#[test]
fn consent_refuses_stale_epochs_unknown_holders_cutoffs_and_noncanonical_scopes() {
    let (mut relay, mut alice, mut bob) = pair();
    exchange(&mut relay, &mut alice, &mut bob);
    let saved = alice.export().unwrap();
    let valid = request(&alice);
    for changed in [
        PrefixConsentRequest {
            policy_epoch: 0,
            ..valid.clone()
        },
        PrefixConsentRequest {
            through: 0,
            ..valid.clone()
        },
        PrefixConsentRequest {
            through: valid.through + 1,
            ..valid.clone()
        },
        PrefixConsentRequest {
            recovery_holder: vec![7; 32],
            ..valid.clone()
        },
        PrefixConsentRequest {
            expires: 1000,
            ..valid.clone()
        },
        PrefixConsentRequest {
            expires: 61001,
            ..valid.clone()
        },
        PrefixConsentRequest {
            origin: "http://relay.example".into(),
            ..valid.clone()
        },
        PrefixConsentRequest {
            origin: "http://127.0.0.1/".into(),
            ..valid.clone()
        },
    ] {
        assert!(alice.sign_prefix_consent(&saved, &changed).is_err());
    }
    alice.begin_rotation().unwrap();
    assert!(
        alice
            .sign_prefix_consent(&alice.export().unwrap(), &valid)
            .is_err()
    );
}

#[test]
fn membership_changes_invalidate_collected_permission_and_old_confirmed_saves() {
    let (mut relay, mut alice, mut bob) = pair();
    exchange(&mut relay, &mut alice, &mut bob);
    let request = request(&alice);
    let saved = alice.export().unwrap();
    alice.remove(&mut relay, "opaque-b").unwrap();
    assert!(alice.sign_prefix_consent(&saved, &request).is_err());
    assert!(
        alice
            .sign_prefix_consent(&alice.export().unwrap(), &request)
            .is_err()
    );
    bob.sync(&mut relay).unwrap();
    assert!(
        bob.sign_prefix_consent(&bob.export().unwrap(), &request)
            .is_err()
    );
}
