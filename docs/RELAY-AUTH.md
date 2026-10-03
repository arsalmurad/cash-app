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

## Explicit operator-rooted local roster routing (2026-10-03)

`roster-worker.js` now routes the transaction primitive only when both
`LOCAL_DEVELOPMENT=true` and `LOCAL_AUTH_MEMBERSHIP=true` are explicit and a
strict trusted `LOCAL_AUTH_POLICY` names one exact loopback origin/group. The
development launcher selects its SQLite `RosterGroupLog` only for the membership
flag; selecting the mode without a policy fails closed, not unsigned. Wrangler
and the shipped default worker remain unchanged/public-closed.

The first authorized operation initializes only empty storage, saving an
immutable `authorization_root`, current policy and request budget. Existing
fixed/legacy storage without that root is refused; changing operator authority
does not overwrite a saved root or reset replay clocks/budgets. Verification
uses a trusted saved roster snapshot, then every transaction rechecks the live
scope/grant after asynchronous work. Admission refusals throw to roll back even
bootstrap writes. Unknown scopes, malformed cursors and unsupported routes are
rejected before allocating a Durable Object.

Authorized group reads/appends and `GET /g/<id>/policy` use fresh nonce/budget
admission. The policy response contains only bounded public authorization
metadata. `POST /g/<id>/membership` combines exact signed opaque ciphertext and
next policy with current permissions, monotonic server time and bounded retired
replay cleanup in one transaction. Authorization epoch is distinct from proof
of MLS epoch/roster. No welcome/mailbox, socket, pruning or anonymous signup
route is enabled, and app membership coordination is not yet integrated.

Test-first actual SQLite/workerd checks pass for empty trusted bootstrap,
concurrent membership CAS (one winner), newly granted-device access, immediate
revocation of an already signed request, immutable root/config-change refusal,
legacy-adoption refusal and no unauthorized allocation. The actual owned Node
launcher independently serves policy/membership and admits the newly granted
device. Fixture inspection/seed/config controls exist only in its test subclass.

The complete relay suite passes 58 checks with three optional Rust-fixture
checks skipped (30.42s); log `app/.dart_tool/roster-routing-final-relay.log`.
Both actual native fixed-policy HTTP/storage cases pass (38s), recorded in
`app/.dart_tool/roster-routing-native-compat.log`; this is compatibility evidence,
not app-level roster integration. No Rust ABI rebuild, install, cloud job or
deployment was needed. Public bootstrap/account abuse, app MLS commit/retry/
Welcome/recovery coordination and final platform gates remain open.

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

## Native app exchange over actual authenticated HTTP (2026-10-03)

`app/test/household_authenticated_http_host_test.dart` runs two real native
controller identities through HTTP sockets to the owned loopback development
launcher and its authenticated SQLite/workerd group. Membership and the welcome
are prepared using `MemoryRelayClient`, then the test operator explicitly pins
those two public keys in the fixed group policy. Original MLS ciphertext is
appended into fresh authenticated storage using genuine signed HTTP requests;
no legacy adoption, debug endpoint or request-supplied self-enrolment is used.

Both controllers are restored from saved journals and explicitly supplied with
the signing callback. Alice produces 18 expenses while Bob is offline, Bob
backfills across multiple pages and adds one expense, and both agree on
`USD -20.50`. A further restored Bob agrees too. Idle sync does not append an
ACK-of-ACK loop. Actual responses reject unsigned/unknown-device requests (401),
replayed proofs (409) and a changed signed body (401), without advancing history.
Returned opaque log bytes do not contain the synthetic expense titles. This is
a wire-content check, not a new direct inspection of every SQLite storage field.

The scoped Windows native test passed in 8 seconds with the cached current DLL,
Node 24.19.0 and local workerd. It starts only its own loopback process and cleans
up that process tree. No public deployment or CI run is dispatched. This closes
the native authenticated HTTP/MLS exchange gap for the fixed pre-trusted policy,
not trusted dynamic enrolment, invite/mailbox authorization, membership changes,
real disk/vault persistence or browser/mobile acceptance. Default app transport
remains unsigned until those enablement gates are resolved.

