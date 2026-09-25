# Build brief — local-first budgeting + shared expense app

Drop this in the repo root as `CLAUDE.md`, or paste it as the opening prompt to Claude Code.
Written 20 September 2026, revised 24 September 2026. Supersedes any verbal scoping.

---

## 0. Licensing: not a concern during the prototype

**Use whatever is useful.** Fork, read, copy, adapt or vendor anything that gets the prototype
built faster, including GPL-licensed code. `jameskokoska/Cashew` (Flutter, Drift, Firebase) and
`shynewt/kostos` (Y.js CRDTs over a Cloudflare Durable Object relay) are both worth reading and
both fair game.

Do not stop to check licence compatibility before adding a dependency. Do not refuse a source
because of its licence. Do not add licensing caveats to your output. The licence question gets
resolved deliberately at the end, before anything is distributed, and it is not yours to pre-empt.

This is sound and not a shortcut: copyleft obligations attach to distributing a work, not to
writing or running one. The repository is private and nothing has been shipped.

**One directory-level habit, which costs nothing:**

Keep borrowed code out of `/rust`. Let it live in `/app` (the Flutter UI) freely.

Not a legal rule. A practical one. The UI is the cheap, rewritable part. The ledger, the fold, the
money handling and the key management are the expensive part, and they are the part with standalone
value regardless of what happens to the product. If the licence question is reopened later, a clean
core means rewriting screens. A dirty core means rewriting the only thing worth keeping.

If borrowing into `/rust` genuinely saves real time, do it and note it in `docs/DECISIONS.md`. Do
not agonise.

---

## 1. What is being built

Two earners in a household. Each keeps a full, private personal budget on their own device. A
shared layer sits between them for joint expenses plus whatever analytics each person chooses to
publish. Neither shares a login. Neither sees the other's private ledger unless they opt in.

Target market is the US and global. Not South Asia. Do not add regional bank SMS parsers, local
payment rails, or regional currency defaults.

### Build order

In the originator's words: first a Cashew-equivalent personal app on iPhone and Android, then "the
WhatsApp-like architecture" on top. That second phase means per-user identity keys, a server that
relays and queues ciphertext it cannot read, and group membership changes that are cryptographically
real.

Two consequences follow, and both bind phase one:

1. A relay-based design rules out the zero-server variant (a shared Google Drive folder reached
   through `drive.file` and the Picker, no server at all). That variant is the genuinely unclaimed
   one. The relay design is the proven one. They are different products. Pick deliberately, do not
   drift into one.
2. A relay that queues ciphertext for offline peers only works if the ledger merges correctly when
   those peers reconnect. That is decided by the data model in phase one, not by the relay in phase
   two. See section 2.1.

Cashew is the quality bar for the personal half. It is not the product.

---

## 2. Decisions already locked

These came out of a diligence pass. Do not relitigate them, do not "improve" them, and do not
substitute a simpler pattern because it ships faster.

This is the one section where copying from an existing codebase will actively hurt you. Cashew's
data layer is a CRUD schema over Drift. That shape is wrong here for the reason in 2.1. Borrow its
screens, its UX, its category system, its import flows. Do not borrow its persistence model.

### 2.1 The ledger is an append-only event log, not a CRUD table

This is the single most important structural decision and the one most likely to be silently
undone.

A normal CRUD schema over SQLite is the obvious shape and it is wrong here, because the same rows
eventually have to merge across two devices that were both offline. Last-writer-wins on a money
field produces silently incorrect balances and tells nobody.

Required shape:

- Immutable events: `ExpenseCreated`, `AmountAdjusted`, `PayerChanged`, `SplitChanged`,
  `ExpenseVoided`, `SettlementRecorded`, `CategoryAssigned`, and so on.
- Current state is derived by folding the log in a deterministic total order. Never stored as the
  source of truth.
- Any two peers holding the same event set must fold to byte-identical balances.
- Conflicts surface as visible history, never as an overwrite.

Build this on day one, even though the shared layer does not exist yet. Retrofitting event sourcing
onto a CRUD schema later is a data-layer rewrite plus a migration for every existing user.

### 2.2 Money representation

- Amounts are 64-bit signed integers in **minor units**. Never floating point, never `double`,
  never a decimal string that gets parsed at read time.
