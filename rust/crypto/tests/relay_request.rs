#![cfg(feature = "relay-auth")]

use cash_crypto::{Member, RelayRequest};

fn request() -> RelayRequest<'static> {
    RelayRequest {
        origin: "https://relay.example",
        method: "POST",
        path: "/g/0123456789abcdef0123456789abcdef/append",
        body: br#"{"expected_tail":1,"blob":"YQ=="}"#,
        nonce: [0xab; 32],
        expires: 1_790_000_030_000,
    }
}

#[test]
fn unjoined_device_signs_without_changing_saved_identity_and_restarts() {
    let member = Member::new("Private display name is not sent").unwrap();
    let before = member.export().unwrap();
    let input = request();
    let signed = member.sign_relay_request(&input).unwrap();
    assert_eq!(signed.len(), 64);
    assert_eq!(before, member.export().unwrap());
    let restored = Member::import(&before).unwrap();
    restored
        .verify_relay_request(&member.public_key(), &input, &signed)
        .unwrap();
    assert_eq!(restored.sign_relay_request(&input).unwrap(), signed);
    assert!(
        !input
            .payload(&member.public_key())
            .unwrap()
            .windows(20)
            .any(|bytes| bytes == b"Private display name")
    );
}

#[test]
fn relay_signatures_refuse_changed_scope_body_nonce_expiry_or_identity() {
    let member = Member::new("alice").unwrap();
    let other = Member::new("bob").unwrap();
    let input = request();
    let signature = member.sign_relay_request(&input).unwrap();
    for changed in [
        RelayRequest {
            origin: "https://other.example",
            ..input
        },
        RelayRequest {
            method: "PUT",
            ..input
        },
        RelayRequest {
            path: "/g/0123456789abcdef0123456789abcdef/append?after=1",
            ..input
        },
        RelayRequest {
            body: b"changed",
            ..input
        },
        RelayRequest {
            nonce: [0xac; 32],
            ..input
        },
        RelayRequest {
            expires: input.expires + 1,
            ..input
        },
    ] {
        assert!(
            member
                .verify_relay_request(&member.public_key(), &changed, &signature)
                .is_err()
        );
    }
    assert!(
        member
            .verify_relay_request(&other.public_key(), &input, &signature)
            .is_err()
    );
    let mut tampered = signature;
    tampered[0] ^= 1;
    assert!(
        member
            .verify_relay_request(&member.public_key(), &input, &tampered)
            .is_err()
    );
}

#[test]
fn request_payload_rejects_ambiguous_urls_sizes_and_unrepresentable_expiry() {
    let member = Member::new("alice").unwrap();
    let input = request();
    for bad in [
        RelayRequest {
            origin: "https://relay.example/",
            ..input
        },
        RelayRequest {
            origin: "https://user@relay.example",
            ..input
        },
        RelayRequest {
            origin: "http://relay.example",
            ..input
        },
        RelayRequest {
            method: "post",
            ..input
        },
        RelayRequest {
            path: "//other.example/x",
            ..input
        },
        RelayRequest {
            path: "/g/x#fragment",
            ..input
        },
        RelayRequest {
            path: "/g/x?",
            ..input
        },
        RelayRequest {
            path: "/g/x\n",
            ..input
        },
        RelayRequest {
            expires: u64::MAX,
            ..input
        },
    ] {
        assert!(member.sign_relay_request(&bad).is_err());
    }
    let large = vec![0; 512 * 1024 + 1];
    assert!(
        member
            .sign_relay_request(&RelayRequest {
                body: &large,
                ..input
            })
            .is_err()
    );
    for origin in [
        "http://127.0.0.1:8787",
        "http://localhost:8787",
        "http://[::1]:8787",
    ] {
        assert!(
            member
                .sign_relay_request(&RelayRequest { origin, ..input })
                .is_ok()
        );
    }
}

#[test]
fn relay_proof_cannot_be_reused_as_signed_financial_history() {
    let mut member = Member::new("alice").unwrap();
    member.create_group().unwrap();
    let input = request();
    let before = member.export().unwrap();
    let relay_signature = member.sign_relay_request(&input).unwrap();
    assert_eq!(before, member.export().unwrap());
    assert!(
        member
            .verify_history(
                &member.public_key(),
                &input.payload(&member.public_key()).unwrap(),
                &relay_signature
            )
            .is_err()
    );
}