Verification from `app`: `RUST_LIB_PATH=<cached current native DLL> flutter test
--no-pub test/household_authenticated_http_host_test.dart
test/household_request_proof_host_test.dart
test/household_paged_backfill_host_test.dart test/relay_client_test.dart` — all
33 tests pass (35s), recorded in `app/.dart_tool/authenticated-http-host.log`.
`flutter analyze --no-pub` reports no issues (3.2s). An initial analysis-only
brace-style notice was repaired; the actual HTTP scenario passed before and
after that formatting repair. No bridge regeneration or platform rebuild was
needed for this test-only concern.

## Inspect authenticated storage from the native app run (2026-10-03)

The native HTTP test now runs a second case with
`relay/test/native-app-audit-relay.mjs`. This test-only launcher loads the same
authenticated group implementation into SQLite-backed workerd and adds an
inspection method to its fixture subclass. Its owning Node process invokes that
method through a direct Durable Object binding after a stdin command; the
externally routed worker does not expose the inspection URL (HTTP 403 is tested).
Neither the production worker nor the development launcher is changed, and no
storage seeding is available.

`authenticated-storage-audit.js` inspects every persisted KV row, requires the
exact trusted operator policy and only the documented fields for ciphertext,
capacity, public keys, nonce/expiry records, server clock and request budgets.
It matches all contiguous ciphertext records to the stored tail/byte counts,
requires a nontrivial log, and scans encoded metadata plus decoded payloads for
synthetic account/member/transaction/title/balance markers, signed i64 amount
representations in both byte orders and the durable-receipt marker. Deliberate
plaintext ciphertext, extra budget amount and nested roster-name injections
must each make the scanner fail. Legitimate public-key/scope/timing/counter
metadata remains visible; this is not a claim of metadata anonymity.

Both native HTTP cases pass (16s), including the original unmodified launcher
case; `app/.dart_tool/authenticated-storage-native.log` records the run.
Analysis reports no issues (3.2s). The cached relay regression suite passes
54 tests with three optional Rust-fixture checks skipped, not counted as
passes (18.86s); log `app/.dart_tool/authenticated-storage-relay-tests.log`.
No rebuild, install, cloud job or deployment was needed. This strengthens
authenticated native-group storage evidence, not mailbox storage, raw database
file forensics, disk/vault persistence, dynamic enrolment or final platforms.

## Atomic membership transaction primitive (2026-10-03)

`request-membership.js` adds a transaction-local operation, not a routed signup
or roster endpoint. `GroupLog.append` has an optional after-append callback
inside its existing storage transaction; throwing from that callback rolls back
ciphertext, tail, capacity and policy/admission writes together. Default/local
routes supply no callback and retain their existing public-closed behavior.

The primitive rehashes a defensive wire-body copy against the immutable
verifier's recorded digest. It accepts exactly expected tail, opaque blob and
bounded nonfinancial policy, requiring exact membership scope, the current
transaction's grant and the next sequential authorization epoch (not proof of
an MLS epoch). It checks the exact ciphertext appended at that slot in the same
transaction, admits the nonce, spends the request budget and writes the policy.
Extra financial fields, foreign scopes, skipped/stale epochs, permissionless
callers and loss of all membership-capable devices fail closed. Removal does
not reset replay records or spent budgets.

The real SQLite/workerd fixture verifies grant addition/removal, exact saved
state, substituted-body refusal, stale retry without mutation, malformed/foreign
policies, read-only and removed-device denial. A failure after all writes rolls
back everything; the identical signed request then succeeds. Only the in-memory
fixture exposes inspection/seed/fault commands.

`npm test` passes 55 checks with three optional Rust-fixture checks skipped
(21.69s); log `app/.dart_tool/membership-transaction-relay.log`. Both actual
native authenticated HTTP/storage cases still pass (21s), logged in
`app/.dart_tool/membership-hook-native-http.log`. No ABI rebuild or deployment
was needed. Next integration requires trusted bootstrap/current-policy routing,
bounded retired replay-key storage during churn, current server time at admission,
and app MLS commit/Welcome/retry/recovery coordination. The relay cannot inspect
the opaque MLS commit: permission grants do not prove its cryptographic roster.
Default/fixed local routes are not dynamically enrolled. Public deployment,
mailbox, socket, pruning and final-platform gates remain open.

