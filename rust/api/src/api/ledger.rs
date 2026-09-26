use std::sync::{Mutex, MutexGuard};

use cash_core::{
    AccountId, Currency, Event, EventKind, FxRate, HybridTimestamp, LedgerState, Money,
    TransactionId, TransactionKind, fold,
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
}

pub struct LedgerOverview {
    pub balance_label: String,
    pub accounts: Vec<AccountView>,
    pub transactions: Vec<TransactionView>,
}

pub struct AccountView {
    pub id: String,
    pub name: String,
    pub balance_label: String,
}

pub struct TransactionView {
    pub id: String,
    pub title: String,
    pub amount_label: String,
    pub is_expense: bool,
    pub category_id: Option<String>,
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

pub fn create_personal_ledger(
    actor_id: String,
    reporting_currency_code: String,
) -> Result<PersonalLedger, String> {
    if actor_id.trim().is_empty() {
        return Err("actor ID cannot be empty".to_owned());
    }
    let reporting_currency =
        Currency::from_code(&reporting_currency_code).map_err(|error| error.to_string())?;
    Ok(PersonalLedger {
        data: Mutex::new(LedgerData {
            actor_id,
            reporting_currency,
            events: Vec::new(),
            last_timestamp: HybridTimestamp::new(0, 0),
        }),
    })
}

pub fn add_account(
    ledger: &PersonalLedger,
    account_id: String,
    name: String,
    currency_code: String,
    wall_clock_millis: i64,
) -> Result<LedgerOverview, String> {
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
    data.append_and_overview(event)
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
    wall_clock_millis: i64,
) -> Result<LedgerOverview, String> {
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
        },
    );
    data.append_and_overview(event)
}

pub fn get_overview(ledger: &PersonalLedger) -> Result<LedgerOverview, String> {
    lock(ledger)?.overview()
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

    fn append_and_overview(&mut self, event: Event) -> Result<LedgerOverview, String> {
        self.events.push(event);
        match self.overview() {
            Ok(overview) => Ok(overview),
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
            title: transaction.title.clone(),
            amount_label: transaction
                .original
                .currency
                .format_minor_units(transaction.original.minor_units),
            is_expense: transaction.kind == TransactionKind::Expense,
            category_id: transaction.category_id.clone(),
        })
        .collect();
    LedgerOverview {
        balance_label: state
            .reporting_currency
            .format_minor_units(state.reporting_balance_minor),
        accounts,
        transactions,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_api_records_money_in_the_rust_ledger() {
        let ledger = create_personal_ledger("device-a".to_owned(), "USD".to_owned()).unwrap();
        let overview = add_account(
            &ledger,
            "checking".to_owned(),
            "Checking".to_owned(),
            "USD".to_owned(),
            1,
        )
        .unwrap();
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
            2,
        )
        .unwrap();

        assert_eq!(overview.balance_label, "USD -12.34");
        assert_eq!(overview.transactions[0].amount_label, "USD 12.34");
        assert!(overview.transactions[0].is_expense);
    }

    #[test]
    fn rejected_event_does_not_poison_the_in_memory_log() {
        let ledger = create_personal_ledger("device-a".to_owned(), "USD".to_owned()).unwrap();
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
}
