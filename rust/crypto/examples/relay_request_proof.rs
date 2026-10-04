//! Synthetic public interoperability fixture; never prints private key state.
use cash_crypto::{Member, RelayRequest};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn main() {
    let member = Member::new("Synthetic private label").unwrap();
    let mode = std::env::args().nth(1);
    let notification = mode.as_deref() == Some("local-notification");
    let local_group = notification || mode.as_deref() == Some("local-group");
    let notification_origin = if notification {
        std::env::args()
            .nth(2)
            .expect("notification fixture origin")
    } else {
        String::new()
    };
    let expires = if local_group {
        u64::try_from(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis(),
        )
        .unwrap()
        .checked_add(50_000)
        .unwrap()
    } else {
        1_790_000_030_000
    };
    let request = RelayRequest {
        origin: if notification {
            &notification_origin
        } else if local_group {
            "http://127.0.0.1"
        } else {
            "https://relay.example"
        },
        method: if notification { "GET" } else { "POST" },
        path: if notification {
            "/g/15151515151515151515151515151515/ws"
        } else {
            "/g/0123456789abcdef0123456789abcdef/append"
        },
        body: if notification {
            b""
        } else if local_group {
            br#"{"expected_tail":0,"blob":"AQ=="}"#
        } else {
            br#"{"expected_tail":1,"blob":"YQ=="}"#
        },
        // Synthetic fixture only: every invocation generates a fresh identity.
        // Real clients owe a fresh random nonce for every signed attempt.
        nonce: [0xab; 32],
        expires,
    };
    let public_key = hex(&member.public_key());
    let signature = hex(&member.sign_relay_request(&request).unwrap());
    let nonce = hex(&request.nonce);
    println!(
        "{{\"publicKey\":\"{public_key}\",\"signature\":\"{signature}\",\"nonce\":\"{nonce}\",\"expires\":{}}}",
        request.expires
    );
}
