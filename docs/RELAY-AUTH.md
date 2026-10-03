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

## Durable app backfill progress (2026-10-03)

The Dart HTTP client now offers `PagedRelayClient.readConfirmedPages`, in
addition to the unchanged all-or-nothing `readAfter` list contract. Each full
page passes the existing response/entry/total limits, contiguous sequence,
monotonic tail and continuation checks before it reaches the consumer. The
household controller ingests and awaits local persistence before another GET.
The first observed target tail remains fixed; concurrent later entries wait for
the next catch-up. Network deadline accounting includes time spent saving,
but storage callbacks are awaited rather than cancelled or raced.

A later 429 or transport failure leaves earlier confirmed progress saved;
restart resumes from that cursor. Incomplete catch-up does not enqueue a saved
history receipt. Uncertain page persistence blocks all later requests/writes
until restart, whether the store saved before throwing or not. The optional
paged capability leaves in-memory/custom clients and invitation list checks
unchanged. This is preparation for signed app networking, not evidence that
the app already authenticates, honors Retry-After automatically, or passes a
real 256-nonce authenticated backfill. The Rust HTTP list path is unchanged.

## Actual authenticated nonce-limited page resumption (2026-10-03)

A subsequent SQLite/workerd regression uses the original authenticated read
route with fresh Node Ed25519 proofs. Test-only controls seed 320 opaque sample
records and 255 short-lived replay rows; the first 16-entry page fills the
256-record nonce table and the next page receives 429 with every stored row,
budget and clock unchanged. After those seeded rows expire in real time, the
first page's still-live proof remains a rejected replay, while reads resume
from sequence 16 and collect exactly sequences 1..320 without gaps or duplicates.
No entry/capacity data changes; only the bootstrap and 20 successful page reads
spend daily request budget. Production code has no fixture seed/inspection route.

The focused test passes (2.96s). The complete relay suite passes 54 checks with
the two explicit Rust-fixture skips (56 total, 24.05s); the dedicated cached
Rust/workerd command separately passes all 15 checks with zero skips (7.80s).
Log: `app/.dart_tool/authenticated-backfill-relay.log`. This verifies server
refusal/resumption with synthetic opaque payloads, not real app-signed MLS
networking, disk-backed Node progress or a new financial-plaintext audit.
Combined app-to-authenticated-relay acceptance remains open.

## Request proofs from the protected sync peer (2026-10-03)

The optional `cash_sync/relay-auth` feature now forwards the pinned crypto
request-proof implementation. `Peer.sign_relay_request` uses the peer's existing
opaque device identity and generates a fresh 32-byte platform-RNG nonce on every
attempt, including after restoring an archive. RNG errors are returned, not
replaced with counters or weak randomness. Only public key, nonce, expiry and
signature leave the signer. No transport, private-key export, new identity,
MLS ratchet, pending financial event, receipt or staged commit is created.
The caller supplies exact origin/method/path-query/body and expiry; canonical
size/URL checks remain in crypto, and trusted permissions/freshness remain
server responsibilities. A request signature is not proof of current MLS
membership or permission to register oneself.

Three test-first sync regressions verify signatures independently, distinct
nonces across 32 attempts and restart, stable key identity, byte-identical
saved archives before/after signing, pending encrypted delivery/staged commit
preservation, exact-body tamper rejection and malformed request refusal. An
initial test incorrectly treated repeated `next_outgoing` encryption as an
idempotent peek; that assertion was corrected to preserve exact archive checks,
not changed in the engine. The synthetic restored-peer example emits only
bounded public proof JSON; the actual SQLite/workerd group route accepts it and
rejects its replay under an operator-specified policy. Dedicated interoperability
now passes all 16 checks with zero skips (11.84s).

Strict sync all-target checks with `relay-auth,http` pass (7.06s), as do the
strict workspace/all-target checks using the CI's new `cash_sync/relay-auth`
feature selection (15.86s). No cloud job was dispatched. The complete relay
suite passes 54 checks with three explicit fixture skips (57 total, 15.74s);
those three fixtures are separately verified by the dedicated command.
The optional signer is not yet enabled by the app API/FRB or HTTP client, so
the existing cached native and WASM app bridge artifacts are unchanged.

The full sync command
`cargo test --manifest-path rust/Cargo.toml -p cash_sync --features relay-auth,http
--locked --offline -j 1` subsequently passes 74 tests, including the 1,000-event
three-peer byte-identical convergence/removal scenario (127.93s). Its two
explicit live-HTTP integration tests remain ignored by this command, not passed.
Log: `app/.dart_tool/peer-request-sync-retry.log`; relay retry log:
`app/.dart_tool/peer-request-relay-retry.log`. The interoperability runner now
builds both cached examples before generating any short-lived proof, so a
cold-cache compilation cannot consume an earlier fixture's 50-second lifetime.
The final interoperability rerun with that build ordering passes all 16 checks
with zero skips in 7.82s.

The initial broad run failed to link new debug test binaries while C: fell to
about 35 MB free; concurrent workerd checks explicitly reported `SQLITE_FULL`
and startup failures. Preserve those failed logs as environment evidence, not
passing tests or a software fix. After both owned runs were terminal, all 2,467
generated dependency/test-cache files (7,114,183,912 bytes) were moved using
native PowerShell to `D:/cash-app-toolchains/cash-app-rust-debug-deps`, with
per-file length and total count/byte checks. A junction preserves the original
`rust/target/debug/deps` path. Only empty old cache directories were removed;
no source, private ledger, native app DLL or useful artifact was discarded.
C: now has about 6.7 GB free; the unchanged suites pass after this cache move.
This local cache placement is not a repository/CI dependency or a toolchain
upgrade. Authentication/deployment, bridge signing, roster and mailbox gates
remain open.

