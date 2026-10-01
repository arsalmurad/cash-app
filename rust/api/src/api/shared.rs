use std::sync::{Mutex, MutexGuard};

use cash_core::{
    AccountId, Currency, EventKind, FxRate, Money, SharedState, TransactionId, TransactionKind,
};
use cash_crypto::{RecoveryKey, safety_number};
use cash_sync::{Outgoing, Peer};
use flutter_rust_bridge::frb;

use super::ledger::{AccountView, EntryKind, reporting_balances};

/// This device's membership in one household: the MLS identity, the shared
/// events it has seen, and what it still has to send. The network lives in
/// Dart: it fetches relay entries into [`household_ingest`], asks
/// [`household_next_outgoing`] what to append, and reports the verdict, so
/// this type never does I/O. See `cash_sync::Peer` for the state machine.
#[frb(opaque)]
pub struct Household {
    peer: Mutex<Peer>,
    reporting_currency: Currency,
}

/// One entry of the relay's log, as fetched by Dart.
pub struct RelayEntry {
    pub sequence: i64,
    pub blob: Vec<u8>,
}

/// Something for Dart to append to the relay log, only if the log's tail is
/// still `expected_tail`.
pub struct OutgoingEntry {
    pub expected_tail: i64,
    pub blob: Vec<u8>,
}

/// A staged commit that adds a member. `welcome` is for the new member and
/// must only be delivered (left in a mailbox) once the relay has accepted
/// `commit`.
pub struct StagedInvite {
    pub commit: OutgoingEntry,
    pub welcome: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub struct HouseholdOverview {
    pub member_id: String,
    pub group_id: Option<String>,
    pub is_member: bool,
    /// Sequence number of the last relay entry processed.
    pub cursor: i64,
    /// Locally written events not yet sent to the relay.
    pub pending_count: i64,
    pub member_ids: Vec<String>,
    pub balance_label: String,
    pub accounts: Vec<AccountView>,
    pub transactions: Vec<SharedTransactionView>,
    pub conflicts: Vec<ConflictView>,
    pub rejected: Vec<RejectedView>,
}

#[derive(Debug, PartialEq)]
pub struct SharedTransactionView {
    pub id: String,
    pub account_id: String,
    pub title: String,
    pub amount_label: String,
    pub is_expense: bool,
    pub voided: bool,
    pub category_id: Option<String>,
    /// Two people edited this expense without seeing each other's edit.
    pub conflicted: bool,
}

/// Two concurrent edits of one expense: both stay visible.
#[derive(Debug, PartialEq)]
pub struct ConflictView {
    pub transaction_id: String,
    pub overwritten_event_id: String,
    pub winning_event_id: String,
}

/// An event that could not apply (for example an edit of a voided expense).
#[derive(Debug, PartialEq)]
pub struct RejectedView {
    pub event_id: String,
    pub reason: String,
}

fn lock(household: &Household) -> Result<MutexGuard<'_, Peer>, String> {
    household
        .peer
        .lock()
        .map_err(|_| "household state is unavailable after an earlier failure".to_owned())
}

fn outgoing(entry: Outgoing) -> OutgoingEntry {
    OutgoingEntry {
        expected_tail: i64::try_from(entry.expected_tail).unwrap_or(i64::MAX),
        blob: entry.blob,
    }
}

fn unsigned(value: i64, what: &str) -> Result<u64, String> {
    u64::try_from(value).map_err(|_| format!("{what} cannot be negative"))
}

/// Creates this device's identity with no group yet. `member_id` is the
/// identity every member of the group will see: use an opaque value, not a
/// name.
pub fn household_new(
    member_id: String,
    reporting_currency_code: String,
) -> Result<Household, String> {
    let reporting_currency =
        Currency::from_code(&reporting_currency_code).map_err(|error| error.to_string())?;
    let peer = Peer::new(&member_id, reporting_currency.clone()).map_err(|e| e.to_string())?;
    Ok(Household {
        peer: Mutex::new(peer),
        reporting_currency,
    })
}

