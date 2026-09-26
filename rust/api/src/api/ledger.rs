use std::sync::{Mutex, MutexGuard};

use cash_core::{
    AccountId, Currency, Event, EventKind, FxRate, HybridTimestamp, LedgerState, Money,
    TransactionId, TransactionKind, decode_event_log, encode_event_frame, fold,
};
use flutter_rust_bridge::frb;

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

#[frb(opaque)]
pub struct PersonalLedger {
    data: Mutex<LedgerData>,
}

struct LedgerData {
    actor_id: String,
    reporting_currency: Currency,
    events: Vec<Event>,
    last_timestamp: HybridTimestamp,
    recovered_event_count: u64,
    truncated_bytes: u64,
}

#[derive(Debug, PartialEq)]
pub struct LedgerOverview {
    pub balance_label: String,
    pub accounts: Vec<AccountView>,
    pub transactions: Vec<TransactionView>,
    pub transfers: Vec<TransferView>,
}

/// The result of a mutation that appended one event. `appended_frame` is the
/// durable-log frame for that event and only exists when the mutation
/// succeeded: a rejected write never reaches this struct, so it can never be
/// persisted. The caller (Dart) must append these bytes to its durable store
/// before treating the mutation as committed.
pub struct LedgerMutation {
    pub overview: LedgerOverview,
    pub appended_frame: Vec<u8>,
}

/// Diagnostics from the load that produced a ledger's current in-memory
/// state. `recovered_event_count` and `truncated_bytes` let the caller
/// distinguish a clean load from one that dropped a torn write at the tail,
/// per [`cash_core::decode_event_log`].
#[derive(Debug, PartialEq)]
pub struct LoadReport {
    pub overview: LedgerOverview,
    pub recovered_event_count: u64,
    pub truncated_bytes: u64,
}

#[derive(Debug, PartialEq)]
pub struct AccountView {
    pub id: String,
    pub name: String,
    pub currency_code: String,
    pub balance_label: String,
}

#[derive(Debug, PartialEq)]
pub struct TransactionView {
    pub id: String,
    pub account_id: String,
    pub title: String,
    pub amount_label: String,
    pub is_expense: bool,
    pub category_id: Option<String>,
}

#[derive(Debug, PartialEq)]
pub struct TransferView {
    pub id: String,
    pub title: String,
    pub from_account_id: String,
    pub to_account_id: String,
    pub sent_label: String,
    pub received_label: String,
}

pub enum EntryKind {
    Expense,
    Income,
}

impl From<EntryKind> for TransactionKind {
    fn from(value: EntryKind) -> Self {
        match value {
            EntryKind::Expense => Self::Expense,
            EntryKind::Income => Self::Income,
        }
    }
}

/// Opens a personal ledger by replaying a durable log's bytes. Pass an empty
/// `log_bytes` for a brand-new installation; this is the only ledger
/// constructor, so first launch and every later restart share one code path.
/// Call [`load_report`] on the result to see what was recovered.
///
/// `actor_id` must be the same stable identifier persisted alongside the log
/// on a previous launch: it anchors this device's place in the total order,
/// and changing it after events exist would let two different actors claim
/// the same event IDs.
pub fn load_personal_ledger(
    actor_id: String,
    reporting_currency_code: String,
    log_bytes: Vec<u8>,
) -> Result<PersonalLedger, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let reporting_currency =
        Currency::from_code(&reporting_currency_code).map_err(|error| error.to_string())?;

    let decoded = decode_event_log(&log_bytes);
    let last_timestamp = decoded
        .events
        .iter()
        .map(|event| event.timestamp)
        .max()
        .unwrap_or(HybridTimestamp::new(0, 0));
    let recovered_event_count = decoded.events.len() as u64;
    // Fold eagerly so a corrupted-but-checksum-valid log (a real conflict,
    // not a torn write) is rejected here rather than surfacing later as a
    // confusing failure from `get_overview`.
    fold(reporting_currency.clone(), decoded.events.clone()).map_err(|error| error.to_string())?;

    Ok(PersonalLedger {
        data: Mutex::new(LedgerData {
            actor_id,
            reporting_currency,
            events: decoded.events,
            last_timestamp,
            recovered_event_count,
            truncated_bytes: decoded.trailing_garbage_bytes as u64,
        }),
    })
}