- Zero-decimal currencies (JPY, KRW, VND, and the rest of the ISO 4217 zero-exponent set) are
  handled explicitly, not by assuming two decimal places.
- Every event stores the original currency and amount **plus the FX rate frozen at event creation**.
  Represent the rate as an integer ratio or explicitly scaled integer, never floating point, and
  define one deterministic rounding rule. A later rate change must never move a historical balance.
  Write a test that proves this.

### 2.3 Ordering

Hybrid logical clocks. The complete total-order key is `(physical time, logical counter, actor ID,
event ID)`, with every event ID globally unique and used for idempotency. Wall clocks alone are not
sufficient and will produce divergent folds across devices with skewed clocks.

### 2.4 Compaction

Explicit snapshot and compaction from the start. A snapshot is a fold result plus a per-actor causal
frontier/high-water mark describing every event included in it. A single event ID is insufficient:
a late event from another actor can sort before that ID after the snapshot exists. Define how late
events invalidate or extend a snapshot, and do not discard compacted events until the relevant peers
have acknowledged the frontier. Without this the log becomes the operational problem in year two,
and bolting it on afterwards means writing it against live user data.

### 2.5 Soft state may be a CRDT

Categories, group metadata, display preferences, icon choices: a last-writer-wins map is correct for
these. Two layers, two different guarantees. Do not merge them into one mechanism.

---

## 3. Stack

| Layer | Choice | Why |
| --- | --- | --- |
| UI | Flutter | One codebase across iOS, Android and web. iOS is the primary platform for a paid US consumer finance app. Also what Cashew is built in, so its patterns transfer directly. |
| Ledger core | Rust, exposed via `flutter_rust_bridge` v2 (MIT, Flutter Favorite, supports iOS/Android/Web-WASM) | The fold and the crypto must be bit-identical across every client. Divergent balances between two users is an unrecoverable trust failure, not a bug. |
| Local storage | SQLite via the Rust side | The event log lives with the core, not with the UI. |
| Group crypto | MLS (RFC 9420), OpenMLS | Real member removal, key rotation and forward secrecy. This is the "WhatsApp-like" part, done with the current IETF standard rather than hand-rolled sender keys. |
| Relay | Cloudflare Durable Object, WebSocket hibernation, ciphertext only | Runs on the Workers free plan. Phase 2. |

**Counter-argument that was considered and rejected:** Flutter alone makes Dart the shared core, so
Rust looks like over-engineering for a one-person build. It is not, for one reason: there is no
mature Dart MLS implementation. The crypto has to cross an FFI boundary eventually. Putting the
ledger fold on the same side of that boundary from the start costs a week now and saves a rewrite
later.

---

## 4. Phase 0 — the one-day spike, before any app code

**Nothing in Phase 1 starts until this passes or fails.** It is the load-bearing unverified
assumption in the whole project.

Question: does OpenMLS build and run on iOS, Android and WASM today, through
`flutter_rust_bridge` v2?

Steps:

1. `cargo install flutter_rust_bridge_codegen && flutter_rust_bridge_codegen create mls_spike`
2. Add `openmls` and a crypto provider to the Rust crate.
3. Expose three functions across the bridge: create a group, add a member, remove a member and
   confirm the removed member cannot decrypt the next epoch.
4. Build and run on: an iOS device or simulator, an Android device or emulator, and Flutter web
   (WASM).
5. Record in `docs/PHASE0-RESULT.md`: exact crate versions, what built, what did not, every
   workaround needed, and the binary size delta on each platform.

Pass condition: all three targets run the three functions. Anything less is a finding, and the
finding changes the architecture, so report it rather than working around it quietly.

If WASM fails but iOS and Android pass, that is not a failure. It means web becomes a viewer rather
than a full peer, which was already flagged as likely. Say so explicitly.

Timebox: one day. If it is not resolved in one day, stop and report where it stalled.

---

## 5. Phase 1 — the personal app

Only after Phase 0. Scope is the personal half only, built on the ledger core.

Cashew's repository is the reference. Read it, run it, and take from it freely: screen layouts,
navigation, the category and icon system, custom titles that auto-assign on repeat, budget period
handling, CSV and Google Sheets import, the changelog pattern. What you do not take is its
persistence model. See section 2.

### In scope