/// Restores a household from [`household_export`]'s bytes.
pub fn household_restore(saved: Vec<u8>) -> Result<Household, String> {
    let peer = Peer::import(&saved).map_err(|error| error.to_string())?;
    let reporting_currency = peer.reporting_currency().clone();
    Ok(Household {
        peer: Mutex::new(peer),
        reporting_currency,
    })
}

/// Import signed history from a backup after a replacement identity has joined
/// the original household. Old sender keys and delivery intent are not reused.
/// Returns false without importing while the old signing key is still a member.
pub fn household_merge_recovery_history(
    household: &Household,
    saved: Vec<u8>,
) -> Result<bool, String> {
    lock(household)?
        .merge_recovery_history(&saved)
        .map_err(|error| error.to_string())
}

/// Everything needed to resume after a restart, including private keys:
/// store it like a password. Includes an exact pending-commit journal.
pub fn household_export(household: &Household) -> Result<Vec<u8>, String> {
    lock(household)?.export().map_err(|error| error.to_string())
}

/// A fresh single-use key package for someone to invite this device with.
/// Hand it to them out of band (never through the relay).
pub fn household_key_package(household: &Household) -> Result<Vec<u8>, String> {
    lock(household)?
        .key_package()
        .map_err(|error| error.to_string())
}

/// Starts a new household with this device as its only member; returns the
/// group's random ID.
pub fn household_found(household: &Household) -> Result<String, String> {
    lock(household)?
        .found_group()
        .map_err(|error| error.to_string())
}

pub fn household_join(
    household: &Household,
    group_id: String,
    welcome: Vec<u8>,
    joined_after: i64,
) -> Result<(), String> {
    let joined_after = unsigned(joined_after, "joined_after")?;
    lock(household)?
        .join(&group_id, &welcome, joined_after)
        .map_err(|error| error.to_string())
}

pub fn household_begin_invite(
    household: &Household,
    key_package: Vec<u8>,
) -> Result<StagedInvite, String> {
    let staged = lock(household)?
        .begin_invite(&key_package)
        .map_err(|error| error.to_string())?;
    Ok(StagedInvite {
        commit: outgoing(staged.commit),
        welcome: staged.welcome,
    })
}

pub fn household_begin_removal(
    household: &Household,
    member_id: String,
) -> Result<OutgoingEntry, String> {
    lock(household)?
        .begin_removal(&member_id)
        .map(outgoing)
        .map_err(|error| error.to_string())
}

pub fn household_commit_accepted(household: &Household, sequence: i64) -> Result<(), String> {
    let sequence = unsigned(sequence, "sequence")?;
    lock(household)?
        .commit_accepted(sequence)
        .map_err(|error| error.to_string())
}

pub fn household_commit_rejected(household: &Household) -> Result<(), String> {
    lock(household)?
        .commit_rejected()
        .map_err(|error| error.to_string())
}

/// Processes relay entries in order (replays are skipped; a gap is an error).
pub fn household_ingest(household: &Household, entries: Vec<RelayEntry>) -> Result<(), String> {
    let entries = entries
        .into_iter()
        .map(|entry| Ok((unsigned(entry.sequence, "sequence")?, entry.blob)))
        .collect::<Result<Vec<_>, String>>()?;
    lock(household)?
        .ingest(&entries)
        .map_err(|error| error.to_string())
}

/// The next queued event, encrypted, for Dart to append; `None` when the
/// outbox is empty. Returns the same event again until it is accepted.
pub fn household_next_outgoing(household: &Household) -> Result<Option<OutgoingEntry>, String> {
    Ok(lock(household)?
        .next_outgoing()
        .map_err(|error| error.to_string())?
        .map(outgoing))
}

pub fn household_outgoing_accepted(household: &Household, sequence: i64) -> Result<(), String> {
    let sequence = unsigned(sequence, "sequence")?;
    lock(household)?
        .outgoing_accepted(sequence)
        .map_err(|error| error.to_string())
}

