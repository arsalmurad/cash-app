# Relay authentication work

Updated 2026-10-03. Public access remains disabled. The current production worker
does not import the new request-proof module or accept a proof as authorization.
Per-device authentication, registration, replay admission and quotas are not
complete merely because a signature verifies.

## Implemented verification primitive

`relay/src/request-proof.js` verifies a short-lived Ed25519 request proof using
an **independently supplied trusted current device key**. It never treats the
public key supplied in an untrusted proof as a grant. It binds the request's
exact canonical origin, uppercase method, path plus query, SHA-256 hash of the
exact bounded body bytes, public signing key, nonce and expiry. All data is
nonfinancial transport metadata; the caller still owes encrypted financial
payloads. Public keys, paths, request sizes/timing and nonces are linkable.

The detached signature payload is:

1. UTF-8 `cash-app authenticated relay request v1` followed by one zero byte.
2. Six u64 big-endian length-framed fields, in order: UTF-8 canonical origin,
   UTF-8 method, UTF-8 path/query, raw 32-byte SHA-256 body digest, raw 32-byte
   Ed25519 public key and raw 32-byte nonce.
3. u64 big-endian expiry in Unix milliseconds (also a JavaScript-safe integer).

Proof JSON has exactly `publicKey`, `nonce`, `expires`, `signature`; the three
binary values use lowercase hex (32, 32 and 64 bytes respectively). Expiry must
be strictly after the supplied server time and at most 60 seconds ahead. Origin
and path are bounded to 256/1,024 characters, body input to 512 KiB; only HTTPS
or explicit HTTP loopback origins and GET/POST/PUT are accepted. Canonical URLs
exclude credentials, fragments and alternate normalized spellings. Verification
returns fixed public metadata or null, not untrusted exception/body contents.

Local test-first checks initially failed at the absent module. Native Node
Ed25519 signs real ephemeral test keys; actual workerd verifies those signatures
and refuses changed bodies. Negative tests cover different origins, paths,
methods, queries, body bytes, trusted keys, absent trust, tampered nonce/expiry/
signature, schema/type/size and expiry bounds. Independent byte-layout assertions
check the documented framing. The production default-public 503 gate remains
unchanged. No credentials are configured, no public relay or cloud job is run.
`cd relay; npm test` independently passes all 33 tests with the existing pinned
Node 24.19 / Miniflare 4.20260730.0 on Windows. Six proof tests include the real
workerd case and exact framing; the complete suite took 21.90 seconds. This
does not prove Rust/app signing interoperability or end-to-end authorization.

## Required before wiring this into public requests

- Establish an authenticated bootstrap/device-registration grant and a trusted
  per-group roster anchored to creation, with explicit membership/recovery
  updates. A self-signed key or random group ID is not permission to create
  storage, register keys or read/append a group.
- Have the app's protected device identity sign the same canonical bytes, without
  using a shared login or exposing private signing keys to Dart/the relay.
  Verify Rust-to-workerd interoperability and actual native/WASM app runtime.
- Atomically admit an unexpired nonce with authorized scope, quotas and mutation.
  A repeated proof deliberately verifies twice at this primitive level; there
  is **no replay protection yet**. Never evict an unexpired replay record to make
  room and thereby allow it again. Refuse capacity safely instead.
- Bound account-wide group/mailbox creation, requests, sockets and retained data;
  preserve lost-response retries and revocation. Per-log limits alone cannot
  constrain an attacker creating many logs.
- Anchor any pruning authority to the authorized current roster, exact durable
  acknowledgements and recoverable floor changes. Receipt bytes remain encrypted;
  signature verification alone is not permission to delete history.
- Keep deployment closed until all these checks pass and the owner authorizes a
  verified $0 spending cap and free-plan deployment. Do not infer billing approval.

This is an integration foundation, not a checked-off production-authentication
gate. Known gaps remain in `COMPLETION.md` and `RELAY-CAPACITY.md`.