## Bound replay-key retention during membership churn (2026-10-03)

The unrouted membership primitive now performs a bounded prefix read of at most
129 nonce-key rows and refuses oversized legacy inventories (503), rather than
scanning them without a limit. It strictly validates each bounded nonce record
collection and reserves capacity for every proposed current device, including
devices that have not sent a request yet. At most 128 current/reserved plus live
retired keys may remain. A change exceeding that bound is refused (429) without
evicting replay protection, changing policy/history or consuming the retry nonce.

Only retired keys whose entire record collection has expired at the admitted
monotonic server clock are deleted; current keys, unexpired revoked records and
spent request budgets remain. Cleanup is inside the same transaction as the
encrypted membership append. It deletes no financial ciphertext. Corrupt record
collections require repair (503), not silent cleanup. Oversized legacy state
requires explicit bounded migration; this is not an account-wide free-plan cap.

The test-first SQLite regression initially accepted a 129th reserved/live key
(200 instead of 429), then passes with the bound. Real workerd checks preserve
every row on capacity refusal, safely reuse the refused signed request after
retired expiry, reject corrupt/oversized state unchanged, and roll back expired
key deletion when a subsequent injected commit failure occurs. Expiry follows
the stored monotonic clock even when the test wall clock is behind it.
The full `npm test` suite passes 55 checks with three optional Rust-fixture
checks skipped (17.82s); log `app/.dart_tool/bounded-membership-relay.log`.
No routed worker/app/ABI was changed or rebuilt. Trusted bootstrap/current-policy
routing, actual time integration, app membership retries and deployment gates
remain open.

## Derive relay keys from the actual staged MLS tree (2026-10-03)

