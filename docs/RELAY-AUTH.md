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

### Scoped per-device policy refinement

The subsequent admission policy is version 2: `{version, epoch, scope, devices}`.
`scope` has the exact canonical `origin`, namespace `kind` (`g`/`m`) and random
32-character hex `id`; each sorted unique device has `{key, operations}` with a
sorted bounded allowlist. Old unscoped version-1 policies are refused, not
silently upgraded. This is experimental local policy metadata, not migration of
a deployed authenticated relay.

The verifier now keeps immutable request origin/method/path/query context in an
isolate-local WeakMap, separate from returned public proof metadata. Admission
uses that context, not caller-supplied/deserialized scope. Known group operations
are read/append/WebSocket/membership/prune; mailbox operations are distinct
read/write/take/ack grants. Wrong origins, namespace IDs, methods, path aliases,
unrelated query parameters, ambiguous/unsafe read cursors and missing operation
grants are refused without nonce/clock/mutation writes. Recognizing a membership
or prune action does **not** implement that endpoint or its approval protocol.

All 11 focused policy/admission tests pass, including actual SQLite workerd
refusal after origin/operation-policy changes, race/revocation and rollback.
The separate seven Rust-to-workerd proof checks also pass again with zero
skipped. Production routes remain unchanged/default-public closed; real grant
issuance, group creation, membership semantics, pruning certificates and app
integration are still open. No new platform rebuild was required for unused
server-side primitives.

The full local Node suite subsequently passes 44 checks and explicitly skips
its one optional Rust fixture (45 total, 54.43 seconds while the full app suite
also ran). The separate Rust-fixture command has already passed seven checks
with zero skips at this same scoped-policy source. No cloud job or deployment
was started.

### Remaining production integration

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

## Actual authenticated group routes, explicit loopback only (2026-10-03)

`local-auth-worker.js` is a separate experimental entry point, not Wrangler's
default worker. It requires literal `LOCAL_DEVELOPMENT=true`, an exact loopback
origin and an operator-supplied `LOCAL_AUTH_POLICY` containing one version-2
group policy. Only read/append grants are supported. Unknown groups, mailboxes,
WebSockets, membership/pruning routes and invalid/oversized configuration fail
closed; rejected namespaces cannot allocate a Durable Object. Configuration is
trusted out of band, never accepted from a client proof or registration request.
The stored policy contains only documented public transport metadata.

HTTP proofs use `x-cash-device-proof`. Exact streamed body bytes are bounded to
512 KiB before verification, then reused without JSON reserialization for the
existing append implementation. Its authorization hook runs inside the same
SQLite transaction as ciphertext/tail/capacity writes; signed reads consume
their nonce in the same transaction as the bounded page read. A fresh empty
object can initialize the configured policy atomically. Existing unauthenticated
history is not adopted, and a different persisted policy is refused, not silently
overwritten or downgraded. Replay protection, permissions and monotonic clock
checks use the previously tested primitives. Returned append conflicts/capacity
errors can consume a nonce; a failed transaction rolls it back with all writes.

The original worker/dev behavior is unchanged unless `LOCAL_AUTH_POLICY` is
explicitly set. With it, `node relay/dev-server.mjs <port>` selects the new
SQLite group worker; its policy origin must exactly match
`http://127.0.0.1:<port>`. Missing/invalid policy values refuse access. The current
Flutter HTTP client remains unsigned and cannot use this mode yet. This is a
protocol-development option, not a suggested public or normal-user deployment.
Both workers reject public URLs, even with development enabled.

Actual workerd tests cover signed/unsigned reads and appends, body changes and
oversize refusal, one winner in a replay race, forbidden namespace allocation,
legacy-policy refusal, and a deliberately failed real append. That failure
leaves policy, nonce, clock, ciphertext, tail and capacity absent together; the
same proof then succeeds on retry. Seed/inspect/fault controls exist only in
the test's in-memory wrapper, never the launcher or either worker. The launcher
itself runs in an owned loopback process and accepts a real signed HTTP append;
only its owned process tree is stopped afterward.

The synthetic Rust example has a `local-group` mode generating a short-lived
proof from a fresh opaque Member, without key export. Its constant test nonce
is not a production nonce generator. `npm run test:request-proof-rust` now
requires both fixtures and passes all 13 checks with zero skips, including a
Rust-authenticated actual group append and replay rejection. The complete final
`npm test` passes 49 checks and explicitly skips these two Rust-fixture cases
(51 total, 23.58 s). Strict crypto/all-target Clippy passes (3.97 s).
`npm run test:storage` still independently inspects 31 real encrypted-peer log
records/mailboxes and rejects its plaintext-injection negative control. It emits
the previously recorded WSASend #10054 diagnostic while exiting successfully;
no physical-network reliability claim follows. No app bridge changed or platform
rebuild was required for unused server/fixture code.

Still open: trusted dynamic MLS-roster transitions/recovery, app signing and
native/WASM networking, mailbox/socket authorization, account-wide/request
quotas, authenticated long-backfill behavior at the 256-live-nonce limit,
recoverable pruning and owner-authorized $0 deployment. One configured local
namespace bounds this experiment, not all account charges or abuse. No cloud
job, public route or history deletion was enabled.

## Request counts independent of proof lifetime (2026-10-03)

The local authenticated group path now also enforces 10,000 admitted requests
per device and 20,000 per configured group per UTC day, independently of nonce
expiry. It stores an exact-schema version-1 `request_budget` record with at most
64 sorted public-key counters; the group count must equal their sum. All counters
are bounded integers. Shortening a proof's lifetime cannot reset these counts.
Rollover uses the admission transaction's monotonic server-time high-water mark,
not client time; backwards time, unknown/malformed budget state and extra metadata
fail closed. An older initialized authenticated object without budget accounting
requires explicit migration rather than guessing its prior daily usage.

Admission, budget spending and the group operation remain in one transaction.
Budget refusal throws, rolling back nonce/clock/policy/operation changes, then
returns 429 with a bounded numeric Retry-After to the next UTC day. Existing
history stays intact. Replay refusals do not spend budget; ordinary admitted
append conflicts/capacity responses can spend budget. Fresh empty-object setup
and a deliberately failed real append roll back budget initialization too.

Three test-first unit checks and an actual SQLite workerd refusal/rollover case
pass. The final complete `npm test` passes 53 checks and explicitly skips the two
Rust-fixture cases (55 total, 35.23 s). The dedicated fixture command passes all
14 Rust/workerd/launcher checks with zero skips (4.61 s), so the skips are not
interoperability evidence by themselves. Local full log:
`app/.dart_tool/relay-request-budget-final.log`. No app/Rust implementation or
platform artifact changed for this isolated experimental-server concern.

These are admitted-operation budgets for one configured local group, not a
complete rate limiter or account spending guarantee. Unauthenticated/invalid
requests, preflight traffic, operator setup and future mailboxes/sockets still
need account-wide abuse controls and verified provider spending limits. Public
access stays closed, and authenticated long backfills still need durable progress
across nonce-budget interruptions before app-side integration is enabled.
