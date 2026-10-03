//! Synthetic public interoperability fixture; never prints private key state.
use cash_crypto::{Member, RelayRequest};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn main() {
    let member = Member::new("Synthetic private label").unwrap();
    let request = RelayRequest {
        origin: "https://relay.example",
        method: "POST",
        path: "/g/0123456789abcdef0123456789abcdef/append",
        body: br#"{"expected_tail":1,"blob":"YQ=="}"#,
        nonce: [0xab; 32],
        expires: 1_790_000_030_000,
    };
    let public_key = hex(&member.public_key());
    let signature = hex(&member.sign_relay_request(&request).unwrap());
    let nonce = hex(&request.nonce);
    println!(
        "{{\"publicKey\":\"{public_key}\",\"signature\":\"{signature}\",\"nonce\":\"{nonce}\",\"expires\":{}}}",
        request.expires
    );
}
