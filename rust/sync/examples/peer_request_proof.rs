//! Synthetic restored-peer interoperability fixture; public proof output only.
use cash_core::Currency;
use cash_sync::Peer;

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn main() {
    let peer = Peer::new(
        "Synthetic private peer label",
        Currency::from_code("USD").unwrap(),
    )
    .unwrap();
    let saved = peer.export().unwrap();
    let restored = Peer::import(&saved).unwrap();
    let expires = u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap()
    .checked_add(50_000)
    .unwrap();
    let proof = restored
        .sign_relay_request(
            "http://127.0.0.1",
            "POST",
            "/g/0123456789abcdef0123456789abcdef/append",
            br#"{"expected_tail":0,"blob":"AQ=="}"#,
            expires,
        )
        .unwrap();
    assert_eq!(restored.export().unwrap(), saved);
    println!(
        "{{\"publicKey\":\"{}\",\"signature\":\"{}\",\"nonce\":\"{}\",\"expires\":{}}}",
        hex(&proof.public_key),
        hex(&proof.signature),
        hex(&proof.nonce),
        proof.expires
    );
}
