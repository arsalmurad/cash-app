use std::collections::{BTreeMap, btree_map::Entry};
use std::fmt;

use crate::{
    AccountId, Currency, Event, EventId, EventKind, FxRate, Money, MoneyError, TransactionId,
    TransactionKind,
};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountState {
    pub name: String,
    pub currency: Currency,
    pub native_balance_minor: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TransactionState {
    pub account_id: AccountId,
    pub kind: TransactionKind,
    pub original: Money,
    pub reporting_fx: FxRate,
    pub reporting_minor: i64,
    pub title: String,
    pub category_id: Option<String>,
    pub voided: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LedgerState {
    pub reporting_currency: Currency,
    pub reporting_balance_minor: i64,
    pub accounts: BTreeMap<AccountId, AccountState>,
    pub transactions: BTreeMap<TransactionId, TransactionState>,
}

impl LedgerState {
    pub fn empty(reporting_currency: Currency) -> Self {
        Self {
            reporting_currency,
            reporting_balance_minor: 0,
            accounts: BTreeMap::new(),
            transactions: BTreeMap::new(),
        }
    }

    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut bytes = Vec::new();
        write_string(&mut bytes, self.reporting_currency.code());
        write_i64(&mut bytes, self.reporting_balance_minor);
        write_u64(&mut bytes, self.accounts.len() as u64);
        for (id, account) in &self.accounts {
            write_string(&mut bytes, id.as_str());
            write_string(&mut bytes, &account.name);
            write_string(&mut bytes, account.currency.code());
            bytes.push(account.currency.exponent());
            write_i64(&mut bytes, account.native_balance_minor);
        }
        write_u64(&mut bytes, self.transactions.len() as u64);
        for (id, transaction) in &self.transactions {
            write_string(&mut bytes, id.as_str());
            write_string(&mut bytes, transaction.account_id.as_str());
            bytes.push(match transaction.kind {
                TransactionKind::Expense => 0,
                TransactionKind::Income => 1,
            });
            write_i64(&mut bytes, transaction.original.minor_units);
            write_string(&mut bytes, transaction.original.currency.code());
            write_i64(&mut bytes, transaction.reporting_fx.numerator);
            write_i64(&mut bytes, transaction.reporting_fx.denominator);
            write_i64(&mut bytes, transaction.reporting_minor);
            write_string(&mut bytes, &transaction.title);
            match &transaction.category_id {
                Some(category) => {
                    bytes.push(1);
                    write_string(&mut bytes, category);
                }
                None => bytes.push(0),
            }
            bytes.push(u8::from(transaction.voided));
        }
        bytes
    }

    pub(crate) fn apply(&mut self, event: &Event) -> Result<(), FoldError> {
        match &event.kind {
            EventKind::AccountOpened {
                account_id,
                name,
                currency,
            } => match self.accounts.entry(account_id.clone()) {
                Entry::Vacant(entry) => {
                    entry.insert(AccountState {
                        name: name.clone(),
                        currency: currency.clone(),
                        native_balance_minor: 0,
                    });
                }
                Entry::Occupied(_) => {
                    return Err(FoldError::AccountAlreadyExists(account_id.clone()));
                }
            },
            EventKind::TransactionRecorded {
                transaction_id,
                account_id,
                kind,
                original,
                reporting_fx,
                title,
                category_id,
            } => {
                if reporting_fx.target_currency != self.reporting_currency {
                    return Err(FoldError::ReportingCurrencyMismatch);
                }
                let account = self
                    .accounts
                    .get_mut(account_id)
                    .ok_or_else(|| FoldError::UnknownAccount(account_id.clone()))?;
                if account.currency != original.currency {
                    return Err(FoldError::AccountCurrencyMismatch(account_id.clone()));
                }
                if self.transactions.contains_key(transaction_id) {
                    return Err(FoldError::TransactionAlreadyExists(transaction_id.clone()));
                }
                let reporting_minor = reporting_fx.convert_minor_units(original.minor_units)?;
                let signed_native = signed(*kind, original.minor_units)?;
                let signed_reporting = signed(*kind, reporting_minor)?;
                account.native_balance_minor =
                    checked_add(account.native_balance_minor, signed_native)?;
                self.reporting_balance_minor =
                    checked_add(self.reporting_balance_minor, signed_reporting)?;
                self.transactions.insert(
                    transaction_id.clone(),
                    TransactionState {
                        account_id: account_id.clone(),
                        kind: *kind,
                        original: original.clone(),
                        reporting_fx: reporting_fx.clone(),
                        reporting_minor,
                        title: title.clone(),
                        category_id: category_id.clone(),
                        voided: false,
                    },
                );
            }
            EventKind::AmountAdjusted {
                transaction_id,
                original,
                reporting_fx,
            } => {
                let transaction = self
                    .transactions
                    .get_mut(transaction_id)
                    .ok_or_else(|| FoldError::UnknownTransaction(transaction_id.clone()))?;
                if transaction.voided {
                    return Err(FoldError::TransactionIsVoided(transaction_id.clone()));
                }
                let account = self
                    .accounts
                    .get_mut(&transaction.account_id)
                    .ok_or_else(|| FoldError::UnknownAccount(transaction.account_id.clone()))?;
                if account.currency != original.currency {
                    return Err(FoldError::AccountCurrencyMismatch(
                        transaction.account_id.clone(),
                    ));
                }
                if reporting_fx.target_currency != self.reporting_currency {
                    return Err(FoldError::ReportingCurrencyMismatch);
                }
                let new_reporting = reporting_fx.convert_minor_units(original.minor_units)?;
                let native_delta =
                    checked_sub(original.minor_units, transaction.original.minor_units)?;
                let reporting_delta = checked_sub(new_reporting, transaction.reporting_minor)?;
                account.native_balance_minor = checked_add(
                    account.native_balance_minor,
                    signed(transaction.kind, native_delta)?,
                )?;
                self.reporting_balance_minor = checked_add(
                    self.reporting_balance_minor,
                    signed(transaction.kind, reporting_delta)?,
                )?;
                transaction.original = original.clone();
                transaction.reporting_fx = reporting_fx.clone();
                transaction.reporting_minor = new_reporting;
            }
            EventKind::CategoryAssigned {
                transaction_id,
                category_id,
            } => {
                let transaction = self
                    .transactions
                    .get_mut(transaction_id)
                    .ok_or_else(|| FoldError::UnknownTransaction(transaction_id.clone()))?;
                transaction.category_id = category_id.clone();
            }
            EventKind::TransactionVoided { transaction_id } => {
                let transaction = self
                    .transactions
                    .get_mut(transaction_id)
                    .ok_or_else(|| FoldError::UnknownTransaction(transaction_id.clone()))?;
                if !transaction.voided {
                    let account = self
                        .accounts
                        .get_mut(&transaction.account_id)
                        .ok_or_else(|| FoldError::UnknownAccount(transaction.account_id.clone()))?;
                    account.native_balance_minor = checked_sub(
                        account.native_balance_minor,
                        signed(transaction.kind, transaction.original.minor_units)?,
                    )?;
                    self.reporting_balance_minor = checked_sub(
                        self.reporting_balance_minor,
                        signed(transaction.kind, transaction.reporting_minor)?,
                    )?;
                    transaction.voided = true;
                }
            }
        }
        Ok(())
    }
}

pub fn fold(
    reporting_currency: Currency,
    events: impl IntoIterator<Item = Event>,
) -> Result<LedgerState, FoldError> {
    let events = validate_deduplicate_and_sort(events)?;
    let mut state = LedgerState::empty(reporting_currency);
    for event in &events {
        state.apply(event)?;
    }
    Ok(state)
}

pub(crate) fn validate_deduplicate_and_sort(
    events: impl IntoIterator<Item = Event>,
) -> Result<Vec<Event>, FoldError> {
    let mut by_id: BTreeMap<EventId, Event> = BTreeMap::new();
    for event in events {
        match by_id.entry(event.id.clone()) {
            Entry::Vacant(entry) => {
                entry.insert(event);
            }
            Entry::Occupied(entry) if entry.get() == &event => {}
            Entry::Occupied(_) => return Err(FoldError::ConflictingDuplicateEvent(event.id)),
        }
    }
    let mut events: Vec<_> = by_id.into_values().collect();
    events.sort_by_key(Event::order_key);
    Ok(events)
}

fn signed(kind: TransactionKind, value: i64) -> Result<i64, FoldError> {
    match kind {
        TransactionKind::Income => Ok(value),
        TransactionKind::Expense => value.checked_neg().ok_or(FoldError::MoneyOverflow),
    }
}

fn checked_add(left: i64, right: i64) -> Result<i64, FoldError> {
    left.checked_add(right).ok_or(FoldError::MoneyOverflow)
}

fn checked_sub(left: i64, right: i64) -> Result<i64, FoldError> {
    left.checked_sub(right).ok_or(FoldError::MoneyOverflow)
}

fn write_i64(bytes: &mut Vec<u8>, value: i64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn write_u64(bytes: &mut Vec<u8>, value: u64) {
    bytes.extend_from_slice(&value.to_be_bytes());
}

fn write_string(bytes: &mut Vec<u8>, value: &str) {
    write_u64(bytes, value.len() as u64);
    bytes.extend_from_slice(value.as_bytes());
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FoldError {
    AccountAlreadyExists(AccountId),
    AccountCurrencyMismatch(AccountId),
    ConflictingDuplicateEvent(EventId),
    MoneyOverflow,
    ReportingCurrencyMismatch,
    TransactionAlreadyExists(TransactionId),
    TransactionIsVoided(TransactionId),
    UnknownAccount(AccountId),
    UnknownTransaction(TransactionId),
}

impl From<MoneyError> for FoldError {
    fn from(error: MoneyError) -> Self {
        match error {
            MoneyError::Overflow => Self::MoneyOverflow,
            MoneyError::InvalidCurrencyCode(_) | MoneyError::InvalidRate => {
                unreachable!("invalid currencies and rates cannot be constructed")
            }
        }
    }
}

impl fmt::Display for FoldError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for FoldError {}