/// Reports what a completed [`load_personal_ledger`] call recovered.
pub fn load_report(ledger: &PersonalLedger) -> Result<LoadReport, String> {
    let data = lock(ledger)?;
    Ok(LoadReport {
        overview: data.overview()?,
        recovered_event_count: data.recovered_event_count,
        truncated_bytes: data.truncated_bytes,
    })
}

pub fn add_account(
    ledger: &PersonalLedger,
    account_id: String,
    name: String,
    currency_code: String,
    wall_clock_millis: i64,
) -> Result<LedgerMutation, String> {
    let currency = Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    let mut data = lock(ledger)?;
    let event = data.next_event(
        wall_clock_millis,
        EventKind::AccountOpened {
            account_id: AccountId::new(account_id),
            name,
            currency,
        },
    );
    data.append_and_mutation(event)
}

#[allow(clippy::too_many_arguments)]
pub fn record_transaction(
    ledger: &PersonalLedger,
    transaction_id: String,
    account_id: String,
    kind: EntryKind,
    amount: String,
    currency_code: String,
    fx_numerator: i64,
    fx_denominator: i64,
    title: String,
    category_id: Option<String>,
    recurring_id: Option<String>,
    wall_clock_millis: i64,
) -> Result<LedgerMutation, String> {
    let currency = Currency::from_code(&currency_code).map_err(|error| error.to_string())?;
    let minor_units = currency
        .parse_major_units(&amount)
        .map_err(|error| error.to_string())?;
    if minor_units <= 0 {
        return Err("transaction amount must be greater than zero".to_owned());
    }

    let mut data = lock(ledger)?;
    let rate = FxRate::new(
        fx_numerator,
        fx_denominator,
        data.reporting_currency.clone(),
    )
    .map_err(|error| error.to_string())?;
    let event = data.next_event(
        wall_clock_millis,
        EventKind::TransactionRecorded {
            transaction_id: TransactionId::new(transaction_id),
            account_id: AccountId::new(account_id),
            kind: kind.into(),
            original: Money::new(minor_units, currency),
            reporting_fx: rate,
            title,
            category_id,
            recurring_id,
        },
    );
    data.append_and_mutation(event)
}

/// Records a transfer between two of this ledger's own accounts.
/// `sent_amount`/`sent_currency_code` must match `from_account_id`'s
/// currency, and `received_amount`/`received_currency_code` must match
/// `to_account_id`'s; for a same-currency transfer these are normally equal,
/// but nothing here requires it (see `cash_core::EventKind::TransferRecorded`
/// for why a cross-currency spread stays visible rather than assumed away).
#[allow(clippy::too_many_arguments)]
pub fn record_transfer(
    ledger: &PersonalLedger,
    transfer_id: String,
    from_account_id: String,
    to_account_id: String,
    sent_amount: String,
    sent_currency_code: String,
    sent_fx_numerator: i64,
    sent_fx_denominator: i64,
    received_amount: String,
    received_currency_code: String,
    received_fx_numerator: i64,
    received_fx_denominator: i64,
    title: String,
    wall_clock_millis: i64,
) -> Result<LedgerMutation, String> {
    if from_account_id == to_account_id {
        return Err("cannot transfer an account to itself".to_owned());
    }
    let sent_currency =
        Currency::from_code(&sent_currency_code).map_err(|error| error.to_string())?;
    let sent_minor_units = sent_currency
        .parse_major_units(&sent_amount)
        .map_err(|error| error.to_string())?;
    if sent_minor_units <= 0 {
        return Err("sent amount must be greater than zero".to_owned());
    }
    let received_currency =
        Currency::from_code(&received_currency_code).map_err(|error| error.to_string())?;
    let received_minor_units = received_currency
        .parse_major_units(&received_amount)
        .map_err(|error| error.to_string())?;
    if received_minor_units <= 0 {
        return Err("received amount must be greater than zero".to_owned());
    }

    let mut data = lock(ledger)?;
    let sent_fx = FxRate::new(
        sent_fx_numerator,
        sent_fx_denominator,
        data.reporting_currency.clone(),
    )
    .map_err(|error| error.to_string())?;
    let received_fx = FxRate::new(
        received_fx_numerator,
        received_fx_denominator,
        data.reporting_currency.clone(),
    )
    .map_err(|error| error.to_string())?;
    let event = data.next_event(
        wall_clock_millis,
        EventKind::TransferRecorded {
            transfer_id: TransactionId::new(transfer_id),
            from_account_id: AccountId::new(from_account_id),
            to_account_id: AccountId::new(to_account_id),
            sent: Money::new(sent_minor_units, sent_currency),
            sent_reporting_fx: sent_fx,
            received: Money::new(received_minor_units, received_currency),
            received_reporting_fx: received_fx,
            title,
        },
    );
    data.append_and_mutation(event)
}

