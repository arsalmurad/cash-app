use cash_core::{
    AccountId, Currency, Event, EventKind, FxRate, Money, SummaryError, SummarySelection,
    TransactionId, TransactionKind, chosen_summary, fold,
};

fn currency(code: &str) -> Currency {
    Currency::from_code(code).unwrap()
}

fn fixture() -> Vec<Event> {
    let usd = currency("USD");
    let eur = currency("EUR");
    let mut events = vec![Event::new(
        "private-account",
        "private-device",
        0,
        0,
        EventKind::AccountOpened {
            account_id: AccountId::new("private-account"),
            name: "Secret account".into(),
            currency: eur.clone(),
        },
    )];
    for (id, time, kind, amount) in [
        ("before", 9, TransactionKind::Expense, 100),
        ("chosen-expense", 10, TransactionKind::Expense, 8000),
        ("chosen-income", 19, TransactionKind::Income, 10000),
        ("after", 20, TransactionKind::Income, 20000),
        ("removed", 15, TransactionKind::Expense, 500),
    ] {
        events.push(Event::new(
            id,
            "private-device",
            time,
            0,
            EventKind::TransactionRecorded {
                transaction_id: TransactionId::new(id),
                account_id: AccountId::new("private-account"),
                kind,
                original: Money::new(amount, eur.clone()),
                reporting_fx: FxRate::new(87, 80, usd.clone()).unwrap(),
                title: "Secret title".into(),
                category_id: Some("Secret category".into()),
                recurring_id: None,
            },
        ));
    }
    events.push(Event::new(
        "correction",
        "private-device",
        30,
        0,
        EventKind::AmountAdjusted {
            transaction_id: TransactionId::new("chosen-expense"),
            original: Money::new(8500, eur),
            reporting_fx: FxRate::new(87, 80, usd).unwrap(),
        },
    ));
    events.push(Event::new(
        "void",
        "private-device",
        31,
        0,
        EventKind::TransactionVoided {
            transaction_id: TransactionId::new("removed"),
        },
    ));
    events
}

#[test]
fn nothing_is_selected_by_default_and_invalid_periods_fail_closed() {
    let state = fold(currency("USD"), fixture()).unwrap();
    assert_eq!(
        chosen_summary(&state, 10, 20, SummarySelection::default()),
        Err(SummaryError::NothingSelected)
    );
    for end in [9, 10] {
        assert_eq!(
            chosen_summary(
                &state,
                10,
                end,
                SummarySelection {
                    income: true,
                    expenses: true
                }
            ),
            Err(SummaryError::InvalidPeriod)
        );
    }
}

#[test]
fn selected_totals_use_current_corrections_original_dates_and_frozen_fx() {
    let state = fold(currency("USD"), fixture()).unwrap();
    let before = state.canonical_bytes();
    let summary = chosen_summary(
        &state,
        10,
        20,
        SummarySelection {
            income: true,
            expenses: true,
        },
    )
    .unwrap();
    assert_eq!(summary.currency(), &currency("USD"));
    assert_eq!(summary.start_millis(), 10);
    assert_eq!(summary.end_millis_exclusive(), 20);
    assert_eq!(summary.income_minor(), Some(10875));
    assert_eq!(summary.expenses_minor(), Some(9244));
    assert_eq!(state.canonical_bytes(), before);
    // A publication payload has no free-form strings or private identifiers.
    let debug = format!("{summary:?}");
    for secret in [
        "Secret",
        "private-account",
        "private-device",
        "chosen-expense",
    ] {
        assert!(!debug.contains(secret));
    }
    let expense_only = chosen_summary(
        &state,
        10,
        20,
        SummarySelection {
            income: false,
            expenses: true,
        },
    )
    .unwrap();
    assert_eq!(expense_only.income_minor(), None);
    assert_eq!(expense_only.expenses_minor(), Some(9244));
    let empty = chosen_summary(
        &state,
        40,
        50,
        SummarySelection {
            income: true,
            expenses: false,
        },
    )
    .unwrap();
    assert_eq!(empty.income_minor(), Some(0));
    assert_eq!(empty.expenses_minor(), None);
}

