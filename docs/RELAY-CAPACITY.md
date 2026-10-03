# Relay capacity guard

Implemented and independently checked locally on 2026-10-03. This is a
non-destructive guard, not authenticated pruning or public-deployment approval.

Each group log accepts at most 10,000 records and 64 MiB of stored ASCII base64
ciphertext. The latter counts encoded bytes, not decoded message sizes; record
keys, database overhead and account-wide usage are additional. These are
conservative prototype ceilings, not a claim that a hosted account stays free.
Mailbox items retain their existing size and seven-day expiry limits.

The append transaction updates the versioned capacity counter, ciphertext and
tail together. A stale expected tail still returns 409 before checking capacity.
A matching-tail write exceeding either ceiling returns 507 without writing,
notifying listeners, expiring history or advancing the tail. Existing readers
can still backfill every retained record. Clients retain unsent work under the
existing failed-append/restart rules; capacity refusal does not authorize
discarding it or creating a replacement household silently.

Nonempty legacy logs without counters and malformed/inconsistent counters return
503 on matching-tail append. Their history remains readable. No automatic full
scan, guessed accounting, reset or destructive migration is provided. Operators
must arrange a separately verified bounded accounting migration before those
logs can accept writes. New empty logs initialize accounting in their first
successful append. There is no deployed production log migration claimed here.

## Independent checks

Pinned existing Node 24.19 / Miniflare 4.20260730.0 / workerd on Windows:

- `cd relay; npm test`: all 27 tests passed, including the full-volume case
  (25.75 seconds in this combined run; complete suite 27.93 seconds).
- `cd relay; node --test test/capacity.test.js`: all five tests passed, including
  an actual 64 MiB encoded-ciphertext fill (192 records), refused next append,
  and byte-exact paged backfill. Full-volume case took 21.33 seconds. Seeded
  boundary tests separately exercise racing final-capacity appends, the 10,000
  record ceiling, unaccounted legacy logs and malformed counters. Their seeding
  route exists only inside an in-memory test module, never production code.
- `CARGO_NET_OFFLINE=true CARGO=C:/Users/ME/.cargo/bin/cargo.exe npm run
  test:storage`: real encrypted Rust peers passed the 31-record workerd storage
  audit, including exact counter-versus-record accounting and a plaintext
  injection negative control. workerd emitted WSASend #10054; assertions and
  exit status passed, without diagnosing that network/cleanup diagnostic.

Only relay code/tests and documentation changed. The previously verified app,
native bridge and production WASM source did not change, so no platform rebuild
was performed for this guard.

The following narrow client change maps append HTTP 507 to trusted local copy:
“Household relay storage is full. Keep this household on your device and contact
the relay operator before trying Sync again.” It does not display remote error
instructions or suggest resetting the household. The UX-copy guidance informed
the explanation and next step, without promising a durability guarantee.
All 23 focused HTTP/native-bridge receipt-coordinator tests pass, including
capacity refusal before the financial frame and after it (while the receipt is
pending). Both restart with the expense retained, refuse further append while
full, then retry without duplicate financial events or an ACK loop when the
test relay accepts writes again. Capacity restoration is a test-double switch,
not evidence of a pruning endpoint or actual-worker-to-app capacity recovery.
The cached full native-enabled Flutter suite subsequently passes all 319 tests
in 2 minutes 20 seconds; static analysis reports no issues. This client copy
change has host HTTP/native-bridge evidence, not a newly rebuilt mobile or
production browser runtime. Previous platform evidence remains revision-scoped.

## Checked relay pages

A subsequent transport change checks every page's tail, continuation flag,
contiguous sequences and nonempty bounded decoded entries in both Dart and the
Rust HTTP client. Backwards tails, missing/mistyped metadata, gaps, duplicates,
stalled continuation and false completion fail without returning partial history.
Concurrent tail growth and ordinary empty completion remain valid. A server
claiming an empty log behind a saved cursor now fails instead of pretending sync
succeeded; this is not a peer-snapshot recovery implementation.

The test-first Dart regressions initially reproduced an extra request after an
empty continuation and acceptance of tail rollback. The Rust decoder tests
initially failed to compile at the absent checked decoder. Subsequently all 41
focused HTTP/native-bridge household persistence tests, two Rust decoder tests,
strict HTTP-enabled all-target Clippy and app static analysis pass. The current
Rust HTTP client again passes the real-workerd 31-record encrypted-peer audit
and negative control; WSASend #10053 appeared despite passing assertions/exit 0.
The earlier full 319 app-test run precedes this page-validation change; no new
production browser/mobile run or physical-network guarantee is inferred.

At that revision the check did not authenticate the relay, cap buffered HTTP
response bytes or stop chasing continually advancing tails. The following
separate change addresses the read-resource boundary, not authentication.

## Finite bounded backfill

Both clients now complete only the prefix ending at the first observed tail.
Every returned entry through that boundary is contiguous and validated; entries
appended concurrently above it are fetched on the next read, not skipped or
reported as part of the original prefix. A read refuses an initial gap exceeding
10,000 entries or an aggregate decoded payload exceeding 64 MiB. No partial
history is returned on a failed limit/timeout check.

Rust JSON replies and streamed Dart log pages are capped at 6 MiB before JSON
parsing. Dart cancels/aborts oversized requests using the existing pinned
HTTP 1.6.0 API, counts actual bytes even when Content-Length lies, and refuses
oversized declarations before consuming the body. Reads share a 20-second
network deadline across pages; Rust requests use the remaining deadline rather
than resetting it per page. These are buffer/network-work limits, not a measured
peak-memory or exact wall-clock/CPU-parsing guarantee. Dart append/mailbox
responses still use the existing buffered adapter and remain separate work.

Test-first Dart checks caught pre-fix buffering until its 20-second timeout and
reading past the original tail. A declared-oversize test initially expected a
body-stream cancellation callback, but the iterator had never subscribed:
the corrected assertion checks request abort and no body subscription instead.
Actual overflow after streaming starts separately checks cancellation. Current
44 focused HTTP/native-bridge persistence/retry tests and five Rust response/
page/window tests pass, including exact limits, aggregate overflow and fetching
concurrent entries on the next read. Strict Rust HTTP all-target checks and
app analysis pass. The actual-workerd 31-record encrypted-peer audit and its
plaintext negative control pass again; WSASend #10054 remains undiagnosed.

The limits match the new relay's ceilings, but legacy logs may exceed a single
client backfill budget; they are not silently truncated. Server-side paged
reads remain available. Safe bounded migration or peer recovery for a larger
legacy backfill remains open, as does final production-browser/mobile runtime
acceptance of this client change. No history deletion or public access is enabled.

## Still open

There is no account-wide group/mailbox creation quota, authenticated roster,
per-device request authorization, safe pruning authority, peer-snapshot
replacement protocol or verified free-plan deployment. Random group IDs and
per-group ceilings cannot prevent an attacker from creating many groups.
The worker's default public 503 gate remains in place; only explicit loopback
development is enabled. Receipt cutoffs remain local plans, not deletion rights.