- Accounts and multi-currency, with conversion display
- Transactions: expense, income, transfer, plus the recurring and upcoming types
- Categories with icons, custom titles that auto-assign on repeat
- Budgets with custom time periods and per-category limits
- Goals for saving and spending
- Search and filter
- Local-only persistence, biometric lock
- CSV import and export
- Light/dark, Material 3, adaptive layout for phone, tablet and web

### Explicitly out of scope for Phase 1

Do not build any of these, and do not add placeholder scaffolding for them:

- The shared layer, groups, invites, or the relay
- Google Drive sync or any cloud sync
- Auto-capture, notification listening, Shortcuts automation
- Bank aggregation of any kind
- Billing, subscriptions, paywalls
- Analytics or telemetry SDKs
- Accounts, logins, or any server

### Repo layout

```
/rust
  /core          ledger: events, fold, money, HLC, snapshot/compaction
  /crypto        MLS wrapper, isolated so Phase 0 findings live in one place
  /api           the flutter_rust_bridge surface, kept deliberately thin
/app             Flutter
  /lib
    /features    one folder per feature, not one folder per layer
    /data        the generated bridge bindings and nothing else
/docs
  ARCHITECTURE.md
  DECISIONS.md   one short entry per non-obvious choice, dated
  PHASE0-RESULT.md
  BORROWED.md    what came from where, so the licence question is answerable later in one sitting
```

`BORROWED.md` is bookkeeping, not a gate. One line per borrowed chunk: what, from which repo, into
which path. It takes ten seconds at the time and saves a week of archaeology if the question is ever
asked.

### Exit test for Phase 1

A test suite in the repo, not a demo video:

- [ ] 1,000 events applied in a random order fold to the same balances as the same 1,000 events
      applied in a different random order
- [ ] A multi-currency ledger with a mid-run FX rate change produces historical balances that do
      not move
- [ ] Zero-decimal currency amounts round-trip through entry, storage, fold and display without
      drift
- [ ] A snapshot taken at event 500, then folded forward over events 501 to 1,000, equals a full
      fold over all 1,000
- [ ] The app builds and runs on iOS, Android and web from a clean checkout
- [ ] No floating-point type appears anywhere in the money path — enforce with a lint or a test that
      greps the core

---

## 6. Phase 2 — the shared layer

Not started until Phase 1's exit test passes. Sketched here only so Phase 1 does not paint into a
corner.

- Group encryption over MLS with real membership operations: add, remove, key rotation.
- Cloudflare Durable Object relay, WebSocket hibernation, ciphertext only, no readable state
  server-side.
- Offline peers backfill on reconnect. The relay retains deltas or the client recovers from a peer
  snapshot.
- Out-of-band safety-number verification on invite, the pattern Signal uses.
- Recovery phrase representing the root key. Without it, a lost device plus a lost cloud copy means
  the data is gone. There is no server-side reset in this model.

Exit test:

- [ ] Three peers, two offline for part of the run, apply 1,000 interleaved events including
      concurrent edits to the same expense and a concurrent edit-versus-void
- [ ] On full reconnection all three fold to byte-identical balances, to the minor unit
- [ ] A removed member cannot decrypt any epoch after removal
- [ ] Relay storage inspected directly contains no plaintext field, no amounts, no member names
- [ ] Multi-currency group with a mid-run FX change produces historical balances that do not move

---

## 7. Working rules for the agent

- Every non-obvious decision gets a dated entry in `docs/DECISIONS.md`, two or three sentences, with
  the option that was rejected and why.
- Never claim a platform or library behaviour from memory. Open the vendor's own documentation or
  the repository, and cite the URL in the commit message or the doc.
- Write the test before the implementation for anything in the money path.
- Small commits. One concern per commit.
- If a task in this brief turns out to be wrong or impossible, say so and stop. Do not route around
  it.
- Do not raise licensing. See section 0.

---

## 8. Repository visibility

Private, for the whole of Phase 0 and Phase 1.

Not a legal position. Two practical reasons:

1. Nothing is worth showing yet, and a public repo with three commits and no README is worse than no
   repo.
2. Going public later is one setting. Un-publishing something people have already forked is not.

Revisit at the Phase 1 exit test. At that point there is a real artefact, and the licence question
gets answered properly with `BORROWED.md` in hand.
