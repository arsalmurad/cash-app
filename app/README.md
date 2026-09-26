# Private Ledger app

Flutter client for the local-first personal budgeting app. Financial amounts
cross a thin `flutter_rust_bridge` boundary and are parsed and folded by the
deterministic Rust ledger in `../rust`.

The current Phase 1 vertical slice supports personal accounts plus income and
expense entry. Its ledger is intentionally in memory until the next slice adds
local SQLite event persistence.
