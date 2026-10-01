# Rust-owned local SQLite storage

Implemented 2026-10-02. Mobile runtime acceptance for this change is pending;
earlier mobile results do not verify this storage implementation.

The default event, document and actor-identity stores now call `cash_storage`
through synchronous Rust bridge operations. Dart transports a path or bytes;
SQL, transactions and checked revisions live in Rust. Existing event codecs,
immutable event IDs, deterministic fold and money representation are unchanged.
There is no SQL or readable financial data on the relay.

## Native

One `cash-app.v1.sqlite` database lives in the application-support directory.
Bundled SQLite uses rollback-journal transactions with `synchronous=EXTRA` and
a five-second busy timeout. Opening/initializing and writes take SQLite writer
locks. A connection exists only for one bridge call. Document/log revisions
are compared and advanced in the same transaction; stale writers fail rather
than replacing newer MLS ratchets or events. Deletions retain revision tombstones.

## Browser

SQLite runs synchronously on the caller's main WASM thread, never in the Rust
bridge worker pool: the pinned `sqlite-wasm-rs` binding is not thread-safe.
Each operation acquires the origin Web Lock `cash-app.sqlite.v1`, reads a
serialized SQLite image, runs Rust SQLite, and saves the complete image as
base64 under `private_ledger.sqlite.v1` before releasing the lock. No independent
tab can overwrite a newer image through these adapters.

This is **not OPFS**. Reading, checking, serializing and saving cost O(database
size), may block the page briefly, and remain subject to browser localStorage
quota, storage eviction and private-browsing limitations. A rejected save leaves
the previous image intact and propagates failure to the existing fail-closed
controllers; clearing site data loses local state. HTTPS/localhost and Web Locks
are required. Large-history performance and other-browser runtime coverage
remain separate acceptance work.

## Migration and protection boundaries

Legacy event logs are imported once, transactionally. The original files/keys
remain untouched as recovery evidence; later edits to them cannot replace a
migrated stream. A validated torn prefix can be repaired only at its observed
revision/length, preserving the full original bytes in `recoveries`. Actor IDs
are retained. Legacy household documents are validated and sealed by the
existing secret-store layer before writing; plaintext is not copied into a
SQLite household document by migration. A tombstone cannot revive legacy state.

Do not run an older app against retained legacy journals to resume a household:
older MLS state is not a safe rollback target. Use the documented fresh-key
recovery/re-invitation flow. Retained files and database pages are not securely
erased and can contain previous values.

Working household journals remain AEAD-encrypted, with OS-held wrapping keys on
native devices and the RAM-only unlock phrase on web. The private personal
ledger is **not encrypted by SQLite**. This does not protect an unlocked page
from same-origin malicious code, a compromised OS, cloned databases, or a user
who edits storage outside the app. Unsupported/foreign/damaged databases fail
without being reset.

## Verification

`cargo test --locked -p cash_storage` exercises serialization/restart, stale
writers, tombstones, torn-prefix archives, failed transaction rollback,
concurrent first-open, two file connections and process exit before/after commit.
Process exit is not a physical power-loss test.

With `RUST_LIB_PATH` pointing to the rebuilt host library, app tests exercise
default native adapters, five real codec-log migrations/repair and restart,
immutable identity, legacy retention and damaged-file rejection. The production
Chrome journey also passed personal persistence, encrypted household restart,
offline conflict, stale-backup fresh-key recovery and old-member exclusion with
SQLite storage. The final revised source is being rechecked before mobile CI.