#[test]
fn opted_out_flow_cannot_overflow_or_leak_into_selected_flow() {
    // A valid net balance does not imply that a gross flow fits in i64.
    let usd = currency("USD");
    let mut events = vec![Event::new(
        "account",
        "device",
        0,
        0,
        EventKind::AccountOpened {
            account_id: AccountId::new("cash"),
            name: "Cash".into(),
            currency: usd.clone(),
        },
    )];
    for (index, kind, amount) in [
        (1, TransactionKind::Income, i64::MAX),
        (2, TransactionKind::Expense, i64::MAX),
        (3, TransactionKind::Income, 1),
    ] {
        events.push(Event::new(
            format!("event-{index}"),
            "device",
            index,
            0,
            EventKind::TransactionRecorded {
                transaction_id: TransactionId::new(format!("txn-{index}")),
                account_id: AccountId::new("cash"),
                kind,
                original: Money::new(amount, usd.clone()),
                reporting_fx: FxRate::identity(usd.clone()),
                title: "Private".into(),
                category_id: None,
                recurring_id: None,
            },
        ));
    }
    let state = fold(usd, events).unwrap();
    assert_eq!(
        chosen_summary(
            &state,
            1,
            4,
            SummarySelection {
                income: true,
                expenses: false
            }
        ),
        Err(SummaryError::Overflow)
    );
    let summary = chosen_summary(
        &state,
        1,
        4,
        SummarySelection {
            income: false,
            expenses: true,
        },
    )
    .unwrap();
    assert_eq!(summary.income_minor(), None);
    assert_eq!(summary.expenses_minor(), Some(i64::MAX));
}

#[test]
fn a_preview_is_frozen_and_internal_transfers_do_not_count_as_income() {
    let mut events = fixture();
    let state = fold(currency("USD"), events.clone()).unwrap();
    let selection = SummarySelection {
        income: true,
        expenses: true,
    };
    let preview = chosen_summary(&state, 10, 20, selection).unwrap();
    events.push(Event::new(
        "second-account",
        "private-device",
        1,
        0,
        EventKind::AccountOpened {
            account_id: AccountId::new("other"),
            name: "Other secret".into(),
            currency: currency("USD"),
        },
    ));
    events.push(Event::new(
        "transfer",
        "private-device",
        18,
        0,
        EventKind::TransferRecorded {
            transfer_id: TransactionId::new("transfer"),
            from_account_id: AccountId::new("private-account"),
            to_account_id: AccountId::new("other"),
            sent: Money::new(100, currency("EUR")),
            sent_reporting_fx: FxRate::new(87, 80, currency("USD")).unwrap(),
            received: Money::new(108, currency("USD")),
            received_reporting_fx: FxRate::identity(currency("USD")),
            title: "Secret transfer".into(),
        },
    ));
    let transferred = fold(currency("USD"), events.clone()).unwrap();
    assert_eq!(
        chosen_summary(&transferred, 10, 20, selection).unwrap(),
        preview
    );
    events.push(Event::new(
        "later-correction",
        "private-device",
        40,
        0,
        EventKind::AmountAdjusted {
            transaction_id: TransactionId::new("chosen-expense"),
            original: Money::new(10000, currency("EUR")),
            reporting_fx: FxRate::new(87, 80, currency("USD")).unwrap(),
        },
    ));
    events.reverse();
    let revised = fold(currency("USD"), events).unwrap();
    assert_eq!(
        chosen_summary(&revised, 10, 20, selection)
            .unwrap()
            .expenses_minor(),
        Some(10875)
    );
    assert_eq!(preview.expenses_minor(), Some(9244));
}

#[test]
fn zero_decimal_reporting_currency_is_preserved_without_scaling_or_rounding_again() {
    let mut events = fixture();
    for event in &mut events {
        match &mut event.kind {
            EventKind::TransactionRecorded { reporting_fx, .. }
            | EventKind::AmountAdjusted { reporting_fx, .. } => {
                *reporting_fx = FxRate::new(3, 2, currency("JPY")).unwrap();
            }
            _ => {}
        }
    }
    let state = fold(currency("JPY"), events).unwrap();
    let summary = chosen_summary(
        &state,
        10,
        20,
        SummarySelection {
            income: true,
            expenses: true,
        },
    )
    .unwrap();
    assert_eq!(summary.currency(), &currency("JPY"));
    assert_eq!(summary.income_minor(), Some(15000));
    assert_eq!(summary.expenses_minor(), Some(12750));
    assert_eq!(
        summary
            .currency()
            .format_minor_units(summary.expenses_minor().unwrap()),
        "JPY 12750"
    );
}