pub fn household_open_account(
    household: &Household,
    account_id: String,
    name: String,
    currency_code: String,
    wall_clock_millis: i64,
) -> Result<(), String> {
    let currency = Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    lock(household)?
        .write(
            wall_clock_millis,
            EventKind::AccountOpened {
                account_id: AccountId::new(account_id),
                name,
                currency,
            },
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// Records a shared expense or income. Like the personal ledger, the rate
/// freezes on the entry (`fx_numerator` / `fx_denominator`: reporting minor
/// units per source minor unit).
#[allow(clippy::too_many_arguments)]
pub fn household_record_transaction(
    household: &Household,
    transaction_id: String,
    account_id: String,
    kind: EntryKind,
    amount: String,
    currency_code: String,
    fx_numerator: i64,
    fx_denominator: i64,
    title: String,
    category_id: Option<String>,
    wall_clock_millis: i64,
) -> Result<(), String> {
    let currency = Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    let minor_units = currency
        .parse_major_units(&amount)
        .map_err(|error| error.to_string())?;
    if minor_units <= 0 {
        return Err("transaction amount must be greater than zero".to_owned());
    }
    let household_currency = household.reporting_currency.clone();
    let rate = FxRate::new(fx_numerator, fx_denominator, household_currency)
        .map_err(|error| error.to_string())?;
    lock(household)?
        .write(
            wall_clock_millis,
            EventKind::TransactionRecorded {
                transaction_id: TransactionId::new(transaction_id),
                account_id: AccountId::new(account_id),
                kind: TransactionKind::from(kind),
                original: Money::new(minor_units, currency),
                reporting_fx: rate,
                title,
                category_id,
                recurring_id: None,
            },
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// Changes an expense's amount. Two people doing this at once is a visible
/// conflict, not a silent overwrite.
#[allow(clippy::too_many_arguments)]
pub fn household_adjust_amount(
    household: &Household,
    transaction_id: String,
    amount: String,
    currency_code: String,
    fx_numerator: i64,
    fx_denominator: i64,
    wall_clock_millis: i64,
) -> Result<(), String> {
    let currency = Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    let minor_units = currency
        .parse_major_units(&amount)
        .map_err(|error| error.to_string())?;
    if minor_units <= 0 {
        return Err("transaction amount must be greater than zero".to_owned());
    }
    let rate = FxRate::new(
        fx_numerator,
        fx_denominator,
        household.reporting_currency.clone(),
    )
    .map_err(|error| error.to_string())?;
    lock(household)?
        .write(
            wall_clock_millis,
            EventKind::AmountAdjusted {
                transaction_id: TransactionId::new(transaction_id),
                original: Money::new(minor_units, currency),
                reporting_fx: rate,
            },
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub fn household_void_transaction(
    household: &Household,
    transaction_id: String,
    wall_clock_millis: i64,
) -> Result<(), String> {
    lock(household)?
        .write(
            wall_clock_millis,
            EventKind::TransactionVoided {
                transaction_id: TransactionId::new(transaction_id),
            },
        )
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub fn household_overview(household: &Household) -> Result<HouseholdOverview, String> {
    let peer = lock(household)?;
    let state = peer.state();
    let member_ids = peer
        .member_keys()
        .map(|keys| keys.into_iter().map(|(name, _)| name).collect())
        .unwrap_or_default();
    let mut overview = overview_from_state(
        &state,
        peer.member_id().to_owned(),
        peer.group_id().map(str::to_owned),
        peer.is_member(),
        peer.cursor(),
        peer.pending_count(),
        member_ids,
    );
    if peer.legacy_unverified() {
        overview.rejected.push(RejectedView {
            event_id: "legacy-unverified-history".to_owned(),
            reason: "Unsigned legacy household history: view/export only. Keep an archive and create a new household before sharing further.".to_owned(),
        });
    }
    Ok(overview)
}

/// The safety number shared between this device and `member_id`: read it
/// aloud or compare it on screen; if it differs on the two devices, someone
/// substituted a key.
pub fn household_safety_number(household: &Household, member_id: String) -> Result<String, String> {
    let peer = lock(household)?;
    let keys = peer.member_keys().map_err(|error| error.to_string())?;
    let (_, theirs) = keys
        .into_iter()
        .find(|(name, _)| *name == member_id)
        .ok_or_else(|| format!("{member_id} is not a member of this household"))?;
    Ok(safety_number(&peer.public_key(), &theirs))
}

/// A new recovery phrase: 24 words to write down. Nothing is stored.
pub fn recovery_generate_phrase() -> String {
    RecoveryKey::generate().phrase()
}

/// Checks that typed words are a valid phrase (right words, right order).
pub fn recovery_validate_phrase(phrase: String) -> Result<(), String> {
    RecoveryKey::from_phrase(&phrase)
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// Encrypts a device backup (for example [`household_export`]'s bytes) under
/// the phrase, for storage anywhere.
pub fn recovery_seal(phrase: String, plaintext: Vec<u8>) -> Result<Vec<u8>, String> {
    RecoveryKey::from_phrase(&phrase)
        .and_then(|key| key.seal(&plaintext))
        .map_err(|error| error.to_string())
}

pub fn recovery_open(phrase: String, sealed: Vec<u8>) -> Result<Vec<u8>, String> {
    RecoveryKey::from_phrase(&phrase)
        .and_then(|key| key.open(&sealed))
        .map_err(|error| error.to_string())
}

fn overview_from_state(
    state: &SharedState,
    member_id: String,
    group_id: Option<String>,
    is_member: bool,
    cursor: u64,
    pending: usize,
    member_ids: Vec<String>,
) -> HouseholdOverview {
    let ledger = &state.ledger;
    let reporting = reporting_balances(ledger);
    let accounts = ledger
        .accounts
        .iter()
        .map(|(id, account)| AccountView {
            id: id.as_str().to_owned(),
            name: account.name.clone(),
            currency_code: account.currency.code().to_owned(),
            balance_label: account
                .currency
                .format_minor_units(account.native_balance_minor),
            reporting_balance_label: if account.currency == ledger.reporting_currency {
                None
            } else {
                reporting
                    .get(id)
                    .copied()
                    .flatten()
                    .map(|minor| ledger.reporting_currency.format_minor_units(minor))
            },
        })
        .collect();
    let conflicted: std::collections::BTreeSet<_> = state
        .conflicts
        .iter()
        .map(|conflict| conflict.transaction_id.clone())
        .collect();
    let transactions = ledger
        .transactions
        .iter()
        .rev()
        .map(|(id, transaction)| SharedTransactionView {
            id: id.as_str().to_owned(),
            account_id: transaction.account_id.as_str().to_owned(),
            title: transaction.title.clone(),
            amount_label: transaction
                .original
                .currency
                .format_minor_units(transaction.original.minor_units),
            is_expense: transaction.kind == TransactionKind::Expense,
            voided: transaction.voided,
            category_id: transaction.category_id.clone(),
            conflicted: conflicted.contains(id),
        })
        .collect();
    HouseholdOverview {
        member_id,
        group_id,
        is_member,
        cursor: i64::try_from(cursor).unwrap_or(i64::MAX),
        pending_count: i64::try_from(pending).unwrap_or(i64::MAX),
        member_ids,
        balance_label: ledger
            .reporting_currency
            .format_minor_units(ledger.reporting_balance_minor),
        accounts,
        transactions,
        conflicts: state
            .conflicts
            .iter()
            .map(|conflict| ConflictView {
                transaction_id: conflict.transaction_id.as_str().to_owned(),
                overwritten_event_id: conflict.overwritten.as_str().to_owned(),
                winning_event_id: conflict.winner.as_str().to_owned(),
            })
            .collect(),
        rejected: state
            .rejected
            .iter()
            .map(|rejected| RejectedView {
                event_id: rejected.event_id.as_str().to_owned(),
                reason: format!("{:?}", rejected.reason),
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Dart's half of the protocol, in miniature: an ordered log with
    /// compare-and-swap.
    #[derive(Default)]
    struct Log(Vec<Vec<u8>>);

    impl Log {
        fn append(&mut self, entry: &OutgoingEntry) -> Result<i64, ()> {
            if self.0.len() as i64 != entry.expected_tail {
                return Err(());
            }
            self.0.push(entry.blob.clone());
            Ok(self.0.len() as i64)
        }

        fn after(&self, cursor: i64) -> Vec<RelayEntry> {
            self.0
                .iter()
                .enumerate()
                .skip(cursor as usize)
                .map(|(index, blob)| RelayEntry {
                    sequence: index as i64 + 1,
                    blob: blob.clone(),
                })
                .collect()
        }
    }

    fn sync(household: &Household, log: &mut Log) {
        let cursor = household_overview(household).unwrap().cursor;
        household_ingest(household, log.after(cursor)).unwrap();
        while let Some(entry) = household_next_outgoing(household).unwrap() {
            match log.append(&entry) {
                Ok(sequence) => household_outgoing_accepted(household, sequence).unwrap(),
                Err(()) => {
                    let cursor = household_overview(household).unwrap().cursor;
                    household_ingest(household, log.after(cursor)).unwrap();
                }
            }
        }
    }

    fn pair() -> (Log, Household, Household) {
        let mut log = Log::default();
        let alice = household_new("alice-laptop".to_owned(), "USD".to_owned()).unwrap();
        let bob = household_new("bob-phone".to_owned(), "USD".to_owned()).unwrap();
        let group = household_found(&alice).unwrap();
        let staged = household_begin_invite(&alice, household_key_package(&bob).unwrap()).unwrap();
        let sequence = log.append(&staged.commit).unwrap();
        household_commit_accepted(&alice, sequence).unwrap();
        household_join(&bob, group, staged.welcome, sequence).unwrap();
        (log, alice, bob)
    }

    fn open_and_spend(household: &Household) {
        household_open_account(
            household,
            "joint".to_owned(),
            "Joint".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        household_record_transaction(
            household,
            "dinner".to_owned(),
            "joint".to_owned(),
            EntryKind::Expense,
            "40.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Dinner".to_owned(),
            None,
            2,
        )
        .unwrap();
    }

    #[test]
    fn two_bridge_households_share_an_expense_and_show_its_labels() {
        let (mut log, alice, bob) = pair();
        open_and_spend(&alice);
        sync(&alice, &mut log);
        sync(&bob, &mut log);

        let overview = household_overview(&bob).unwrap();
        assert!(overview.is_member);
        assert_eq!(overview.member_ids, ["alice-laptop", "bob-phone"]);
        assert_eq!(overview.balance_label, "USD -40.00");
        assert_eq!(overview.accounts[0].name, "Joint");
        assert_eq!(overview.transactions.len(), 1);
        assert_eq!(overview.transactions[0].title, "Dinner");
        assert_eq!(overview.transactions[0].amount_label, "USD 40.00");
        assert!(overview.transactions[0].is_expense);
        assert!(!overview.transactions[0].conflicted);
        assert_eq!(overview.pending_count, 0);
        assert_eq!(household_overview(&alice).unwrap().cursor, overview.cursor);
    }

    #[test]
    fn concurrent_edits_surface_as_a_visible_conflict() {
        let (mut log, alice, bob) = pair();
        open_and_spend(&alice);
        sync(&alice, &mut log);
        sync(&bob, &mut log);

        household_adjust_amount(
            &alice,
            "dinner".to_owned(),
            "45.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            10,
        )
        .unwrap();
        household_adjust_amount(
            &bob,
            "dinner".to_owned(),
            "42.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            11,
        )
        .unwrap();
        for _ in 0..2 {
            sync(&alice, &mut log);
            sync(&bob, &mut log);
        }

        for household in [&alice, &bob] {
            let overview = household_overview(household).unwrap();
            assert_eq!(overview.conflicts.len(), 1);
            assert_eq!(overview.conflicts[0].transaction_id, "dinner");
            assert!(overview.transactions[0].conflicted);
            assert_eq!(overview.balance_label, "USD -42.00");
        }
    }

    #[test]
    fn an_edit_after_a_void_is_reported_as_rejected() {
        let (mut log, alice, bob) = pair();
        open_and_spend(&alice);
        sync(&alice, &mut log);
        sync(&bob, &mut log);

        household_void_transaction(&alice, "dinner".to_owned(), 10).unwrap();
        household_adjust_amount(
            &bob,
            "dinner".to_owned(),
            "42.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            11,
        )
        .unwrap();
        for _ in 0..2 {
            sync(&alice, &mut log);
            sync(&bob, &mut log);
        }
        let overview = household_overview(&alice).unwrap();
        assert!(overview.transactions[0].voided);
        assert_eq!(overview.balance_label, "USD 0.00");
        assert_eq!(overview.rejected.len(), 1);
    }

    #[test]
    fn a_foreign_currency_entry_shows_its_reporting_value() {
        let (mut log, alice, bob) = pair();
        household_open_account(
            &alice,
            "eur".to_owned(),
            "Euro".to_owned(),
            "EUR".to_owned(),
            1,
        )
        .unwrap();
        household_record_transaction(
            &alice,
            "hotel".to_owned(),
            "eur".to_owned(),
            EntryKind::Expense,
            "100.00".to_owned(),
            "EUR".to_owned(),
            11,
            10,
            "Hotel".to_owned(),
            None,
            2,
        )
        .unwrap();
        sync(&alice, &mut log);
        sync(&bob, &mut log);
        let overview = household_overview(&bob).unwrap();
        assert_eq!(overview.accounts[0].balance_label, "EUR -100.00");
        assert_eq!(
            overview.accounts[0].reporting_balance_label.as_deref(),
            Some("USD -110.00")
        );
    }

    #[test]
    fn invalid_input_is_an_error_not_a_state_change() {
        let (_, alice, _) = pair();
        let bad = household_record_transaction(
            &alice,
            "t".to_owned(),
            "joint".to_owned(),
            EntryKind::Expense,
            "0.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Zero".to_owned(),
            None,
            1,
        );
        assert!(bad.is_err());
        assert!(household_join(&alice, "g".to_owned(), vec![1], -1).is_err());
        assert!(household_new("x".to_owned(), "usd".to_owned()).is_err());
        assert_eq!(household_overview(&alice).unwrap().pending_count, 0);
    }

    #[test]
    fn export_and_restore_keep_the_household_working() {
        let (mut log, alice, bob) = pair();
        open_and_spend(&alice);
        sync(&alice, &mut log);

        let saved = household_export(&bob).unwrap();
        drop(bob);
        let bob = household_restore(saved).unwrap();
        sync(&bob, &mut log);
        assert_eq!(household_overview(&bob).unwrap().transactions.len(), 1);
        assert_eq!(household_overview(&bob).unwrap().member_id, "bob-phone");
    }

    #[test]
    fn safety_numbers_match_across_the_bridge() {
        let (_, alice, bob) = pair();
        let from_alice = household_safety_number(&alice, "bob-phone".to_owned()).unwrap();
        let from_bob = household_safety_number(&bob, "alice-laptop".to_owned()).unwrap();
        assert_eq!(from_alice, from_bob);
        assert!(household_safety_number(&alice, "mallory".to_owned()).is_err());
    }

    #[test]
    fn recovery_round_trips_a_household_backup() {
        let (mut log, alice, bob) = pair();
        open_and_spend(&alice);
        sync(&alice, &mut log);
        sync(&bob, &mut log);

        let phrase = recovery_generate_phrase();
        recovery_validate_phrase(phrase.clone()).unwrap();
        let sealed = recovery_seal(phrase.clone(), household_export(&bob).unwrap()).unwrap();
        let restored = household_restore(recovery_open(phrase, sealed.clone()).unwrap()).unwrap();
        assert_eq!(household_overview(&restored).unwrap().transactions.len(), 1);

        assert!(recovery_open(recovery_generate_phrase(), sealed).is_err());
        assert!(recovery_validate_phrase("not a phrase".to_owned()).is_err());
    }

    #[test]
    fn removal_locks_a_member_out_through_the_bridge() {
        let (mut log, alice, bob) = pair();
        let commit = household_begin_removal(&alice, "bob-phone".to_owned()).unwrap();
        let sequence = log.append(&commit).unwrap();
        household_commit_accepted(&alice, sequence).unwrap();
        sync(&bob, &mut log);
        assert!(!household_overview(&bob).unwrap().is_member);
    }
}
