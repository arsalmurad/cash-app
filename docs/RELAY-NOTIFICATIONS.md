# Authenticated local relay notifications

Verified 2026-10-05. This is an explicitly enabled owned-loopback transport,
not public registration, deployment, app auto-sync or final-platform acceptance.
Default public routing and ordinary authenticated HTTP behavior stay unchanged.

## Contract and authorization

The roster worker accepts `GET /g/{group}/ws` only with
`LOCAL_AUTH_SOCKETS=true`, `LOCAL_AUTH_MEMBERSHIP=true`, a valid independently
configured root and its exact loopback origin/group. No query aliases are
accepted. Public URLs still return 503; absent socket opt-in returns 403.

An upgrade needs a fresh existing Ed25519 request proof over the canonical
**HTTP/HTTPS** origin, `GET`, exact `/g/{group}/ws`, empty body digest, nonce and
expiry. The ordinary 60-second signature window, persisted monotonic clock,
one-use replay inventory and device/group daily request budgets apply.
WebSocket URL conversion to `ws`/`wss` does not change the signed HTTP origin.
The existing current `read` grant authorizes these read-metadata notifications;
no new policy schema or implicit membership-manager grant is introduced.
Admission uses a distinct exact-scope helper, so history/append proofs cannot
open sockets. Removed devices' bounded historical reads do not grant live
subscriptions. Current grants are rechecked inside the admission transaction.

Native callers may supply `x-cash-device-proof`. Browser-compatible callers
supply exactly one `Sec-WebSocket-Protocol` token:
`cash-request.` followed by unpadded canonical base64url of the same proof JSON.
The successful response selects that exact token. Ambiguous header plus token,
extra protocols, padding/noncanonical encodings, malformed/expired signatures
and values over 1,024 characters are refused. These are public signed metadata,
not secret keys; captured proofs cannot create another accepted connection.

There are at most two **open** connections per current device and 128 total
connections per group, including transports still completing close handshakes.
Capacity refusal spends no nonce/budget. Quota refusal rolls back admission and
returns Retry-After without terminating an existing listener.

## Hibernation API and membership lifecycle

The worker calls `acceptWebSocket`, not ordinary `accept`/event listeners, and
serializes only `{version, publicKey, origin, group}` on the server connection.
It has no in-memory connection registry, heartbeat timer, financial queue or
long-lived waitUntil promise. Identity survives instance reconstruction through
the runtime attachment. These APIs follow [Cloudflare's hibernation guide](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)
and [state API](https://developers.cloudflare.com/durable-objects/api/state/).
Local tests prove runtime attachments and a fresh class instance, **not actual
cloud eviction/revival or billed-duration behavior**.

After a durable append, the current committed roster/root/tail are loaded under
a short local concurrency gate before any notification is sent. Removed keys,
revoked read grants and malformed/untrusted attachments are closed before that
append's tail can reach them. Unchanged readers remain connected across epochs.
Only `{"tail": n}` is sent; it is a lossy advisory hint, not a financial event
or delivery acknowledgement. A notification failure cannot undo a committed
append; unavailable authority closes listeners rather than exposing metadata.
Concurrent callbacks read the current tail instead of publishing an older tail.

Any client application message closes the connection with code 1008. It is not
parsed as JSON or persisted, and cannot append/modify financial state. Runtime
transport errors close with 1011. A future app client must always backfill through
the authenticated HTTP saved-before-ACK path on open/reconnect and after hints;
it must not treat socket messages as ledger state or offline retention consent.

## Independent verification

Pinned Windows Node 24.19 / Miniflare 4.20260730.0 / workerd SQLite, Rust stable
1.98.1. Existing dependencies/caches were reused; no Flutter/mobile/WASM rebuild,
toolchain upgrade, cloud job, account configuration or public deploy occurred.

- Final 16-file package test suite with `--test-concurrency=2` and
  `RUST_NOTIFICATION_INTEROP=1`: **91 tests, 88 pass, three optional existing
  Rust-fixture skips, zero failures** (43.61 s). The files are the list in
  `relay/package.json`'s `test` command; two-worker concurrency bounds host memory.
- `cd relay; npm run test:request-proof-rust`, with `RUSTUP_TOOLCHAIN=stable`
  and locked/offline cached compilation: **21 tests pass, zero skips/failures**
  (16.33 s test runtime). This executes those three existing Rust fixtures plus
  fresh opaque Rust identity signatures for native-header and real network
  browser-compatible notification handshakes. Cold builds finish before any
  short-lived proof is produced; private labels/keys never leave the fixture.
- The enhanced owned launcher test separately passes (1 test, 2.12 s):
  `node --test --test-name-pattern="owned development launcher"
  test/roster-worker.test.js`. A real standard network client receives a signed
  tail across a membership addition, proving the launcher forwards socket opt-in
  and unchanged reader identity remains authorized. The preceding full suite
  ran before that test-only launcher enhancement.
- Focused tests exercise unsigned/foreign/expired/wrong-scope requests,
  exact selected protocol, replay, malformed carriers, two-per-device caps,
  64 actual trusted identities/128 workerd sockets, global-cap rollback,
  daily quota rollback, current read-grant revocation, removed-device close,
  unchanged active readers, fresh-instance notification delivery, and a
  plaintext-looking incoming negative control with unchanged actual KV rows.
  Transport attachments/public keys/counters are metadata, not anonymity.

Ignored logs under `app/.dart_tool`: `roster-sockets-focused.log`,
`roster-sockets-admission.log`, `roster-sockets-relay-final-suite.log`,
`roster-sockets-rust-interop-final.log`. `rustfmt +stable --check` passes for the
changed example; JavaScript syntax and `git diff --check` pass.

### Failures kept separate

The baseline test failed because opt-in sockets still returned the closed 403
route. The first implementation test's malformed protocol never reached workerd:
Node's client rejected the invalid token itself. Those parser negatives now use
ordinary HTTP, while valid selected protocols use actual upgraded/network clients.
A subsequent double-close in test cleanup masked a later observation failure
and left the finished test child alive; cleanup now checks open state and always
disposes the owned worker. That exact already-finished child was terminated once
to flush its failure; no forced-exit result is counted as green.

A two-second close observation timed out although the removed peer had received
no tail and was no longer an open server subscription. Real network clients and
a bounded forty-second close-handshake allowance pass; observed full scenarios
take roughly eleven seconds. This is not a claimed renderer/toolchain repair.
The quota fixture initially used a forbidden POST history route; correcting only
its test-only seed route to `/append` then passes. A wrong formatter relative
path and formatting check failed before compilation; both were corrected before
the reported interoperability pass.

## Optional local use and remaining gates

Follow [LOCAL-RELAY-SETUP.md](LOCAL-RELAY-SETUP.md), then add
`$env:LOCAL_AUTH_SOCKETS = 'true'` before starting `node dev-server.mjs 8787`.
The existing app still uses authenticated HTTP/manual sync; socket lifecycle,
unlock/lock/close, foreground/background, reconnection/backfill, notifications
during uncertain saves and final app-platform acceptance remain to be connected
and verified. This server capability alone does not close the full notification
or Phase 2 gate. Trusted public registration, account-wide anonymous abuse/cost
bounds, authorized free hosting and actual cloud hibernation remain open.
