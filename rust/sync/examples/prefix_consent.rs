//! Synthetic public consent/request interoperability; no user keys or archives.
use cash_core::{AccountId, Currency, EventKind};
use cash_sync::{DeviceRequestProof, MemoryRelay, Peer, PrefixConsentRequest, Relay};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
fn proof(value: &DeviceRequestProof) -> String {
    format!(
        "{{\"publicKey\":\"{}\",\"nonce\":\"{}\",\"expires\":{},\"signature\":\"{}\"}}",
        hex(&value.public_key),
        hex(&value.nonce),
        value.expires,
        hex(&value.signature)
    )
}
fn main() {
    let mut relay = MemoryRelay::default();
    let usd = Currency::from_code("USD").unwrap();
    let mut alice = Peer::new("opaque-interop-a", usd.clone()).unwrap();
    let group = alice.found(&mut relay).unwrap();
    let mut bob = Peer::new("opaque-interop-b", usd.clone()).unwrap();
    let invite = alice
        .invite(&mut relay, &bob.key_package().unwrap())
        .unwrap();
    bob.accept(&mut relay, &group, &invite).unwrap();
    alice
        .write(
            1,
            EventKind::AccountOpened {
                account_id: AccountId::new("fixture"),
                name: "Private Rust consent fixture".into(),
                currency: usd,
            },
        )
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    alice
        .enqueue_saved_state_receipt(&alice.export().unwrap())
        .unwrap();
    alice.sync(&mut relay).unwrap();
    bob.sync(&mut relay).unwrap();
    bob.enqueue_saved_state_receipt(&bob.export().unwrap())
        .unwrap();
    bob.sync(&mut relay).unwrap();
    alice.sync(&mut relay).unwrap();
    let now = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap();
    let through = alice
        .retention_cutoff(&alice.received_retention_receipts())
        .unwrap();
    let request = PrefixConsentRequest {
        origin: "http://127.0.0.1".into(),
        policy_epoch: 1,
        through,
        recovery_holder: alice.public_key(),
        now,
        expires: now + 50000,
    };
    let first = hex(&alice
        .sign_prefix_consent(&alice.export().unwrap(), &request)
        .unwrap());
    let second = hex(&bob
        .sign_prefix_consent(&bob.export().unwrap(), &request)
        .unwrap());
    let body = format!(
        "{{\"expectedFloor\":0,\"through\":{through},\"consents\":[\"{first}\",\"{second}\"]}}"
    );
    let signed = alice
        .sign_relay_request(
            &request.origin,
            "POST",
            &format!("/g/{group}/prune"),
            body.as_bytes(),
            request.expires,
        )
        .unwrap();
    let read = alice
        .sign_relay_request(
            &request.origin,
            "GET",
            &format!("/g/{group}/policy"),
            &[],
            request.expires,
        )
        .unwrap();
    let mut keys = [hex(&alice.public_key()), hex(&bob.public_key())];
    keys.sort();
    let entries = relay
        .read_after(&group, 0)
        .unwrap()
        .iter()
        .map(|(seq, blob)| format!("{{\"seq\":{seq},\"hex\":\"{}\"}}", hex(blob)))
        .collect::<Vec<_>>()
        .join(",");
    println!(
        "{{\"group\":\"{group}\",\"keys\":[\"{}\",\"{}\"],\"body\":{body},\"proof\":{},\"readProof\":{},\"entries\":[{entries}]}}",
        keys[0],
        keys[1],
        proof(&signed),
        proof(&read)
    );
}
