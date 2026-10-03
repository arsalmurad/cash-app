#![cfg(feature = "relay-auth")]

use std::collections::BTreeSet;

use cash_core::{AccountId, Currency, EventKind};
use cash_crypto::{Member, RelayRequest};
use cash_sync::Peer;

const ORIGIN: &str = "https://relay.example";
const PATH: &str = "/g/0123456789abcdef0123456789abcdef?after=0";
const EXPIRY: u64 = 1_790_000_030_000;

fn peer() -> Peer {
    Peer::new("opaque-device", Currency::from_code("USD").unwrap()).unwrap()
}

#[test]
fn unjoined_peer_signs_with_fresh_nonces_and_stable_saved_identity() {
    let device = peer();
    let saved = device.export().unwrap();
    let verifier = Member::new("independent-verifier").unwrap();
    let mut nonces = BTreeSet::new();
    let mut key = None;
    for _ in 0..32 {
        let proof = device
            .sign_relay_request(ORIGIN, "GET", PATH, b"", EXPIRY)
            .unwrap();
        assert_eq!(proof.public_key.len(), 32);
        assert_eq!(proof.signature.len(), 64);
        assert_eq!(proof.expires, EXPIRY);
        assert!(nonces.insert(proof.nonce));
        assert_eq!(
            key.get_or_insert(proof.public_key.clone()),
            &proof.public_key
        );
        verifier
            .verify_relay_request(
                &proof.public_key,
                &RelayRequest {
                    origin: ORIGIN,
                    method: "GET",
                    path: PATH,
                    body: b"",
                    nonce: proof.nonce,
                    expires: proof.expires,
                },
                &proof.signature,
            )
            .unwrap();
        assert_eq!(device.export().unwrap(), saved);
    }
    let restored = Peer::import(&saved).unwrap();
    let proof = restored
        .sign_relay_request(ORIGIN, "GET", PATH, b"", EXPIRY)
        .unwrap();
    assert_eq!(Some(proof.public_key), key);
    assert!(
        nonces.insert(proof.nonce),
        "Restart must not reuse a persisted request counter"
    );
    assert_eq!(restored.export().unwrap(), saved);
}

#[test]
fn signing_preserves_pending_financial_frames_and_staged_membership() {
    let mut device = peer();
    device.found_group().unwrap();
    device
        .write(
            1,
            EventKind::AccountOpened {
                account_id: AccountId::new("shared"),
                name: "Private name".into(),
                currency: Currency::from_code("USD").unwrap(),
            },
        )
        .unwrap();
    let outgoing = device.next_outgoing().unwrap().unwrap();
    let saved = device.export().unwrap();
    let body = br#"{"expected_tail":0,"blob":"AQ=="}"#;
    let path = "/g/0123456789abcdef0123456789abcdef/append";
    let proof = device
        .sign_relay_request(ORIGIN, "POST", path, body, EXPIRY)
        .unwrap();
    assert_eq!(device.export().unwrap(), saved);
    // Asking for another outgoing frame advances MLS encryption again; it is
    // not an idempotent peek. The exact exported ratchet/outbox comparison
    // above proves that signing itself did not mutate pending delivery state.
    assert_eq!(outgoing.expected_tail, device.cursor());
    let verifier = Member::new("verifier").unwrap();
    let request = RelayRequest {
        origin: ORIGIN,
        method: "POST",
        path,
        body,
        nonce: proof.nonce,
        expires: proof.expires,
    };
    assert!(
        verifier
            .verify_relay_request(
                &proof.public_key,
                &RelayRequest {
                    body: b"changed",
                    ..request
                },
                &proof.signature
            )
            .is_err()
    );
    verifier
        .verify_relay_request(&proof.public_key, &request, &proof.signature)
        .unwrap();
    let invitee = Peer::new("invitee-device", Currency::from_code("USD").unwrap()).unwrap();
    device
        .begin_invite(&invitee.key_package().unwrap())
        .unwrap();
    let staged = device.export().unwrap();
    device
        .sign_relay_request(ORIGIN, "GET", PATH, b"", EXPIRY)
        .unwrap();
    assert_eq!(device.export().unwrap(), staged);
}

#[test]
fn malformed_requests_fail_without_modifying_peer_history() {
    let device = peer();
    let saved = device.export().unwrap();
    for (origin, method, path, body, expiry) in [
        ("http://relay.example", "GET", PATH, vec![], EXPIRY),
        (ORIGIN, "DELETE", PATH, vec![], EXPIRY),
        (ORIGIN, "GET", "//other.example/g", vec![], EXPIRY),
        (ORIGIN, "GET", PATH, vec![0; 512 * 1024 + 1], EXPIRY),
        (ORIGIN, "GET", PATH, vec![], 9_007_199_254_740_992),
    ] {
        assert!(
            device
                .sign_relay_request(origin, method, path, &body, expiry)
                .is_err()
        );
        assert_eq!(device.export().unwrap(), saved);
    }
}