pub fn get_overview(ledger: &PersonalLedger) -> Result<LedgerOverview, String> {
    lock(ledger)?.overview()
}

/// Exposes the ledger's raw folded state to sibling bridge modules that need
/// more than `LedgerOverview` gives (e.g. `api::budgets`, which sums raw
/// `reporting_minor` amounts by category and date rather than displaying
/// formatted transaction labels).
pub(crate) fn folded_state(ledger: &PersonalLedger) -> Result<LedgerState, String> {
    let data = lock(ledger)?;
    fold(data.reporting_currency.clone(), data.events.clone()).map_err(|error| error.to_string())
}

/// "Custom titles that auto-assign on repeat" (build brief §5): the category
/// of the most recent past transaction whose title matches, trimmed and
/// case-insensitive, or `None` if nothing matches (or that transaction had
/// no category either). This is a UI convenience, not part of the ledger's
/// financial state, so it never fails the way recording a transaction can.
pub fn suggest_category_for_title(
    ledger: &PersonalLedger,
    title: String,
) -> Result<Option<String>, String> {
    let data = lock(ledger)?;
    let normalized = title.trim().to_lowercase();
    if normalized.is_empty() {
        return Ok(None);
    }
    let mut ordered: Vec<&Event> = data.events.iter().collect();
    ordered.sort_by_key(|event| event.order_key());
    let suggestion = ordered
        .into_iter()
        .rev()
        .find_map(|event| match &event.kind {
            EventKind::TransactionRecorded {
                title: recorded_title,
                category_id,
                ..
            } if recorded_title.trim().to_lowercase() == normalized => Some(category_id.clone()),
            _ => None,
        });
    Ok(suggestion.flatten())
}

fn lock(ledger: &PersonalLedger) -> Result<MutexGuard<'_, LedgerData>, String> {
    ledger
        .data
        .lock()
        .map_err(|_| "personal ledger lock was poisoned".to_owned())
}

impl LedgerData {
    fn next_event(&mut self, wall_clock_millis: i64, kind: EventKind) -> Event {
        let timestamp = if wall_clock_millis > self.last_timestamp.physical_millis {
            HybridTimestamp::new(wall_clock_millis, 0)
        } else {
            HybridTimestamp::new(
                self.last_timestamp.physical_millis,
                self.last_timestamp.logical.saturating_add(1),
            )
        };
        self.last_timestamp = timestamp;
        let id = format!(
            "{}-{:016x}-{:08x}",
            self.actor_id, timestamp.physical_millis, timestamp.logical
        );
        Event::new(
            id,
            self.actor_id.clone(),
            timestamp.physical_millis,
            timestamp.logical,
            kind,
        )
    }

    fn overview(&self) -> Result<LedgerOverview, String> {
        let state = fold(self.reporting_currency.clone(), self.events.clone())
            .map_err(|error| error.to_string())?;
        Ok(overview_from_state(state))
    }

