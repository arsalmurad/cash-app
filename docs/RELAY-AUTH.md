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

## Opt-in Rust signing and actual-workerd interoperability

`cash_crypto` now has an explicit `relay-auth` feature. It uses the existing
opaque Member's Ed25519 identity to sign the same canonical request payload,
including before the device joins MLS. It computes the body digest internally
and rejects noncanonical/oversized inputs and expiries outside the shared safe
integer range. The caller still owes a fresh nonce and suitable expiry; the
signer does not treat either as authorization or mutate MLS ratchets.

The feature reuses pinned `url=2.5.8`, already in Cargo.lock/cache; only the
direct optional dependency relation is added, with no package upgrades. The
default app bridge does **not** enable this feature and has no new signing API.
No Flutter/OS-key/cloud signing runtime is claimed from these host checks.

Independent locked/offline Windows checks with pinned Rust 1.98.1:

- `cargo test --manifest-path rust/Cargo.toml --locked --offline -p cash_crypto
  --features relay-auth`: all 25 crypto tests pass (14 MLS/history, seven recovery,
  four request-signing). The four new tests cover unjoined signed identity/
  byte-identical export/restart, changed request scope/identity/body/nonce/expiry,
  bounds/URL spellings/loopback variants, and rejection as financial history.
- Matching all-target Clippy with `-- -D warnings` passes without suppressions.
- `CARGO=C:/Users/ME/.cargo/bin/cargo.exe npm run test:request-proof-rust` in
  `relay`: all seven proof tests pass, zero skipped, including a real synthetic
  Rust Member signature accepted by actual workerd and changed-body rejection.
  The fixture prints only a synthetic public proof, never private archives.

Node-only `npm test` retains the original proof checks and conditionally skips
only the Rust-fixture case unless its public fixture is provided; the separate
Rust interoperability command requires it and does not skip. Phase 2 CI now
explicitly enables the crypto feature for tests/lint and invokes interoperability
after restoring relay dependencies. No workflow was dispatched; pushes to main
do not trigger this PR/manual workflow. Cloud CI results are not inferred.

## Required before wiring this into public requests

### Transactional admission primitive

`request-admission.js` now consumes only immutable, identity-branded output from
the verifier in the same isolate. A raw/copy-deserialized `{publicKey, nonce,
expires}` object is not verified evidence. The future caller must verify inside
the target Durable Object against that exact request/namespace scope; a worker
cannot serialize this result and expect another isolate to trust it.

Inside the same storage transaction as an authorized operation, the helper
rechecks `authorized_devices` (version 1, nonnegative safe epoch, one to 64 sorted
unique public keys). Removed keys are rejected even if signature verification
occurred before revocation. It persists at most 256 sorted live nonce/expiry
records per device and a group clock high-water mark. A full live set refuses
admission; it does not evict an unexpired replay record. Expired rows are
reclaimed only on successful admission, and monotonic effective server time
prevents purged proofs becoming fresh again after clock rollback. Malformed or
missing required policy/counter/clock data fail closed without state writes.

The helper is still not imported by production routing. The caller must validate
operation-specific permissions, exact namespace/request binding and quotas,
then run admission **and mutation in one transaction**. Returning an error
instead of rolling back a failed mutation can consume a nonce; lost responses
must use a newly signed nonce with existing safe app retries. Membership updates
must preserve unexpired replay records and the clock high-water mark. This is
not roster bootstrap, a grant/role policy, account-wide quotas or crash-proof
delivery attestation.

Tests initially failed at the absent helper. Unit checks cover verifier-output
branding, live roster rechecks, replay/capacity, expiration/clock rollback and
malformed-state refusal. An in-memory test-only wrapper in actual workerd with
SQLite Durable Objects verifies signed requests, admits exactly one of two
racing nonce uses, rolls nonce/clock back with a deliberately failed mutation,
retries successfully, and rejects a key revoked after verification but before
the transaction. Its seed/read/fault/revocation routes never enter production
configuration. This is local primitive evidence, not a deployed/app auth claim.
All six admission tests pass locally; the separate Rust-to-workerd command again
passes all seven proof tests with zero skipped.
The subsequent full `npm test` run passes 39 tests and conditionally skips the
one Rust-fixture case (40 total), in 22.90 seconds. That case is independently
required and passes in `test:request-proof-rust`; the skip is not a claim that
interoperability ran during the Node-only suite. No production worker/app source
is activated by the new admission module.

### Open integration gates

- Establish an authenticated bootstrap/device-registration grant and a trusted
  per-group roster anchored to creation, with explicit membership/recovery
  updates. A self-signed key or random group ID is not permission to create
  storage, register keys or read/append a group.
- Have the app's protected device identity sign the same canonical bytes, without
  using a shared login or exposing private signing keys to Dart/the relay.
  Verify Rust-to-workerd interoperability and actual native/WASM app runtime.
- Wire the tested admission primitive into production authorization and mutation
  transactions with operation-specific scope/quotas. A repeated proof still
  deliberately verifies twice at the standalone signature level; the helper
  prevents repeat admission only where correctly integrated. Production/app
  replay protection remains unimplemented. Never evict an unexpired record to
  make room and thereby allow it again.
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