`Peer::relay_roster_keys()` now returns only sorted, unique 32-byte signing
keys for the current roster or the staged post-commit roster. Its crypto helper
uses the pinned OpenMLS 0.9.0 pending commit's public tree export, not a cloned
private archive, a hand-assembled identity list or an early merge of the real
commit. The API was checked against installed dependency source:
[StagedCommit public-tree export](https://docs.rs/openmls/0.9.0/src/openmls/group/mls_group/staged_commit.rs.html).
Member names, financial data and private/encryption keys are not returned.
Unjoined/inactive peers, missing pending member trees, duplicate/wrong-size
keys and projections exceeding 64 devices fail closed.

Four test-first core regressions initially fail at the absent method, then pass
for founded/unjoined peers, exact staged invite/removal projections, unchanged
byte-identical archives/current rosters, rejected commits and staged restarts.
Projected keys match both the committed sponsor and welcomed member. Removed
devices are refused. A real 64-member tree passes; the 65th staged key fails
before confirmation, remains refused after restart, and rejection restores the
previous roster without silently truncating it. Initial test-only unnecessary
mutable bindings were removed rather than suppressing warnings.

All 35 affected sync checks pass with locked/offline `cash_sync --features
relay-auth` tests `relay_roster`, `relay_request`, `restart`, `steps` and
`recovery_gap`; log `app/.dart_tool/relay-roster-sync.log`. All 25 crypto
integration checks pass with `cash_crypto --features relay-auth` tests `group`,
`recovery` and `relay_request`; log
`app/.dart_tool/relay-roster-crypto-integration.log`. The initial library-only
target had zero tests and is not counted as verification. Strict all-targets
Clippy for both crates with HTTP/relay-auth features passes (7.26s).

This is a read-only Rust capability, not an app bridge or server enrolment
change. Generated ABI, cached native/WASM artifacts and app defaults are
unchanged; no current-platform runtime claim follows. App bridge exposure,
validated policy transport, durable membership/Welcome/retry coordination and
public deployment remain open.

## Public roster bridge exposure (2026-10-03)

`household_relay_roster_keys` now exposes the verified Rust projection as
`List<Uint8List>` through regenerated native/web FRB bindings. It holds the
household mutex only for the read-only query and returns bounded public signing
keys, not names, ledger fields or private state. A test-first API check fails
at the missing function, then passes for unjoined refusal, staged invite/
removal, byte-identical archives, rejected commits and staged restoration.
All 67 Rust API tests pass (0.85s).

The real native bridge test independently verifies sorted unique 32-byte keys,
actual Welcome/committed-roster agreement, rejection and restart, unchanged
current member IDs before commit and unchanged saved archives. Mutating a
returned Dart key does not mutate the Rust identity or a subsequent response.
All 25 focused roster/proof/paging/protected-save checks pass (36s). Analysis
reports no issues (32.9s); strict all-targets API Clippy passes (20.50s).

Regeneration changes the ABI hash to `970902974` (previous `-155377132` is old).
The rebuilt native DLL is 14,958,592 bytes and the release WASM bridge is
6,305,277 bytes. Previous artifacts are preserved in ignored
`app/.dart_tool/bridge-before-roster-keys.dll` and
`app/.dart_tool/web-bridge-before-roster-keys/`. The pinned Windows release
helper succeeds in about 1m15s, retaining the known atomics warning; its
wasm-bindgen installation message is not evidence of a new download.
Logs: `roster-bridge-generation.log`, `roster-bridge-api-tests.log` and
`roster-bridge-wasm-build.log` under `app/.dart_tool`.

This directly exercises the new method on native only. The production Flutter
browser app and existing Android/iOS artifacts predate the new ABI; rebuilding
a WASM bridge is not browser acceptance. Controller lifetime/lock integration,
validated policy transport, durable app membership/Welcome/retry coordination
and final platform verification remain open. Do not combine old app/generated
bindings with the new native/WASM library or infer server authorization from
the returned keys.

The full native-enabled `flutter test --no-pub` suite subsequently passes all
356 checks (3m31s) with `RUST_LIB_PATH` set to the rebuilt DLL, including both
actual fixed-policy HTTP/storage cases. Log:
`app/.dart_tool/roster-bridge-full-app.log`. This closes current native ABI
compatibility for these app tests, not browser/mobile roster acceptance.

## 2026-10-03 — opt-in app policy/membership HTTP transport

`RosterRelayClient` is a separate, explicitly enabled capability. The default
factory remains unsigned and roster-disabled; supplying a proof callback alone
does not enable policy or membership requests. `RelayAuthorizationPolicy`
accepts only exact v2 public fields, canonical scoped origins/groups, bounded
sorted unique signing keys/grants and a safe integer epoch. Defensive immutable
copies prevent parsed or exported objects from mutating policy. Projected MLS
survivors retain their grants; new members receive the app's three standard
capabilities. This is public authorization metadata, not an MLS certificate.

Policy reads and membership writes use the existing bounded, deadline-limited
HTTP reader and fresh exact-body signer. Membership acknowledges only the
expected next log slot; malformed responses and refused requests do not prove
rejection. Tail conflicts remain distinct from policy conflicts; no remote
diagnostic is presented as trusted app text. Noncanonical/insecure addresses
are refused before proof generation or networking.

Independent Windows checks: analysis has no issues (2.4s); all 31 focused
policy/HTTP checks pass (24s). The real native bridge plus owned loopback
Node/workerd SQLite relay passes `household_roster_http_host_test.dart` (1s):
an actual pending MLS invite is exported/restored, its exact encrypted commit
and projected public roster are atomically accepted, retry confirms tail 1
without a second entry, and Bob joins using the returned Welcome. A real
removal commits tail 2 and revokes Bob's fresh and previously signed requests;
Bob applies the removal and cannot project an active roster. Logs:
`app/.dart_tool/roster-policy-transport.log` and `roster-native-http.log`.

The retry is explicit after an observed successful response, not an injected
network loss or implemented controller recovery. Bootstrap is operator-trusted,
Welcome delivery is out of band, native handles are test-owned, and no public
relay is deployed. Durable controller policy/commit/Welcome orchestration,
protected roster access and final browser/mobile acceptance remain open.

Full native-enabled `flutter test --no-pub` then passes all 364 checks (2m37s),
including existing fixed-policy HTTP/storage and new roster HTTP cases, with
the current ABI `970902974` DLL. Log:
`app/.dart_tool/roster-transport-full-app.log`. No native/WASM rebuild was
needed for this Dart-only transport change; browser/mobile runtime claims
remain unchanged.

## 2026-10-03 — protected controller roster access

`HouseholdController.relayRosterKeys()` now owns the native query and returns
an immutable public-key list, without changing saved state or queueing behind
sync. Writable/identity/closed checks run before and after the native await.
Ten focused native controller, signer, roster and actual SQLite HTTP checks
pass (6s); analysis is clean (2.8s). Tests compare the roster key with the
protected request identity, restore unchanged saved bytes, and refuse results
when lock/disposal occurs in flight or persistence has abandoned the handle.
Log: `app/.dart_tool/roster-controller-access.log`. Controlled lock flags are
not biometric/browser-vault UI evidence. No default transport is enabled and
durable policy/commit/Welcome orchestration is still separate work.

All 23 additional journal, uncertain-save and durable paged-sync regressions
pass (16s), recorded in `app/.dart_tool/roster-controller-regressions.log`.
The 364-check full suite above predates this isolated getter; current revision
verification is the 33 affected checks plus clean analysis, not a new full run.

## 2026-10-04 — controller journals exact membership transitions

The opt-in controller now reads a scoped policy matching its confirmed MLS
roster before staging an add/removal, derives the next policy from protected
projected keys, and saves policy/slot/commit with the private Rust state before
network I/O. `PendingRelayMembership` strictly validates exact v1 fields,
safe bounds and public policy; copied ciphertext and immutable policy survive
restart. Journal decoding rejects a foreign relay; controller restoration
rejects a foreign household. Existing v1/v2/raw journals remain readable.

Sync sends this exact saved transition through `appendMembership`, never
ordinary append. Successful native acknowledgement or ordered MLS ingestion
clears intent; offline/capacity/policy failures retain it. A confirmed losing
slot may discard it through native ingestion, not a timeout. Relay switching
and saved-state receipts remain blocked while intent is pending; recovery and
vault lock do not reuse it for a replacement identity. Unsent invalid projected
policies reject the local staged commit and save before any write. Financial
requests in opt-in mode verify current roster policy too, so a legacy pending
add/removal without policy metadata cannot silently use plain append.

Twelve focused native/journal checks initially pass (2s), including four
controlled removal failures and a lost invite response followed by failed
Welcome delivery across two restarts. The full native-enabled suite then
passes 374 checks (2m37s) before the final foreign-scope/exhausted-epoch guards
and added failed-save/missing-metadata cases. Logs:
`membership-controller-retry.log` and `membership-intent-full-app.log` under
`app/.dart_tool`. Final scoped regression evidence is recorded below.

These retry tests use actual native MLS and saved app journals with a controlled
in-memory relay. Its working mailboxes do not prove real-worker authorization:
the loopback roster worker still refuses mailbox routes. Public trusted
enrolment, actual authenticated Welcome delivery, owned HTTP controller
failure injection and final browser/mobile acceptance remain open. The app's
default factory remains unsigned and roster-disabled; no deployment occurred.

Final analysis is clean (65.6s); all 37 affected native/journal/controller-save
and paged-sync checks pass (22s), including explicit foreign-policy and
exhausted-epoch refusal, failed-save-before-send and missing legacy metadata.
Log: `app/.dart_tool/membership-final-regressions.log`. This is current-source
scoped evidence; the earlier 374-check full run is deliberately distinguished.

## 2026-10-04 — atomic public invitation authority

Accepted policy transitions now update `invite_authorities` in the same SQLite
transaction as ciphertext, policy, nonce, monotonic clock and budget. Only keys
newly added by that transition receive a record: public recipient/sponsor keys,
accepted sequence, immutable seven-day expiry and initially null mailbox ID.
At most 64 exact sorted records are allowed; no names, amounts, private keys,
Welcome plaintext or caller-supplied delivery authorization is stored.

Survivors retain their original expiry/binding, removal revokes authority and
re-add gets a new slot. Missing authority starts empty without granting older
members retrospective delivery permissions; damaged or oversized authority
refuses the transaction rather than silently discarding records. Expiry uses
the existing admitted monotonic request clock, not an independently reset clock.

Seven focused checks pass (9.39s), including actual SQLite failure/rollback
after authority writes and corrupt/65-record refusal with unchanged ciphertext,
nonce and budget. The full relay suite passes 61 checks plus three explicit
optional Rust-fixture skips (23.41s). Actual native MLS over the owned loopback
roster relay still passes (1s). Logs under `app/.dart_tool`:
`invite-authority-relay.log`, `invite-authority-full-relay.log`,
`invite-authority-native-http.log`.

This establishes the authority needed by authenticated Welcome delivery; it
does not yet route upload/read/ack requests or prove mailbox lifecycle. Default
public access remains closed and no account/deployment authorization changed.

## 2026-10-04 — authenticated group Welcome routes

The explicit loopback roster worker now accepts `PUT /g/{group}/invite/{id}`
with exact `{recipient,joined_after,welcome}`, recipient-only GET, and
recipient-only empty POST `/ack`. All calls use exact scope/body device proofs,
current grants, nonce admission and spending inside the operation transaction.
Uploads must match authority minted by an accepted membership slot and its
original sponsor. Random IDs, a generic membership grant, another recipient
or a fabricated slot do not authorize upload/read/ack. There is no `/take`.

A bounded sorted 64-entry metadata index avoids reading all Welcome blobs
for normal capacity checks. The first upload binds its mailbox ID; conflicting
bytes/IDs cannot replace it. Acknowledgement is idempotent and retains an opaque
tombstone until the original seven-day expiry, so exact upload retries cannot
resurrect a consumed Welcome. Full inventory refuses new growth (507); corrupt
or oversized inventory fails closed. The transactional alarm validates expired
payloads, deletes only `welcome:` ciphertext, updates its bounded index and
next alarm, and preserves the maximum observed server/admitted clock floor.
Ledger ciphertext and current permission policy are never pruned by this path.

Actual SQLite/workerd checks cover sponsor/recipient refusal, extra financial
fields, replay, idempotent read/ack/upload, immutable expiry, one-mailbox binding,
64/65-record inventory refusal and a fault after all writes (including alarm)
with exact rollback/reusable nonce. Expiry is driven by a controlled admitted
clock floor, not seven days of wall-clock waiting. Eight focused route/scope
checks pass (3.34s), including 256 KiB maximum-size delivery, refusal of empty,
noncanonical and one-byte-oversize blobs, and browser preflight for paged `?after=0` reads and
PUT routes. The broader relay suite passes 62 checks plus three optional
Rust-fixture skips (26.46s) before the final isolated alarm clock-floor guard
and added size-boundary assertions; these pass the eight affected checks. Logs under `app/.dart_tool`:
`roster-welcome-routing.log` and `roster-welcome-full-relay.log`.

The actual native HTTP test now uploads an OpenMLS-produced encrypted Welcome
with Alice's protected request identity; Bob retrieves it before joining,
joins from the HTTP-returned bytes, then acknowledges/retries without reopening
delivery. Sponsor read is refused and later removal still revokes Bob. Analysis
is clean (4.2s) and this owned loopback native scenario passes (2s), recorded in
`roster-welcome-native-http.log`. Raw test requests are not durable controller
save ordering, app UI, browser/mobile runtime or storage-audit acceptance.
Controller/client mailbox capability, public enrolment/account caps and final
platform verification remain open; default/public routing is still closed.

## 2026-10-04 — bounded app Welcome transport

`RosterWelcomeRelayClient` adds explicit group-scoped upload/peek/ack without
changing the default factory or existing unsigned/fixed-policy clients.
`HttpRelayClient` uses its common signed, abortable, deadline-limited bounded
reader for every attempt. Invalid IDs, recipients, slots and payload sizes are
refused before proof/network; peek accepts only exact matching group/slot fields
and canonical nonempty base64 up to 256 KiB. Write/ack replies must be exact
`{ok:true}`. Refusals use trusted local copy, including 507 storage capacity.
Roster-enabled clients refuse every legacy mailbox operation, including take,
without issuing a proof or request; there is no unsigned/path fallback.

Analysis is clean (3.4s); all 37 focused scoped/legacy/policy/native HTTP checks
pass (20s), logged in `app/.dart_tool/roster-welcome-transport.log`. The actual
native OpenMLS scenario now uses the production bounded client methods rather
than raw test HTTP for upload/read/ack/retry; Bob joins from the returned bytes
and sponsor reads fail. This still does not prove controller-managed durable
join/save/ack ordering or current mobile/browser UI. Those remain next work.
