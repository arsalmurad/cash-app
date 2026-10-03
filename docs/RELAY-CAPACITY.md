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

## Still open

There is no account-wide group/mailbox creation quota, authenticated roster,
per-device request authorization, safe pruning authority, peer-snapshot
replacement protocol or verified free-plan deployment. Random group IDs and
per-group ceilings cannot prevent an attacker from creating many groups.
The worker's default public 503 gate remains in place; only explicit loopback
development is enabled. Receipt cutoffs remain local plans, not deletion rights.
