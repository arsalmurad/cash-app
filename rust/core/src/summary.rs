//! Explicitly chosen, immutable aggregate values. No private source identifiers
//! or free-form labels cross this boundary. This is a snapshot, not a subscription
//! and not a financial event: it cannot change accounts, balances or transactions.

use std::fmt;

use crate::{Currency, LedgerState, TransactionKind};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct SummarySelection {
    pub income: bool,
    pub expenses: bool,
}

/// Only these values may enter a shared publication. Missing totals mean the
/// user did not select them; selected periods with no entries have `Some(0)`.
/// Times describe a caller-selected half-open interval, with no implicit UTC
/// month or current-clock policy. A UI must show its local date interpretation.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChosenSummary {
    currency: Currency,
    start_millis: i64,
    end_millis_exclusive: i64,
    income_minor: Option<i64>,
    expenses_minor: Option<i64>,
}

impl ChosenSummary {
    pub fn new(
        currency: Currency,
        start_millis: i64,
        end_millis_exclusive: i64,
        income_minor: Option<i64>,
        expenses_minor: Option<i64>,
    ) -> Result<Self, SummaryError> {
        if start_millis >= end_millis_exclusive {
            return Err(SummaryError::InvalidPeriod);
        }
        if income_minor.is_none() && expenses_minor.is_none() {
            return Err(SummaryError::NothingSelected);
        }
        Ok(Self {
            currency,
            start_millis,
            end_millis_exclusive,
            income_minor,
            expenses_minor,
        })
    }

    pub fn currency(&self) -> &Currency {
        &self.currency
    }
    pub fn start_millis(&self) -> i64 {
        self.start_millis
    }
    pub fn end_millis_exclusive(&self) -> i64 {
        self.end_millis_exclusive
    }
    pub fn income_minor(&self) -> Option<i64> {
        self.income_minor
    }
    pub fn expenses_minor(&self) -> Option<i64> {
        self.expenses_minor
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SummaryError {
    NothingSelected,
    InvalidPeriod,
    Overflow,
}

impl fmt::Display for SummaryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NothingSelected => "choose at least one total to share",
            Self::InvalidPeriod => "the summary period must end after it starts",
            Self::Overflow => "the selected total exceeds signed 64-bit minor units",
        })
    }
}

impl std::error::Error for SummaryError {}

/// Summarizes the current fold, using each entry's original recorded date and
/// frozen reporting amount. Transfers and removed transactions are excluded.
/// Corrections are included now, but cannot mutate a previously returned value.
pub fn chosen_summary(
    state: &LedgerState,
    start_millis: i64,
    end_millis_exclusive: i64,
    selection: SummarySelection,
) -> Result<ChosenSummary, SummaryError> {
    let mut summary = ChosenSummary::new(
        state.reporting_currency.clone(),
        start_millis,
        end_millis_exclusive,
        selection.income.then_some(0),
        selection.expenses.then_some(0),
    )?;
    for transaction in state.transactions.values().filter(|transaction| {
        !transaction.voided
            && transaction.recorded_at_millis >= start_millis
            && transaction.recorded_at_millis < end_millis_exclusive
    }) {
        let total = match transaction.kind {
            TransactionKind::Income => &mut summary.income_minor,
            TransactionKind::Expense => &mut summary.expenses_minor,
        };
        if let Some(total) = total {
            *total = total
                .checked_add(transaction.reporting_minor)
                .ok_or(SummaryError::Overflow)?;
        }
    }
    Ok(summary)
}