## Public app bridge signing interface (2026-10-03)

The app API now enables the protected-peer signer through its existing sync
dependency. `household_sign_relay_request` accepts exact request fields and a
signed-64-bit expiry, refuses negative or JS-unsafe expiry values, and returns
only public proof bytes. The API does not send requests, register devices or
change MLS/ledger state. Two test-first API checks and the full 66 API tests
pass; a rebuilt native FRB library directly passes the fresh-nonce/restored-key
and exact invalid-expiry checks. All 346 native-enabled Flutter tests pass.
`PHASE2-PROGRESS.md` records exact commands, prior test/environment failures,
artifact paths and verification limits.

Bindings now require Rust content hash `-155377132`; older bridge binaries do
not match. Native and production WASM artifacts were rebuilt with the pinned
toolchains; the old artifacts were preserved locally. This is not a claim that
the app HTTP client signs requests yet, that the new signing method ran inside
the browser, or that current Android/iOS binaries passed. Trusted registration,
dynamic roster/mailbox/socket authorization, authenticated end-to-end transport,
safe recoverable pruning and authorized $0 deployment remain open.

## Opt-in HTTP proof provider (2026-10-03)

`HttpRelayClient` now accepts an optional `RelayRequestSigner` callback. For
every page and append/mailbox request it supplies the exact method, URI and
encoded body bytes, then attaches the returned public proof header. Body
encoding happens once; the provider receives a defensive copy and cannot alter
the bytes later sent. Proof headers are bounded to 1,024 printable ASCII
characters. Their cryptographic validity and trusted grants remain server
responsibilities, not a client-header-validation claim.

Signing is awaited within the request's 20-second budget. A timeout, thrown
Rust string/Dart error, empty/oversized/header-injection result prevents any
request, reports trusted local copy and never falls back to unsigned traffic.
A regression actually waits out the deadline and completes the provider later:
no late transmission follows. Reads and mutations share abortable streaming
and the existing 6 MiB reply bound. Existing paged validation, fixed-frontier
reads and durably confirmed progress are preserved.

Test-first wire regressions cover all six route variants, exact bytes despite
provider mutation, failure/no-network behavior, per-page invocation and late
completion. The first implementation used an unsupported constructor header
argument; installed http 1.6.0 instead requires populating request headers.
The corrected path passes 42 combined transport/native-bridge encrypted
backfill/receipt tests in 20 seconds before the final per-page check was added.
Dart analysis is clean (2.4s). Final focused log:
`app/.dart_tool/signed-http-tests.log`. No Rust API/bridge changed in this concern.
The final focused transport run passes all 24 checks in 20 seconds, including
the added exact continuation-URL/per-page provider check.

This is an opt-in wire capability, not controller enrolment or a real app-signed
HTTP/MLS acceptance run. Tests use a controlled proof callback and HTTP mock;
the default controller still supplies no signer. Native/WASM protected-key
adapter, trusted device registration, mailbox/roster authorization and final
platform verification remain open. The production browser artifact still
predates these Dart transport changes; no current-browser claim follows.

## Protected controller provider and lifetime checks (2026-10-03)

`HouseholdController.relayRequestSigner` now adapts the real protected identity
to HTTP's optional callback. It signs the exact encoded URI path/query and body,
uses a 50-second expiry from a checked JS-safe clock, refuses credentials or
fragments in the URL, and returns only the four documented hex/public fields.
It does not enqueue behind the sync waiting for its own proof. Signing changes
no saved household bytes, and restoring the archive preserves the public key
while producing a fresh nonce.

The provider checks writable/unlocked identity before and after the asynchronous
native call; changed/abandoned handles, lock-state transitions and controller
disposal discard the result. Disposal revokes proof access without freeing a
Rust handle underneath existing queued borrows. The default relay factory still
does not attach this provider: trusted enrolment and transport enablement are
not silently inferred from possession of a signature.

Three test-first controller regressions extend the real native bridge tests.
The actual relay signature verifier accepts the generated GET proof and a POST
proof routed through `HttpRelayClient`/a controlled HTTP mock, rejecting changed
query and transmitted-body bytes. The verifier uses the previously observed
expected public key; it is cryptographic conformance, not a self-registration
or authorization test. Other checks cover restored identity, no archive writes,
closed/abandoned identities and controlled lock/disposal during a pending proof.
An initial uncertain-save fixture lacked a relay URL and stopped before saving;
configuring its in-memory relay correctly exercises the intended failure.

All five proof/controller native checks and all 353 native-enabled app tests
pass (full suite 2m08s); analysis reports no issues (3.2s). Command from `app`:
`RUST_LIB_PATH=<cached current native DLL> flutter test --no-pub`; log:
`app/.dart_tool/controller-request-proof-full.log`. No Rust API/ABI changed,
and no platform toolchain rebuild was needed. Current browser/mobile provider
runtime, actual authenticated HTTP/MLS exchange, trusted registration, dynamic
roster/mailbox authorization and authorized deployment remain open. The lock
test manipulates controlled controller lock state; it is not new native
biometric or vault-UI acceptance.
