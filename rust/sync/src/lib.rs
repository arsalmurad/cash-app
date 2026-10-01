//! Household sync: MLS-encrypted shared events over a dumb, ordered relay.
//!
//! The relay (see [`relay`]) is a per-group append-only log with
//! compare-and-swap on the tail: it stores opaque bytes and assigns them a
//! total order, and learns nothing else. [`Peer`] ties the pieces together:
//! it encrypts each shared event with MLS ([`cash_crypto`]), appends it to
//! the relay, pulls everyone else's entries in order, and folds the decrypted
//! events with [`cash_core::fold_shared`].
//!
//! Because every entry, commits included, goes through one totally ordered
//! log, every member processes the same MLS messages in the same order, and
//! a writer whose view is stale simply loses the compare-and-swap, catches
//! up, and retries. No peer needs to see another directly.

mod authenticated_history;
#[cfg(feature = "http")]
mod http;
mod ids;
mod peer;
mod relay;

#[cfg(feature = "http")]
pub use http::HttpRelay;
pub use peer::{Outgoing, Peer, StagedInvite, SyncError};
pub use relay::{MailboxItem, MemoryRelay, Relay, RelayError};
