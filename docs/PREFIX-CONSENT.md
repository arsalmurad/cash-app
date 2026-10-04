# Explicit relay prefix consent

Implemented and locally verified 2026-10-04. **Not a completed end-to-end app
retention feature.** The Rust signer and actual SQLite roster worker now enforce
separate, unanimous deletion consent. Normal launch remains disabled; only an
explicit `LOCAL_AUTH_RETENTION=true` in owned loopback roster mode enables
`POST /g/{id}/prune`. Public routing remains closed. No cloud jobs were dispatched.

## Permission, not a receipt cutoff

`Peer::sign_prefix_consent(saved, request)` is read-only. It requires the exact
latest archive, active unstaged membership, no unsent work, authenticated history,
and a valid collected saved-state receipt from every current MLS signing key for
the same checkpoint. It refuses a target beyond the minimum acknowledged cursor,
an incorrect policy/MLS epoch, unknown recovery holder, invalid origin or expiry.
The caller still owes a confirmed protected-storage read-back and retention of a
recoverable archive: Rust cannot infer those from bytes.

The binary consent has a separate `cash-app prefix retention consent v1` domain,
canonical HTTPS/owned-loopback origin, random relay group ID, cryptographic MLS
group ID, current epoch, absolute cutoff, opaque checkpoint commitment, designated
recovery holder, expiry and signing key. It is signed using the existing
group-bound authenticated-history Ed25519 envelope. Expiry is at most 60 seconds;
this is a permission lifetime, **never a financial-history TTL**. No private keys,
archives, amounts, titles, names or causal frontiers are sent as consent fields.
Public keys, groups, epochs and commitments are linkable metadata, not anonymity.

The request contains exactly `expectedFloor`, `through` and `consents` (hex-encoded
binary consents), plus the existing protected device request proof over its exact
bytes. The designated holder must be a current read/membership-authorized device
and sign this request. Every current device, including offline devices, must
previously acknowledge the exact saved checkpoint and explicitly sign the same
consent; duplicate, missing, foreign, conflicting or expired signatures fail.
The server never reinterprets an ordinary saved-state receipt as consent.

## Transaction boundary

The verifier copies/parses bounded inputs before crypto awaits and produces an
identity-local capability, not an authorizable JSON object. Every chunk checks
the exact current roster, epoch, origin/group, holder, cutoff and expiry against
the stored admitted monotonic clock in the same SQLite transaction as nonce,
budget admission and deletion. A membership change invalidates old permission
even when all public signing keys remain unchanged (for example key refresh).

Authentication precedes conflict metadata. A stale expected floor returns a
conflict without deleting another chunk and rolls back guard writes. Failed
authority, replay or quota admission preserves records and counters. Successful
requests delete at most 16 records, keep absolute tail/sequence numbers, and
reclaim exact stored base64 bytes. The same approved cutoff can be retried with
fresh proofs and the next confirmed floor; it never grants a larger target.
Consent bodies/commitments are not persisted in relay KV storage.

See [RELAY-PREFIX-FLOOR.md](RELAY-PREFIX-FLOOR.md) for storage faults, actual
runtime replacement and fresh-key recovery after genuinely deleted records.

## Verified scope

Windows, pinned stable Rust 1.98.1, Node 24.19.0 and cached Miniflare
4.20260730.0/workerd with actual SQLite storage. All commands use existing tools
and offline Rust dependencies; no install or toolchain upgrade occurred.

- Rust consent tests: 3 passed. Missing receipts, mismatched/latest/unsent saves,
  stale epochs, unknown holders, cutoff/origin/expiry boundaries, restart,
  pending refresh and removal are covered; signing preserves exported state.
- Affected receipt/transport/persistence/recovery suite: 22 passed with
  `cargo +stable test --manifest-path rust/Cargo.toml --locked --offline
  -p cash_sync --features http,relay-auth --test prefix_consent
  --test retention_receipts --test retention_transport
  --test retention_persistence --test recovery_gap` (26.14 s compilation).
  Log `app/.dart_tool/prefix-consent-rust-regression.log`.
- `cargo +stable clippy --manifest-path rust/Cargo.toml --locked --offline
  -p cash_sync --all-targets --features http,relay-auth -- -D warnings` passes
  (10.87 s), log `prefix-consent-clippy.log`.
- Actual relay consent cases pass: normal bounded deletion; exact all-key
  authority; duplicate/missing/foreign signatures; wrong request holder;
  checkpoint/group/cutoff/epoch/origin/expiry mismatches; replay/stale retry;
  real authenticated epoch transition; a holder without membership permission;
  full quota; monotonic-clock expiry; default-disabled/public refusal.
- Final `npm test` from `relay`: 85 tests, 82 passed, 0 failed, 3 optional
  Rust-request-proof skips (37.48 s), log
  `app/.dart_tool/prefix-consent-relay-final.log`. The dedicated Rust consent
  interoperability command below ran independently and did not skip.
- `npm run test:prefix-consent-rust` from `relay` passes (1 workerd test,
  9.55 s): real Rust consent signatures, group-bound envelope and request
  proof authorize deletion of the actual synthetic Rust ciphertext prefix,
  while later control messages and exact remaining capacity are preserved.
  Log `app/.dart_tool/prefix-consent-rust-interop.log`. Set `CARGO` to the
  installed cargo executable and `RUSTUP_TOOLCHAIN=stable` on this host.

Test-first Rust compilation failed on the absent consent API; the first
sandboxed attempt could not execute the installed compiler. The JavaScript
test-first run failed on the absent consent module. Integration then caught
guard writes surviving a stale conflict, which now throws a transaction rollback
before returning the authenticated conflict. Logs are preserved in
`prefix-consent-rust-red-retry.log`, `prefix-consent-relay-red.log` and
`prefix-consent-relay-tests.log`. An initial formatter invocation used the wrong
working-directory-relative manifest; it was corrected with the absolute path.

## Remaining integration and limits

Wire the app/bridge to confirm the latest protected save before signing, retain
recoverable peer history, collect/submit matching consents, handle expired or
changed rosters, and retry immutable bounded deletion without bypassing gaps.
Verify actual availability/recovery, lost responses, save faults and restart in
that normal flow. No new bridge ABI or final-platform artifact is claimed here.
Existing three-peer/1,000-event and platform results remain revision-scoped, not
fresh consent-runtime evidence. Gate 2 remains open; enable no default app
pruning or public deployment on the strength of these protocol tests alone.