    fn append_and_mutation(&mut self, event: Event) -> Result<LedgerMutation, String> {
        let appended_frame = encode_event_frame(&event);
        self.events.push(event);
        match self.overview() {
            Ok(overview) => Ok(LedgerMutation {
                overview,
                appended_frame,
            }),
            Err(error) => {
                self.events.pop();
                Err(error)
            }
        }
    }
}

fn overview_from_state(state: LedgerState) -> LedgerOverview {
    let accounts = state
        .accounts
        .iter()
        .map(|(id, account)| AccountView {
            id: id.as_str().to_owned(),
            name: account.name.clone(),
            currency_code: account.currency.code().to_owned(),
            balance_label: account
                .currency
                .format_minor_units(account.native_balance_minor),
        })
        .collect();
    let transactions = state
        .transactions
        .iter()
        .rev()
        .map(|(id, transaction)| TransactionView {
            id: id.as_str().to_owned(),
            account_id: transaction.account_id.as_str().to_owned(),
            title: transaction.title.clone(),
            amount_label: transaction
                .original
                .currency
                .format_minor_units(transaction.original.minor_units),
            is_expense: transaction.kind == TransactionKind::Expense,
            category_id: transaction.category_id.clone(),
        })
        .collect();
    let transfers = state
        .transfers
        .iter()
        .rev()
        .map(|(id, transfer)| TransferView {
            id: id.as_str().to_owned(),
            title: transfer.title.clone(),
            from_account_id: transfer.from_account_id.as_str().to_owned(),
            to_account_id: transfer.to_account_id.as_str().to_owned(),
            sent_label: transfer
                .sent
                .currency
                .format_minor_units(transfer.sent.minor_units),
            received_label: transfer
                .received
                .currency
                .format_minor_units(transfer.received.minor_units),
        })
        .collect();
    LedgerOverview {
        balance_label: state
            .reporting_currency
            .format_minor_units(state.reporting_balance_minor),
        accounts,
        transactions,
        transfers,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_ledger(actor_id: &str) -> PersonalLedger {
        load_personal_ledger(actor_id.to_owned(), "USD".to_owned(), Vec::new()).unwrap()
    }

    #[test]
    fn bridge_api_records_money_in_the_rust_ledger() {
        let ledger = new_ledger("device-a");
        let overview = add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap()
        .overview;
        assert_eq!(overview.balance_label, "USD 0.00");

        let overview = record_transaction(
            &ledger,
            "groceries-1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "12.34".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Groceries".to_owned(),
            Some("food".to_owned()),
            None,
            2,
        )
        .unwrap()
        .overview;

        assert_eq!(overview.balance_label, "USD -12.34");
        assert_eq!(overview.transactions[0].amount_label, "USD 12.34");
        assert!(overview.transactions[0].is_expense);
    }

    #[test]
    fn rejected_event_does_not_poison_the_in_memory_log() {
        let ledger = new_ledger("device-a");
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        assert!(
            add_account(
                &ledger,
                "checking".to_owned(),
                "Duplicate".to_owned(),
                "USD".to_owned(),
                2,
            )
            .is_err()
        );
        let overview = get_overview(&ledger).unwrap();
        assert_eq!(overview.accounts.len(), 1);
    }

    #[test]
    fn a_rejected_write_never_produces_a_frame_to_persist() {
        let ledger = new_ledger("device-a");
        let first = add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();

        // The caller can only ever learn about `appended_frame` for a
        // mutation that returned `Ok`, so a rejected duplicate has no bytes
        // that could accidentally be persisted.
        let rejected = add_account(
            &ledger,
            "checking".to_owned(),
            "Duplicate".to_owned(),
            "USD".to_owned(),
            2,
        );
        assert!(rejected.is_err());

        // Replaying only the frame from the accepted write reproduces
        // exactly the state before the rejected attempt.
        let reloaded = load_personal_ledger(
            "device-a".to_owned(),
            "USD".to_owned(),
            first.appended_frame,
        )
        .unwrap();
        let report = load_report(&reloaded).unwrap();
        assert_eq!(report.recovered_event_count, 1);
        assert_eq!(report.truncated_bytes, 0);
        assert_eq!(report.overview.accounts.len(), 1);
    }

    #[test]
    fn restart_recovers_identical_state_from_the_persisted_frames() {
        let ledger = new_ledger("device-a");
        let mut log = Vec::new();
        log.extend(
            add_account(
                &ledger,
                "checking".to_owned(),
                "Checking".to_owned(),
                "USD".to_owned(),
                1,
            )
            .unwrap()
            .appended_frame,
        );
        let before_restart = record_transaction(
            &ledger,
            "groceries-1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "12.34".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Groceries".to_owned(),
            Some("food".to_owned()),
            None,
            2,
        )
        .unwrap();
        log.extend(before_restart.appended_frame);

        let restarted = load_personal_ledger("device-a".to_owned(), "USD".to_owned(), log)
            .unwrap();
        let report = load_report(&restarted).unwrap();
        assert_eq!(report.recovered_event_count, 2);
        assert_eq!(report.truncated_bytes, 0);
        assert_eq!(report.overview, before_restart.overview);
    }

    #[test]
    fn restart_recovers_the_prefix_before_a_log_truncated_by_a_crash() {
        let ledger = new_ledger("device-a");
        let account_frame = add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap()
        .appended_frame;
        let transaction_frame = record_transaction(
            &ledger,
            "groceries-1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "12.34".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Groceries".to_owned(),
            Some("food".to_owned()),
            None,
            2,
        )
        .unwrap()
        .appended_frame;

        // Simulate the process dying mid-`flush` of the second frame: only
        // half of it made it to durable storage.
        let mut log = account_frame;
        let torn_len = transaction_frame.len() / 2;
        log.extend(&transaction_frame[..torn_len]);

        let restarted = load_personal_ledger("device-a".to_owned(), "USD".to_owned(), log)
            .unwrap();
        let report = load_report(&restarted).unwrap();
        assert_eq!(report.recovered_event_count, 1);
        // Trailing garbage is what was actually written for the torn frame,
        // not what's missing from it.
        assert_eq!(report.truncated_bytes, torn_len as u64);
        assert_eq!(report.overview.accounts.len(), 1);
        assert!(report.overview.transactions.is_empty());
        assert_eq!(report.overview.balance_label, "USD 0.00");
    }

    #[test]
    fn restart_continues_the_hybrid_clock_even_if_the_new_wall_clock_lags() {
        let ledger = new_ledger("device-a");
        let frame = add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1_000_000,
        )
        .unwrap()
        .appended_frame;

        let restarted =
            load_personal_ledger("device-a".to_owned(), "USD".to_owned(), frame).unwrap();
        let persisted_timestamp = restarted.data.lock().unwrap().last_timestamp;
        assert_eq!(persisted_timestamp, HybridTimestamp::new(1_000_000, 0));

        // The device's wall clock reads earlier after restart (skew, or a
        // clock that resets across reboots). The next event must still sort
        // strictly after everything already persisted.
        let mutation = add_account(
            &restarted,
            "savings".to_owned(),
            "Savings".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        let advanced_timestamp = restarted.data.lock().unwrap().last_timestamp;
        assert!(advanced_timestamp > persisted_timestamp);
        assert_eq!(mutation.overview.accounts.len(), 2);
    }

    #[test]
    fn a_repeated_title_suggests_its_previous_category() {
        let ledger = new_ledger("device-a");
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        record_transaction(
            &ledger,
            "t1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "12.34".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "  Groceries  ".to_owned(),
            Some("food".to_owned()),
            None,
            2,
        )
        .unwrap();

        assert_eq!(
            suggest_category_for_title(&ledger, "groceries".to_owned()).unwrap(),
            Some("food".to_owned())
        );
        assert_eq!(
            suggest_category_for_title(&ledger, "GROCERIES".to_owned()).unwrap(),
            Some("food".to_owned())
        );
        assert_eq!(
            suggest_category_for_title(&ledger, "Rent".to_owned()).unwrap(),
            None
        );
    }

    #[test]
    fn a_title_suggestion_follows_the_most_recent_matching_transaction() {
        let ledger = new_ledger("device-a");
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        record_transaction(
            &ledger,
            "t1".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "5.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Coffee".to_owned(),
            Some("food".to_owned()),
            None,
            2,
        )
        .unwrap();
        record_transaction(
            &ledger,
            "t2".to_owned(),
            "checking".to_owned(),
            EntryKind::Expense,
            "6.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Coffee".to_owned(),
            Some("drinks".to_owned()),
            None,
            3,
        )
        .unwrap();

        assert_eq!(
            suggest_category_for_title(&ledger, "Coffee".to_owned()).unwrap(),
            Some("drinks".to_owned())
        );
    }

    #[test]
    fn a_transfer_moves_balance_between_two_accounts() {
        let ledger = new_ledger("device-a");
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
        add_account(
            &ledger,
            "savings".to_owned(),
            "Savings".to_owned(),
            "USD".to_owned(),
            2,
        )
        .unwrap();

        let mutation = record_transfer(
            &ledger,
            "t1".to_owned(),
            "checking".to_owned(),
            "savings".to_owned(),
            "50.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "50.00".to_owned(),
            "USD".to_owned(),
            1,
            1,
            "Move to savings".to_owned(),
            3,
        )
        .unwrap();

        let checking = mutation
            .overview
            .accounts
            .iter()
            .find(|account| account.id == "checking")
            .unwrap();
        let savings = mutation
            .overview
            .accounts
            .iter()
            .find(|account| account.id == "savings")
            .unwrap();
        assert_eq!(checking.balance_label, "USD -50.00");
        assert_eq!(savings.balance_label, "USD 50.00");
        assert_eq!(mutation.overview.balance_label, "USD 0.00");
        assert_eq!(mutation.overview.transfers.len(), 1);
        assert_eq!(mutation.overview.transfers[0].sent_label, "USD 50.00");
        assert_eq!(mutation.overview.transfers[0].received_label, "USD 50.00");
    }

    #[test]
    fn a_transfer_to_the_same_account_is_rejected_by_the_bridge() {
        let ledger = new_ledger("device-a");
        add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();

        assert!(
            record_transfer(
                &ledger,
                "t1".to_owned(),
                "checking".to_owned(),
                "checking".to_owned(),
                "10.00".to_owned(),
                "USD".to_owned(),
                1,
                1,
                "10.00".to_owned(),
                "USD".to_owned(),
                1,
                1,
                "Oops".to_owned(),
                2,
            )
            .is_err()
        );
    }

    #[test]
    fn restart_recovers_a_transfer_from_its_persisted_frame() {
        let ledger = new_ledger("device-a");
        let mut log = Vec::new();
        log.extend(
            add_account(
                &ledger,
                "checking".to_owned(),
                "Checking".to_owned(),
                "USD".to_owned(),
                1,
            )
            .unwrap()
            .appended_frame,
        );
        log.extend(
            add_account(
                &ledger,
                "savings".to_owned(),
                "Savings".to_owned(),
                "USD".to_owned(),
                2,
            )
            .unwrap()
            .appended_frame,
        );
        log.extend(
            record_transfer(
                &ledger,
                "t1".to_owned(),
                "checking".to_owned(),
                "savings".to_owned(),
                "25.00".to_owned(),
                "USD".to_owned(),
                1,
                1,
                "25.00".to_owned(),
                "USD".to_owned(),
                1,
                1,
                "Move to savings".to_owned(),
                3,
            )
            .unwrap()
            .appended_frame,
        );

        let restarted = load_personal_ledger("device-a".to_owned(), "USD".to_owned(), log)
            .unwrap();
        let report = load_report(&restarted).unwrap();
        assert_eq!(report.recovered_event_count, 3);
        assert_eq!(report.truncated_bytes, 0);
        assert_eq!(report.overview.transfers.len(), 1);
    }
}
