# Private Ledger app

Flutter client for the local-first personal budgeting app. Financial amounts
cross a thin `flutter_rust_bridge` boundary and are parsed and folded by the
deterministic Rust ledger in `../rust`.

Personal event logs and encrypted household journals persist through the
Rust SQLite adapter. Personal SQLite is not encrypted by the app; household
private-key journals are. The project is an unfinished private prototype.

See [the repository guide](../README.md) for setup and security limits,
[the completion tracker](../docs/COMPLETION.md) for remaining work, and
[platform evidence](../docs/PHASE2-PROGRESS.md) for precise tested revisions.
